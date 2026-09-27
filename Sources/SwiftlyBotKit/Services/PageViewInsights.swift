import Foundation
import SQLKit

/// One period's headline figures for the Page views tab's tiles.
struct PageViewSummary: Sendable, Equatable {
    /// People's page views, from `page_view_counts`.
    var peopleViews = 0
    /// Distinct paths people read.
    var peoplePages = 0
    /// AI agent page reads, as ``PageViewQueries/agentReadFilter`` counts them.
    var agentReads = 0
    /// Distinct paths AI agents read.
    var agentPages = 0
    /// Distinct IP hashes behind those reads: addresses, not organisations,
    /// since one crawler fleet spans many.
    var agentAddresses = 0
    /// Distinct agents (GPTBot, ClaudeBot, ...) behind those reads.
    var agents = 0
    /// People arriving from an AI assistant's answer.
    var referrals = 0
}

/// The tiles' figures for the window and for the equally long stretch just
/// before it, so each tile can say how it moved.
struct PageViewComparison: Sendable {
    var current = PageViewSummary()
    var previous = PageViewSummary()
    /// People were counted for the whole previous period. When counting began
    /// later, their change is unknown rather than a leap from zero.
    var peopleComparable = false
    /// The same for AI agents: recording had begun before the previous
    /// period started.
    var agentsComparable = false
}

/// Time on page over the chart's days.
struct TimeOnPageData: Sendable, Equatable {
    struct Sums: Sendable, Equatable {
        var readings = 0
        var seconds = 0

        /// Whole seconds, or `nil` with no readings.
        var average: Int? { readings > 0 ? Int((Double(seconds) / Double(readings)).rounded()) : nil }
    }

    /// Readings per ``TimeOnPageBand``, in band order.
    var bands: [Int] = Array(repeating: 0, count: TimeOnPageBand.allCases.count)
    var total = Sums()
    var pages: [String: Sums] = [:]
    /// Stored per day: on the 24-hour range this covers yesterday and today.
    var isDailyFallback = false

    /// The band holding the middle reading.
    var medianBand: TimeOnPageBand? {
        guard total.readings > 0 else { return nil }
        var seen = 0
        for band in TimeOnPageBand.allCases {
            seen += bands[band.rawValue]
            if seen * 2 >= total.readings { return band }
        }
        return .over10m
    }

    /// Share of readings under ten seconds: people who glanced and left.
    var glanceShare: Double? {
        guard total.readings > 0 else { return nil }
        return Double(bands[TimeOnPageBand.under10s.rawValue]) / Double(total.readings)
    }
}

/// A ranked list from the daily dimension counters: top referrers, countries
/// or landing pages.
struct PageViewRanking: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        let value: String
        let count: Int
    }

    var rows: [Row] = []
    /// Everything the ranking is a share of, including what it folds away.
    var total = 0
    /// Views in values under the small-cell threshold, folded together.
    var folded = 0
    var isDailyFallback = false
}

extension PageViewQueries {

    /// How many rows each ranking shows.
    static let rankingLimit = 10

    // MARK: - Tiles

    /// The window's figures and the previous period's: the same length of
    /// time ending where the window starts.
    func comparison(range: BotDateRange, siteKey: String?, now: Date = Date()) async throws -> PageViewComparison {
        let start = range.window(now: now, in: timeZone).start
        let previousStart = start.addingTimeInterval(-now.timeIntervalSince(start))
        var comparison = PageViewComparison()
        comparison.current = try await summary(from: start, until: nil, siteKey: siteKey)
        comparison.previous = try await summary(from: previousStart, until: start, siteKey: siteKey)
        if let first = try await firstCountedView(siteKey: siteKey) {
            comparison.peopleComparable = first <= previousStart
        }
        if let first = try await firstAgentRead(siteKey: siteKey) {
            comparison.agentsComparable = first <= previousStart
        }
        return comparison
    }

    func summary(from start: Date, until end: Date?, siteKey: String?) async throws -> PageViewSummary {
        var summary = PageViewSummary()
        var people: SQLQueryString = """
        SELECT COALESCE(SUM(views), 0)::bigint AS views, COUNT(DISTINCT path) AS pages
        FROM page_view_counts
        WHERE bucket_start >= \(bind: start)
        """
        if let end { people += " AND bucket_start < \(bind: end)" }
        people += siteClause(siteKey)
        if let row = try await database.raw(people).first() {
            summary.peopleViews = (try? row.decode(column: "views", as: Int.self)) ?? 0
            summary.peoplePages = (try? row.decode(column: "pages", as: Int.self)) ?? 0
        }

        let read = Self.agentReadFilter
        var agents: SQLQueryString = """
        SELECT COUNT(*) FILTER (WHERE \(unsafeRaw: read)) AS reads,
               COUNT(DISTINCT path) FILTER (WHERE \(unsafeRaw: read)) AS pages,
               COUNT(DISTINCT ip_hash) FILTER (WHERE \(unsafeRaw: read)) AS addresses,
               COUNT(DISTINCT agent_name) FILTER (WHERE \(unsafeRaw: read)) AS agents,
               COUNT(*) FILTER (WHERE referrer_platform IS NOT NULL) AS referrals
        FROM ai_bot_visits
        WHERE created_at >= \(bind: start)
        """
        if let end { agents += " AND created_at < \(bind: end)" }
        agents += siteClause(siteKey)
        if let row = try await database.raw(agents).first() {
            summary.agentReads = (try? row.decode(column: "reads", as: Int.self)) ?? 0
            summary.agentPages = (try? row.decode(column: "pages", as: Int.self)) ?? 0
            summary.agentAddresses = (try? row.decode(column: "addresses", as: Int.self)) ?? 0
            summary.agents = (try? row.decode(column: "agents", as: Int.self)) ?? 0
            summary.referrals = (try? row.decode(column: "referrals", as: Int.self)) ?? 0
        }
        return summary
    }

