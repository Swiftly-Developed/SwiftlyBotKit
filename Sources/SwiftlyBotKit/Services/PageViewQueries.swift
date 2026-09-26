import Foundation
import SQLKit

/// Whose page reads the "Page views" tab shows, from `?audience=`.
enum PageViewAudience: String, CaseIterable, Sendable {
    /// People in a browser, from `page_view_counts`. The default.
    case people
    /// AI agents' successful page requests, from `ai_bot_visits`.
    case agents
    /// Both, drawn as two parts of every bar.
    case combined = "all"

    var label: String {
        switch self {
        case .people: return "People"
        case .agents: return "AI agents"
        case .combined: return "Combined"
        }
    }

    init(query raw: String?) {
        self = raw.flatMap(PageViewAudience.init(rawValue:)) ?? .people
    }

    var includesPeople: Bool { self != .agents }
    var includesAgents: Bool { self != .people }
}

/// What the "Page views" tab shows. Every figure is split into people and AI
/// agents; the audience decides which of them the page uses.
struct PageViewData: Sendable {
    struct PageRow: Sendable, Equatable {
        let path: String
        let people: Int
        let agents: Int
    }

    struct SeriesPoint: Sendable, Equatable {
        let bucket: Date
        let people: Int
        let agents: Int
    }

    var people = 0
    var agents = 0
    /// Distinct paths with at least one read by the chosen audience.
    var distinctPages = 0
    var series: [SeriesPoint] = []
    var topPages: [PageRow] = []
    /// The first counted page view, when counting began inside the window.
    /// People figures before it are not zero but unknown.
    var peopleCountedSince: Date?
    /// How many of the window's buckets lie after counting began: the
    /// divisor for a people-per-bucket average.
    var peopleBucketCount = 0

    func total(for audience: PageViewAudience) -> Int {
        (audience.includesPeople ? people : 0) + (audience.includesAgents ? agents : 0)
    }
}

/// The page view aggregates. PostgreSQL only, like ``BotDashboardQueries``,
/// and bucketed the same way: Swift computes every boundary and PostgreSQL
/// only sorts rows between them with `width_bucket`. A stored quarter-hour
/// never straddles a boundary, because every zone's offset is a whole number
/// of quarter-hours.
///
/// AI agent reads are the rows ``BotDashboardQueries`` counts as agent visits,
/// narrowed to what a person could have read: a successful `GET` of a page.
/// `robots.txt`, sitemaps and errors stay on the AI agents tab, so "combined"
/// adds like to like.
struct PageViewQueries: Sendable {
    let database: any SQLDatabase
    let timeZone: TimeZone

    /// How many pages the top list shows.
    static let topPageLimit = 25

    /// The `ai_bot_visits` rows that count as an AI agent reading a page.
    static let agentReadFilter = """
        agent_name IS NOT NULL AND method = 'GET' AND status_code BETWEEN 200 AND 299 \
        AND path NOT LIKE '%.txt' AND path NOT LIKE '%.xml'
        """

    func load(
        range: BotDateRange,
        siteKey: String?,
        audience: PageViewAudience = .people,
        now: Date = Date()
    ) async throws -> PageViewData {
        let window = range.window(now: now, in: timeZone)
        var data = PageViewData()
        let people = try await peopleSeries(window: window, siteKey: siteKey)
        let agents = try await agentSeries(window: window, siteKey: siteKey)
        data.series = zip(window.buckets, zip(people, agents)).map {
            .init(bucket: $0.start, people: $1.0, agents: $1.1)
        }
        data.people = people.reduce(0, +)
        data.agents = agents.reduce(0, +)
        let (pages, distinct) = try await topPages(since: window.start, siteKey: siteKey, audience: audience)
        data.topPages = pages
        data.distinctPages = distinct

        data.peopleBucketCount = window.buckets.count
        if let first = try await firstCountedView(siteKey: siteKey), first > window.start {
            data.peopleCountedSince = first
            // A bucket counts once any of it lies after counting began.
            let ends = window.buckets.dropFirst().map(\.start) + [now]
            data.peopleBucketCount = max(1, ends.filter { $0 > first }.count)
        }
        return data
    }

    // MARK: - Series

