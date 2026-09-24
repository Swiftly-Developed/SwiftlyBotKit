import Foundation
import Vapor
import Fluent
import SQLKit

/// What one dashboard render needs, in five grouped queries.
struct BotDashboardData: Sendable {
    struct Totals: Sendable {
        var botVisits = 0
        var userTriggered = 0
        var verified = 0
        var spoofed = 0
        var referrals = 0
        var distinctAgents = 0

        /// Share of bot visits whose source IP matched the operator's published
        /// ranges. Note the denominator: visits that *could* be checked, not all
        /// of them. Most of the long tail publishes nothing, and folding those in
        /// would read as a verification failure rather than an absence.
        var verifiableShare: Double? {
            let checkable = verified + spoofed
            guard checkable > 0 else { return nil }
            return Double(verified) / Double(checkable)
        }
    }

    struct SeriesPoint: Sendable {
        let bucket: Date
        var counts: [AIAgentPurpose: Int]
        var total: Int { counts.values.reduce(0, +) }
    }

    struct AgentRow: Sendable {
        let name: String
        let operatorName: String
        let purpose: AIAgentPurpose?
        let count: Int
        let verified: Int
        let spoofed: Int
        let respectsRobotsTxt: Bool?
    }

    struct PageRow: Sendable {
        let path: String
        let count: Int
        let userTriggered: Int
    }

    struct PlatformRow: Sendable {
        let platform: String
        let count: Int
    }

    var totals = Totals()
    var series: [SeriesPoint] = []
    var topAgents: [AgentRow] = []
    var topPages: [PageRow] = []
    var referrals: [PlatformRow] = []

    var purposeTotals: [(purpose: AIAgentPurpose, count: Int)] {
        AIAgentPurpose.displayOrder.compactMap { purpose in
            let count = series.reduce(0) { $0 + ($1.counts[purpose] ?? 0) }
            return count > 0 ? (purpose, count) : nil
        }
    }

    var isEmpty: Bool { totals.botVisits == 0 && totals.referrals == 0 }
}

/// Every aggregate the dashboard shows.
///
/// **PostgreSQL only.** The queries use `COUNT(*) FILTER (WHERE …)`,
/// `width_bucket` over a `timestamptz[]`, `BOOL_AND` and `::text` casts.
///
/// Raw SQL rather than Fluent: all five are `GROUP BY` with `FILTER` clauses,
/// which Fluent's query builder cannot express, and doing it in Swift would
/// mean pulling ninety days of rows into memory to count them.
///
/// The only interpolated values are the window start, the bucket
/// boundaries and the site key, all bound. The enum labels in the `FILTER` clauses are literals from our own
/// source, never from the request.
struct BotDashboardQueries: Sendable {
    let database: any SQLDatabase
    /// The zone every bucket boundary is computed in, on the Swift side only.
    /// PostgreSQL is handed instants, never this zone's name.
    let timeZone: TimeZone

    func load(range: BotDateRange, siteKey: String?, now: Date = Date()) async throws -> BotDashboardData {
        let window = range.window(now: now, in: timeZone)
        let since = window.start
        var data = BotDashboardData()
        data.totals = try await totals(since: since, siteKey: siteKey)
        data.series = try await series(window: window, siteKey: siteKey)
        data.topAgents = try await topAgents(since: since, siteKey: siteKey)
        data.topPages = try await topPages(since: since, siteKey: siteKey)
        data.referrals = try await referrals(since: since, siteKey: siteKey)
        return data
    }

    // MARK: - Queries

    private func totals(since: Date, siteKey: String?) async throws -> BotDashboardData.Totals {
        var query: SQLQueryString = """
        SELECT
            COUNT(*) FILTER (WHERE agent_name IS NOT NULL) AS bot_visits,
            COUNT(*) FILTER (WHERE purpose = 'userTriggered') AS user_triggered,
            COUNT(*) FILTER (WHERE verification = 'verified') AS verified,
            COUNT(*) FILTER (WHERE verification = 'spoofed') AS spoofed,
            COUNT(*) FILTER (WHERE referrer_platform IS NOT NULL) AS referrals,
            COUNT(DISTINCT agent_name) AS distinct_agents
        FROM ai_bot_visits
        WHERE created_at >= \(bind: since)
        """
        query += siteClause(siteKey)

        guard let row = try await database.raw(query).first() else { return .init() }
        var totals = BotDashboardData.Totals()
        totals.botVisits = (try? row.decode(column: "bot_visits", as: Int.self)) ?? 0
        totals.userTriggered = (try? row.decode(column: "user_triggered", as: Int.self)) ?? 0
        totals.verified = (try? row.decode(column: "verified", as: Int.self)) ?? 0
        totals.spoofed = (try? row.decode(column: "spoofed", as: Int.self)) ?? 0
        totals.referrals = (try? row.decode(column: "referrals", as: Int.self)) ?? 0
        totals.distinctAgents = (try? row.decode(column: "distinct_agents", as: Int.self)) ?? 0
        return totals
    }