    /// When recording first wrote a row for this site (or any site).
    private func firstAgentRead(siteKey: String?) async throws -> Date? {
        var query: SQLQueryString = "SELECT MIN(created_at) AS first FROM ai_bot_visits WHERE TRUE"
        query += siteClause(siteKey)
        return try await database.raw(query).first()?.decode(column: "first", as: Date?.self)
    }

    // MARK: - Daily tables

    /// The first local day a daily table is read from: the window's first
    /// day, or yesterday on the 24-hour range. `timeZone` must be the zone
    /// the counter stored days in.
    func firstDay(for range: BotDateRange, now: Date) -> String? {
        let window = range.isHourly
            ? BotDateRange.week.window(now: now, in: timeZone).suffix(2)
            : range.window(now: now, in: timeZone)
        return window.buckets.first.map { PageViewDay(daysSince1970: Int32($0.key)).isoDate }
    }

    /// Time on page over the range's days, with each of `paths`' own sums.
    func timeOnPage(range: BotDateRange, siteKey: String?, paths: [String], now: Date = Date()) async throws -> TimeOnPageData {
        var data = TimeOnPageData()
        data.isDailyFallback = range.isHourly
        guard let firstDay = firstDay(for: range, now: now) else { return data }
        var bands: SQLQueryString = """
        SELECT band, SUM(readings)::bigint AS readings, SUM(seconds)::bigint AS seconds
        FROM page_view_durations
        WHERE day >= \(bind: firstDay)::date
        """
        bands += siteClause(siteKey)
        bands += " GROUP BY band"
        for row in try await database.raw(bands).all() {
            guard let band = try? row.decode(column: "band", as: Int.self),
                  data.bands.indices.contains(band),
                  let readings = try? row.decode(column: "readings", as: Int.self),
                  let seconds = try? row.decode(column: "seconds", as: Int.self)
            else { continue }
            data.bands[band] += readings
            data.total.readings += readings
            data.total.seconds += seconds
        }
        guard data.total.readings > 0, !paths.isEmpty else { return data }
        var pages: SQLQueryString = """
        SELECT path, SUM(readings)::bigint AS readings, SUM(seconds)::bigint AS seconds
        FROM page_view_durations
        WHERE day >= \(bind: firstDay)::date AND path = ANY(\(bind: paths)::text[])
        """
        pages += siteClause(siteKey)
        pages += " GROUP BY path"
        for row in try await database.raw(pages).all() {
            guard let path = try? row.decode(column: "path", as: String.self),
                  let readings = try? row.decode(column: "readings", as: Int.self),
                  let seconds = try? row.decode(column: "seconds", as: Int.self)
            else { continue }
            data.pages[path] = .init(readings: readings, seconds: seconds)
        }
        return data
    }

    /// The most frequent values of `dimension` over the range's days.
    /// Values under `smallCellThreshold` are folded into one count, so the
    /// list never points at a handful of readers. Values in `excluding` are
    /// left out of the rows and the total alike.
    func ranking(
        _ dimension: PageViewDimension,
        range: BotDateRange,
        siteKey: String?,
        excluding: [String] = [],
        smallCellThreshold: Int,
        now: Date = Date()
    ) async throws -> PageViewRanking {
        var ranking = PageViewRanking()
        ranking.isDailyFallback = range.isHourly
        guard let firstDay = firstDay(for: range, now: now) else { return ranking }
        var query: SQLQueryString = """
        SELECT value, SUM(views)::bigint AS n
        FROM page_view_dimension_counts
        WHERE dimension = \(bind: dimension.rawValue) AND day >= \(bind: firstDay)::date
          AND NOT (value = ANY(\(bind: excluding)::text[]))
        """
        query += siteClause(siteKey)
        query += " GROUP BY value ORDER BY n DESC, value"
        for row in try await database.raw(query).all() {
            guard let value = try? row.decode(column: "value", as: String.self),
                  let n = try? row.decode(column: "n", as: Int.self)
            else { continue }
            ranking.total += n
            if n < smallCellThreshold {
                ranking.folded += n
            } else if ranking.rows.count < Self.rankingLimit {
                ranking.rows.append(.init(value: value, count: n))
            } else {
                ranking.folded += n
            }
        }
        return ranking
    }

    /// The pages people opened first: views with no previous page on the
    /// same site, per page. Paths are what the Most-read list already shows,
    /// so nothing is folded.
    func landingPages(range: BotDateRange, siteKey: String?, now: Date = Date()) async throws -> PageViewRanking {
        var ranking = PageViewRanking()
        ranking.isDailyFallback = range.isHourly
        guard let firstDay = firstDay(for: range, now: now) else { return ranking }
        var query: SQLQueryString = """
        SELECT path, SUM(views)::bigint AS n
        FROM page_view_dimension_counts
        WHERE dimension = \(bind: PageViewDimension.previousPage.rawValue)
          AND value = \(bind: PageViewDimension.none) AND day >= \(bind: firstDay)::date
        """
        query += siteClause(siteKey)
        query += " GROUP BY path ORDER BY n DESC, path"
        for row in try await database.raw(query).all() {
            guard let path = try? row.decode(column: "path", as: String.self),
                  let n = try? row.decode(column: "n", as: Int.self)
            else { continue }
            ranking.total += n
            if ranking.rows.count < Self.rankingLimit {
                ranking.rows.append(.init(value: path, count: n))
            } else {
                ranking.folded += n
            }
        }
        return ranking
    }
}