    private func peopleSeries(window: BotDateRange.Window, siteKey: String?) async throws -> [Int] {
        var query: SQLQueryString = """
        SELECT width_bucket(bucket_start, \(bind: window.runs.map(\.start))::timestamptz[]) AS run,
               SUM(views)::bigint AS n
        FROM page_view_counts
        WHERE bucket_start >= \(bind: window.start)
        """
        query += siteClause(siteKey)
        query += " GROUP BY 1"
        return try await bucketed(query, window: window)
    }

    private func agentSeries(window: BotDateRange.Window, siteKey: String?) async throws -> [Int] {
        var query: SQLQueryString = """
        SELECT width_bucket(created_at, \(bind: window.runs.map(\.start))::timestamptz[]) AS run,
               COUNT(*) AS n
        FROM ai_bot_visits
        WHERE created_at >= \(bind: window.start) AND \(unsafeRaw: Self.agentReadFilter)
        """
        query += siteClause(siteKey)
        query += " GROUP BY 1"
        return try await bucketed(query, window: window)
    }

    /// One count per bucket, driven by the bucket list so quiet periods show
    /// as gaps rather than vanishing.
    private func bucketed(_ query: SQLQueryString, window: BotDateRange.Window) async throws -> [Int] {
        var counts = Array(repeating: 0, count: window.buckets.count)
        for row in try await database.raw(query).all() {
            guard let run = try? row.decode(column: "run", as: Int.self),
                  (1...window.runs.count).contains(run),
                  let n = try? row.decode(column: "n", as: Int.self)
            else { continue }
            counts[window.runs[run - 1].bucket] += n
        }
        return counts
    }

    // MARK: - Pages

    /// The most-read paths for `audience`, each with both counts, and how many
    /// distinct paths the audience read at all.
    private func topPages(
        since: Date,
        siteKey: String?,
        audience: PageViewAudience
    ) async throws -> (pages: [PageViewData.PageRow], distinct: Int) {
        let metric: String
        switch audience {
        case .people: metric = "people"
        case .agents: metric = "agents"
        case .combined: metric = "people + agents"
        }
        var query: SQLQueryString = """
        WITH per_path AS (
            SELECT path, SUM(people)::bigint AS people, SUM(agents)::bigint AS agents
            FROM (
                SELECT path, SUM(views) AS people, 0 AS agents
                FROM page_view_counts
                WHERE bucket_start >= \(bind: since)
        """
        query += siteClause(siteKey)
        query += """

                GROUP BY path
                UNION ALL
                SELECT path, 0, COUNT(*)
                FROM ai_bot_visits
                WHERE created_at >= \(bind: since) AND \(unsafeRaw: Self.agentReadFilter)
        """
        query += siteClause(siteKey)
        query += """

                GROUP BY path
            ) AS both_sources
            GROUP BY path
        )
        SELECT path, people, agents, COUNT(*) OVER () AS distinct_pages
        FROM per_path
        WHERE \(unsafeRaw: metric) > 0
        ORDER BY \(unsafeRaw: metric) DESC, path
        LIMIT \(unsafeRaw: String(Self.topPageLimit))
        """

        var distinct = 0
        let rows: [PageViewData.PageRow] = try await database.raw(query).all().compactMap { row in
            guard let path = try? row.decode(column: "path", as: String.self) else { return nil }
            distinct = (try? row.decode(column: "distinct_pages", as: Int.self)) ?? distinct
            return .init(
                path: path,
                people: (try? row.decode(column: "people", as: Int.self)) ?? 0,
                agents: (try? row.decode(column: "agents", as: Int.self)) ?? 0
            )
        }
        return (rows, distinct)
    }

    /// When page views were first counted for this site (or any site).
    private func firstCountedView(siteKey: String?) async throws -> Date? {
        var query: SQLQueryString = "SELECT MIN(bucket_start) AS first FROM page_view_counts WHERE TRUE"
        query += siteClause(siteKey)
        return try await database.raw(query).first()?.decode(column: "first", as: Date?.self)
    }

    /// Empty for the all-sites view.
    private func siteClause(_ siteKey: String?) -> SQLQueryString {
        guard let siteKey else { return "" }
        return " AND site_key = \(bind: siteKey)"
    }
}
