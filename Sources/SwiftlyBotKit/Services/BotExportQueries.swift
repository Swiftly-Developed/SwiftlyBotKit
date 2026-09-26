import Foundation
import SQLKit

/// The export's queries. PostgreSQL only, like ``BotDashboardQueries``.
///
/// A grouped export is one `GROUP BY` per audience, bucketed the dashboard's
/// way: Swift computes every period boundary and PostgreSQL only sorts rows
/// between them with `width_bucket`. The result is bounded by periods times
/// groups, so it is built in memory.
///
/// A raw export is not bounded, so it is read in pages of ``rawPageSize`` lines
/// and written as it goes. Pages are cut on `(time, key)` rather than an
/// offset, so each one starts with an index scan and the cost stays flat
/// however deep into the export it is.
///
/// Every column and table name comes from this file; only the window, the
/// boundaries, the site key and the page cursor are bound.
struct BotExportQueries: Sendable {
    let database: any SQLDatabase

    /// Lines per raw page.
    var rawPageSize = 5_000

    /// One line of a grouped export.
    struct GroupedRow: Sendable, Equatable {
        /// Index into ``BotExportPlan/periods``.
        let period: Int
        let audience: BotExportAudience
        var site: String?
        var path: String?
        var agent: String?
        var agentOperator: String?
        var purpose: String?
        var verification: String?
        var referrer: String?
        let count: Int

        func values(for dimension: BotExportDimension) -> [String?] {
            switch dimension {
            case .site: return [site]
            case .path: return [path]
            case .agent: return [agent, agentOperator]
            case .purpose: return [purpose]
            case .verification: return [verification]
            case .referrer: return [referrer]
            }
        }
    }

    // MARK: - Grouped

