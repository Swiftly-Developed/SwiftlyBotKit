import Foundation
import SQLKit

/// What the "Page views" tab shows.
struct PageViewData: Sendable {
    struct PageRow: Sendable {
        let path: String
        let views: Int
        /// AI agent requests for the same path in the same window, from
        /// `ai_bot_visits`, so a page's human and machine readership sit side
        /// by side.
        let agentVisits: Int
    }

    var totalViews = 0
    var distinctPages = 0
    /// AI agent requests in the same window and site, for scale.
    var agentVisits = 0
    var series: [(bucket: Date, count: Int)] = []
    var topPages: [PageRow] = []

    var isEmpty: Bool { totalViews == 0 }
}

/// The page view aggregates. PostgreSQL only, like ``BotDashboardQueries``,
/// and bucketed the same way: Swift computes every boundary and PostgreSQL
/// only sorts the stored quarter-hours between them with `width_bucket`.
/// A quarter-hour never straddles a boundary, because every zone's offset is
/// a whole number of quarter-hours.
struct PageViewQueries: Sendable {
    let database: any SQLDatabase
    let timeZone: TimeZone

    /// How many pages the top list shows.
    static let topPageLimit = 25

    func load(range: BotDateRange, siteKey: String?, now: Date = Date()) async throws -> PageViewData {
        let window = range.window(now: now, in: timeZone)
        var data = PageViewData()
        let totals = try await totals(since: window.start, siteKey: siteKey)
        data.totalViews = totals.views
        data.distinctPages = totals.pages
        data.series = try await series(window: window, siteKey: siteKey)
        let pages = try await topPages(since: window.start, siteKey: siteKey)
        let agents = try await agentVisits(since: window.start, siteKey: siteKey, paths: pages.map(\.path))
        data.agentVisits = agents.total
        data.topPages = pages.map { .init(path: $0.path, views: $0.views, agentVisits: agents.byPath[$0.path] ?? 0) }
        return data
    }

    private func totals(since: Date, siteKey: String?) async throws -> (views: Int, pages: Int) {
        var query: SQLQueryString = """
        SELECT COALESCE(SUM(views), 0)::bigint AS views, COUNT(DISTINCT path) AS pages
        FROM page_view_counts
        WHERE bucket_start >= \(bind: since)
        """
        query += siteClause(siteKey)
        guard let row = try await database.raw(query).first() else { return (0, 0) }
        return (
            (try? row.decode(column: "views", as: Int.self)) ?? 0,
            (try? row.decode(column: "pages", as: Int.self)) ?? 0
        )
    }

    private func series(window: BotDateRange.Window, siteKey: String?) async throws -> [(bucket: Date, count: Int)] {
        let thresholds = window.runs.map(\.start)
        var query: SQLQueryString = """
        SELECT
            width_bucket(bucket_start, \(bind: thresholds)::timestamptz[]) AS run,
            SUM(views)::bigint AS views
        FROM page_view_counts
        WHERE bucket_start >= \(bind: window.start)
        """
        query += siteClause(siteKey)
        query += " GROUP BY 1"

        var counts = Array(repeating: 0, count: window.buckets.count)
        for row in try await database.raw(query).all() {
            guard let run = try? row.decode(column: "run", as: Int.self),
                  (1...window.runs.count).contains(run),
                  let views = try? row.decode(column: "views", as: Int.self)
            else { continue }
            counts[window.runs[run - 1].bucket] += views
        }
        // Driven by the bucket list, so quiet periods show as gaps.
        return zip(window.buckets, counts).map { ($0.start, $1) }
    }

    private func topPages(since: Date, siteKey: String?) async throws -> [(path: String, views: Int)] {
        var query: SQLQueryString = """
        SELECT path, SUM(views)::bigint AS views
        FROM page_view_counts
        WHERE bucket_start >= \(bind: since)
        """
        query += siteClause(siteKey)
        query += " GROUP BY path ORDER BY views DESC, path LIMIT \(unsafeRaw: String(Self.topPageLimit))"

        return try await database.raw(query).all().compactMap { row in
            guard let path = try? row.decode(column: "path", as: String.self),
                  let views = try? row.decode(column: "views", as: Int.self)
            else { return nil }
            return (path, views)
        }
    }

    /// The window's AI agent total, and the per-path counts for `paths`.
    private func agentVisits(
        since: Date,
        siteKey: String?,
        paths: [String]
    ) async throws -> (total: Int, byPath: [String: Int]) {
        var totalQuery: SQLQueryString = """
        SELECT COUNT(*) AS total FROM ai_bot_visits
        WHERE created_at >= \(bind: since) AND agent_name IS NOT NULL
        """
        totalQuery += siteClause(siteKey)
        let total = try await database.raw(totalQuery).first()?.decode(column: "total", as: Int.self) ?? 0
        guard !paths.isEmpty else { return (total, [:]) }

        var pathQuery: SQLQueryString = """
        SELECT path, COUNT(*) AS n FROM ai_bot_visits
        WHERE created_at >= \(bind: since) AND agent_name IS NOT NULL AND path = ANY(\(bind: paths)::text[])
        """
        pathQuery += siteClause(siteKey)
        pathQuery += " GROUP BY path"
        var byPath: [String: Int] = [:]
        for row in try await database.raw(pathQuery).all() {
            guard let path = try? row.decode(column: "path", as: String.self),
                  let count = try? row.decode(column: "n", as: Int.self)
            else { continue }
            byPath[path] = count
        }
        return (total, byPath)
    }

    /// Empty for the all-sites view.
    private func siteClause(_ siteKey: String?) -> SQLQueryString {
        guard let siteKey else { return "" }
        return " AND site_key = \(bind: siteKey)"
    }
}