    private func series(
        window: BotDateRange.Window,
        siteKey: String?
    ) async throws -> [BotDashboardData.SeriesPoint] {
        // PostgreSQL does not bucket by time zone at all. Swift computed every
        // run of constant local wall-clock hour or day; `width_bucket` returns
        // which run a row falls in (1-based, thresholds ascending). No zone
        // name, `AT TIME ZONE` or tzdata on the server is involved, so the two
        // sides cannot disagree about DST, legacy names or fixed offsets.
        //
        // A NULL purpose (a row written by something other than this package)
        // is charted as `scraper`, the catalog's own fallback for an agent it
        // cannot classify, so the chart sums to the same total as the tile.
        let thresholds = window.runs.map(\.start)
        var query: SQLQueryString = """
        SELECT
            width_bucket(created_at, \(bind: thresholds)::timestamptz[]) AS run,
            COALESCE(purpose::text, 'scraper') AS purpose,
            COUNT(*) AS count
        FROM ai_bot_visits
        WHERE created_at >= \(bind: window.start) AND agent_name IS NOT NULL
        """
        query += siteClause(siteKey)
        query += " GROUP BY 1, 2"

        var counts = Array(repeating: [AIAgentPurpose: Int](), count: window.buckets.count)
        for row in try await database.raw(query).all() {
            guard let run = try? row.decode(column: "run", as: Int.self),
                  (1...window.runs.count).contains(run),
                  let raw = try? row.decode(column: "purpose", as: String.self),
                  let purpose = AIAgentPurpose(rawValue: raw),
                  let count = try? row.decode(column: "count", as: Int.self)
            else { continue }
            counts[window.runs[run - 1].bucket][purpose, default: 0] += count
        }

        // Driven by the generated bucket list, not by the rows, so quiet
        // periods stay visible as gaps in the chart.
        return zip(window.buckets, counts).map { bucket, counts in
            .init(bucket: bucket.start, counts: counts)
        }
    }

    private func topAgents(since: Date, siteKey: String?) async throws -> [BotDashboardData.AgentRow] {
        var query: SQLQueryString = """
        SELECT
            agent_name,
            COALESCE(agent_operator, 'Unknown') AS agent_operator,
            purpose::text AS purpose,
            BOOL_AND(respects_robots_txt) AS respects_robots_txt,
            COUNT(*) AS count,
            COUNT(*) FILTER (WHERE verification = 'verified') AS verified,
            COUNT(*) FILTER (WHERE verification = 'spoofed') AS spoofed
        FROM ai_bot_visits
        WHERE created_at >= \(bind: since) AND agent_name IS NOT NULL
        """
        query += siteClause(siteKey)
        query += " GROUP BY agent_name, agent_operator, purpose ORDER BY count DESC LIMIT 12"

        return try await database.raw(query).all().compactMap { row in
            guard let name = try? row.decode(column: "agent_name", as: String.self),
                  let count = try? row.decode(column: "count", as: Int.self)
            else { return nil }
            let rawPurpose = try? row.decode(column: "purpose", as: String.self)
            return .init(
                name: name,
                operatorName: (try? row.decode(column: "agent_operator", as: String.self)) ?? "Unknown",
                purpose: rawPurpose.flatMap(AIAgentPurpose.init(rawValue:)),
                count: count,
                verified: (try? row.decode(column: "verified", as: Int.self)) ?? 0,
                spoofed: (try? row.decode(column: "spoofed", as: Int.self)) ?? 0,
                respectsRobotsTxt: try? row.decode(column: "respects_robots_txt", as: Bool?.self)
            )
        }
    }

    private func topPages(since: Date, siteKey: String?) async throws -> [BotDashboardData.PageRow] {
        var query: SQLQueryString = """
        SELECT
            path,
            COUNT(*) AS count,
            COUNT(*) FILTER (WHERE purpose = 'userTriggered') AS user_triggered
        FROM ai_bot_visits
        WHERE created_at >= \(bind: since) AND agent_name IS NOT NULL
        """
        query += siteClause(siteKey)
        query += " GROUP BY path ORDER BY count DESC LIMIT 12"

        return try await database.raw(query).all().compactMap { row in
            guard let path = try? row.decode(column: "path", as: String.self),
                  let count = try? row.decode(column: "count", as: Int.self)
            else { return nil }
            return .init(
                path: path,
                count: count,
                userTriggered: (try? row.decode(column: "user_triggered", as: Int.self)) ?? 0
            )
        }
    }

    private func referrals(since: Date, siteKey: String?) async throws -> [BotDashboardData.PlatformRow] {
        var query: SQLQueryString = """
        SELECT referrer_platform, COUNT(*) AS count
        FROM ai_bot_visits
        WHERE created_at >= \(bind: since) AND referrer_platform IS NOT NULL
        """
        query += siteClause(siteKey)
        query += " GROUP BY referrer_platform ORDER BY count DESC LIMIT 10"

        return try await database.raw(query).all().compactMap { row in
            guard let platform = try? row.decode(column: "referrer_platform", as: String.self),
                  let count = try? row.decode(column: "count", as: Int.self)
            else { return nil }
            return .init(platform: platform, count: count)
        }
    }

    /// Empty for the all-sites view.
    private func siteClause(_ siteKey: String?) -> SQLQueryString {
        guard let siteKey else { return "" }
        return " AND site_key = \(bind: siteKey)"
    }
}