    /// Every line of a grouped export, ordered by period, audience, count
    /// (largest first) and then the group values.
    ///
    /// With no dimension chosen, a period an audience was quiet in still gets
    /// its line with a count of 0, so the file is an unbroken series.
    func grouped(_ plan: BotExportPlan) async throws -> [GroupedRow] {
        guard !plan.periods.isEmpty else { return [] }
        var rows: [GroupedRow] = []
        for audience in plan.audiences {
            rows += try await grouped(audience, plan: plan)
        }
        if plan.dimensions.isEmpty {
            let present = Set(rows.map { "\($0.period):\($0.audience.rawValue)" })
            for period in plan.periods.indices {
                for audience in plan.audiences where !present.contains("\(period):\(audience.rawValue)") {
                    rows.append(.init(period: period, audience: audience, count: 0))
                }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: BotExportAudience.allCases.enumerated().map { ($1, $0) })
        return rows.sorted { a, b in
            if a.period != b.period { return a.period < b.period }
            if a.audience != b.audience { return order[a.audience]! < order[b.audience]! }
            if a.count != b.count { return a.count > b.count }
            let left = plan.dimensions.flatMap { a.values(for: $0) }.map { $0 ?? "" }
            let right = plan.dimensions.flatMap { b.values(for: $0) }.map { $0 ?? "" }
            return left.lexicographicallyPrecedes(right)
        }
    }

    private func grouped(_ audience: BotExportAudience, plan: BotExportPlan) async throws -> [GroupedRow] {
        let source = Source(audience, pageReadsOnly: plan.pageReadsOnly)
        let columns = plan.dimensions.filter { $0.applies(to: audience) }.flatMap(Self.sqlColumns)

        var query: SQLQueryString = """
        SELECT width_bucket(\(unsafeRaw: source.time), \(bind: plan.periods.map(\.start))::timestamptz[]) AS period
        """
        for column in columns {
            query += ", \(unsafeRaw: column.expression) AS \(unsafeRaw: column.alias)"
        }
        query += """
         , \(unsafeRaw: source.measure) AS n
        FROM \(unsafeRaw: source.table)
        WHERE \(unsafeRaw: source.time) >= \(bind: plan.start) AND \(unsafeRaw: source.time) < \(bind: plan.end)
          AND \(unsafeRaw: source.filter)
        """
        query += siteClause(plan.siteKey)
        query += " GROUP BY \(unsafeRaw: (1...(columns.count + 1)).map(String.init).joined(separator: ", "))"

        return try await database.raw(query).all().compactMap { row in
            guard let period = try? row.decode(column: "period", as: Int.self),
                  plan.periods.indices.contains(period - 1),
                  let count = try? row.decode(column: "n", as: Int.self)
            else { return nil }
            var line = GroupedRow(period: period - 1, audience: audience, count: count)
            let text: (String) -> String? = { alias in
                columns.contains { $0.alias == alias } ? (try? row.decode(column: alias, as: String?.self)) ?? nil : nil
            }
            line.site = text("site_key")
            line.path = text("path")
            line.agent = text("agent_name")
            line.agentOperator = text("agent_operator")
            line.purpose = text("purpose")
            line.verification = text("verification")
            line.referrer = text("referrer_platform")
            return line
        }
    }

    /// The selected expression and alias for each dimension's columns.
    private static func sqlColumns(_ dimension: BotExportDimension) -> [(expression: String, alias: String)] {
        switch dimension {
        case .site: return [("site_key", "site_key")]
        case .path: return [("path", "path")]
        case .agent: return [("agent_name", "agent_name"), ("agent_operator", "agent_operator")]
        case .purpose: return [("purpose::text", "purpose")]
        case .verification: return [("verification::text", "verification")]
        case .referrer: return [("referrer_platform", "referrer_platform")]
        }
    }

    /// Where an audience's rows live and what counts one.
    private struct Source {
        let table: String
        let time: String
        let measure: String
        let filter: String

        init(_ audience: BotExportAudience, pageReadsOnly: Bool) {
            switch audience {
            case .agents:
                table = "ai_bot_visits"
                time = "created_at"
                measure = "COUNT(*)"
                filter = Self.agentFilter(pageReadsOnly: pageReadsOnly)
            case .referrals:
                table = "ai_bot_visits"
                time = "created_at"
                measure = "COUNT(*)"
                filter = Self.referralFilter
            case .people:
                table = "page_view_counts"
                time = "bucket_start"
                measure = "SUM(views)::bigint"
                filter = "TRUE"
            }
        }

        static func agentFilter(pageReadsOnly: Bool) -> String {
            pageReadsOnly ? "(\(PageViewQueries.agentReadFilter))" : "agent_name IS NOT NULL"
        }

        static let referralFilter = "referrer_platform IS NOT NULL"
    }

    // MARK: - Raw

    /// Writes every raw line, header first, oldest first, one page at a time.
    ///
    /// AI agents and referrals come from `ai_bot_visits`, one line per
    /// request; people from `page_view_counts`, one line per quarter-hour
    /// counter. The two are merged in time order in one query.
    func streamRaw(_ plan: BotExportPlan, write: @Sendable (String) async throws -> Void) async throws {
        try await write(BotExportCSV.line(BotExportCSV.rawColumns))
        let formatter = BotExportCSV.timestampFormatter(in: plan.timeZone)
        var cursor: (micros: Int64, key: String)?
        while true {
            let rows = try await database.raw(rawPage(plan, after: cursor)).all()
            var chunk = ""
            for row in rows {
                let micros = try row.decode(column: "us", as: Int64.self)
                let key = try row.decode(column: "k", as: String.self)
                cursor = (micros, key)
                let status = try row.decode(column: "status_code", as: Int?.self)
                let robots = try row.decode(column: "respects_robots_txt", as: Bool?.self)
                chunk += BotExportCSV.line([
                    formatter.string(from: try row.decode(column: "t", as: Date.self)),
                    try row.decode(column: "audience", as: String.self),
                    try row.decode(column: "site_key", as: String.self),
                    try row.decode(column: "path", as: String.self),
                    try row.decode(column: "method", as: String?.self),
                    status.map(String.init),
                    try row.decode(column: "agent_name", as: String?.self),
                    try row.decode(column: "agent_operator", as: String?.self),
                    try row.decode(column: "purpose", as: String?.self),
                    try row.decode(column: "verification", as: String?.self),
                    robots.map { $0 ? "true" : "false" },
                    try row.decode(column: "referrer_platform", as: String?.self),
                    String(try row.decode(column: "n", as: Int.self)),
                ])
            }
            if !chunk.isEmpty { try await write(chunk) }
            if rows.count < rawPageSize { return }
        }
    }

    /// One page of raw lines after `cursor`.
    ///
    /// The cursor is the time in whole microseconds, computed by PostgreSQL
    /// so it round-trips exactly (a `Date` would not), plus a key unique
    /// within that instant. The plain time bound one second below it lets
    /// the time index do the work; the tuple comparison then trims exactly.
    private func rawPage(_ plan: BotExportPlan, after cursor: (micros: Int64, key: String)?) -> SQLQueryString {
        var lower = plan.start
        if let cursor {
            lower = max(plan.start, Date(timeIntervalSince1970: Double(cursor.micros) / 1_000_000 - 1))
        }

        var branches: [SQLQueryString] = []
        var aiFilters: [String] = []
        if plan.audiences.contains(.agents) { aiFilters.append(Source.agentFilter(pageReadsOnly: plan.pageReadsOnly)) }
        if plan.audiences.contains(.referrals) { aiFilters.append(Source.referralFilter) }
        if !aiFilters.isEmpty {
            var branch: SQLQueryString = """
            SELECT created_at AS t,
                   (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS us,
                   'a:' || id::text AS k,
                   CASE WHEN agent_name IS NOT NULL THEN 'ai_agent' ELSE 'ai_referral' END AS audience,
                   site_key, path, method, status_code, agent_name, agent_operator,
                   purpose::text AS purpose, verification::text AS verification,
                   respects_robots_txt, referrer_platform, 1::bigint AS n
            FROM ai_bot_visits
            WHERE created_at >= \(bind: lower) AND created_at < \(bind: plan.end)
              AND (\(unsafeRaw: aiFilters.joined(separator: " OR ")))
            """
            branch += siteClause(plan.siteKey)
            branches.append(branch)
        }
        if plan.audiences.contains(.people) {
            var branch: SQLQueryString = """
            SELECT bucket_start AS t,
                   (EXTRACT(EPOCH FROM bucket_start) * 1000000)::bigint AS us,
                   'p:' || site_key || E'\\n' || path AS k,
                   'people' AS audience,
                   site_key, path, NULL::text AS method, NULL::int AS status_code,
                   NULL::text AS agent_name, NULL::text AS agent_operator,
                   NULL::text AS purpose, NULL::text AS verification,
                   NULL::boolean AS respects_robots_txt, NULL::text AS referrer_platform, views AS n
            FROM page_view_counts
            WHERE bucket_start >= \(bind: lower) AND bucket_start < \(bind: plan.end)
            """
            branch += siteClause(plan.siteKey)
            branches.append(branch)
        }

        var query: SQLQueryString = "SELECT * FROM ("
        for (index, branch) in branches.enumerated() {
            if index > 0 { query += " UNION ALL " }
            query += branch
        }
        query += ") AS lines"
        if let cursor {
            query += " WHERE (us, k COLLATE \"C\") > (\(bind: cursor.micros), \(bind: cursor.key) COLLATE \"C\")"
        }
        query += " ORDER BY us, k COLLATE \"C\" LIMIT \(unsafeRaw: String(rawPageSize))"
        return query
    }

    /// Empty for every site.
    private func siteClause(_ siteKey: String?) -> SQLQueryString {
        guard let siteKey else { return "" }
        return " AND site_key = \(bind: siteKey)"
    }
}
