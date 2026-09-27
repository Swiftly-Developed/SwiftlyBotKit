import Foundation
import Vapor
import SQLKit

/// Decides whether a finished request was a person reading a page.
///
/// Runs on every response, so the cheap checks (method, status, content type,
/// request headers) come first and the user-agent checks last. It reads the
/// user agent to rule a request *out* and never keeps it.
struct PageViewFilter: Sendable {
    let classifier: BotRequestClassifier

    /// Lowercased fragments no browser's user agent contains, and nearly every
    /// automated client's does: bots and crawlers that name themselves, link
    /// preview fetchers, uptime checks, headless browsers and HTTP libraries.
    /// The AI agent catalog is checked separately.
    static let automatedMarkers: [String] = [
        "bot", "crawl", "spider", "slurp", "scrape", "archiver", "headless", "lighthouse",
        "pagespeed", "inspectiontool", "google-", "mediapartners", "pingdom", "uptime", "monitor",
        "preview", "fetch", "http", "curl", "wget", "python", "java", "okhttp", "axios", "node",
        "go-", "ruby", "perl", "php", "phantom", "selenium", "puppeteer", "playwright",
        "externalhit", "whatsapp", "iframely", "embedly", "validator", "checker",
    ]

    /// Real phones whose model name contains a marker.
    static let browserExceptions: [String] = ["cubot"]

    func counts(
        method: HTTPMethod,
        path: String,
        requestHeaders: HTTPHeaders,
        status: HTTPResponseStatus,
        responseHeaders: HTTPHeaders
    ) -> Bool {
        guard method == .GET, (200..<300).contains(status.code) else { return false }
        guard let contentType = responseHeaders.contentType,
              contentType.type.lowercased() == "text", contentType.subType.lowercased() == "html"
        else { return false }
        // An HTMX swap is a fragment of a page already counted.
        if requestHeaders.first(name: "HX-Request") != nil { return false }
        // Browsers that send Fetch Metadata say what the response is for; only
        // a top-level document is a page someone is looking at.
        if let destination = requestHeaders.first(name: "Sec-Fetch-Dest"),
           destination.lowercased() != "document" {
            return false
        }
        // A prefetch or prerender may never be shown.
        for name in ["Sec-Purpose", "Purpose", "X-Moz", "X-Purpose"] {
            if let value = requestHeaders.first(name: name)?.lowercased(),
               value.contains("prefetch") || value.contains("preview") {
                return false
            }
        }
        guard !classifier.isExcluded(path: path) else { return false }
        return Self.isBrowser(userAgent: requestHeaders.first(name: .userAgent), agents: classifier.agents)
    }

    /// Whether the user agent reads as a person's browser: it claims
    /// `Mozilla/` (every browser engine still does), is not an AI agent from
    /// the catalog, and contains none of ``automatedMarkers``.
    static func isBrowser(userAgent: String?, agents: AIAgentMatcher) -> Bool {
        guard let userAgent, !userAgent.isEmpty else { return false }
        var lowered = userAgent.lowercased()
        guard lowered.hasPrefix("mozilla/") else { return false }
        for exception in browserExceptions {
            lowered = lowered.replacingOccurrences(of: exception, with: "")
        }
        if automatedMarkers.contains(where: { lowered.contains($0) }) { return false }
        return agents.match(userAgent: userAgent) == nil
    }
}


/// A page view counter's key: site, path and quarter-hour.
struct PageViewKey: Hashable, Sendable {
    let siteKey: String
    let path: String
    /// Seconds since 1970, a multiple of ``PageViewTally/bucketSeconds``.
    let bucketStart: Int64
}

/// A dimension counter's key: site, local day, dimension, value and page.
struct PageViewDimensionKey: Hashable, Sendable {
    let siteKey: String
    let day: PageViewDay
    let dimension: PageViewDimension
    let value: String
    let path: String
}

/// A pair counter's key: site, local day and two dimension values, the
/// first dimension declared before the second.
struct PageViewPairKey: Hashable, Sendable {
    let siteKey: String
    let day: PageViewDay
    let first: PageViewDimension
    let firstValue: String
    let second: PageViewDimension
    let secondValue: String
}

/// A calendar date as days since 1970-01-01, in whatever zone it was taken
/// in. Integer arithmetic both ways, so no `Calendar` or `DateFormatter` on
/// the request path.
struct PageViewDay: Hashable, Sendable, Comparable {
    let daysSince1970: Int32

    init(daysSince1970: Int32) {
        self.daysSince1970 = daysSince1970
    }

    /// The local date of `date` in `timeZone`.
    init(_ date: Date, in timeZone: TimeZone) {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down)) + Int64(timeZone.secondsFromGMT(for: date))
        let (quotient, remainder) = seconds.quotientAndRemainder(dividingBy: 86_400)
        daysSince1970 = Int32(remainder < 0 ? quotient - 1 : quotient)
    }

    /// `yyyy-MM-dd`, from Howard Hinnant's `civil_from_days`.
    var isoDate: String {
        let z = Int64(daysSince1970) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func pad(_ value: Int64, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    static func < (lhs: PageViewDay, rhs: PageViewDay) -> Bool {
        lhs.daysSince1970 < rhs.daysSince1970
    }
}

/// Counts gathered since the last write, keyed by whatever one table's
/// primary key is.
///
/// A lock rather than an actor, so counting a view on the request path is a
/// synchronous increment with no hop to another executor.
final class CountTally<Key: Hashable & Sendable>: @unchecked Sendable {

    let maximumKeys: Int
    // Guarded by `lock`.
    private let lock = NSLock()
    private var counts: [Key: Int] = [:]
    private var dropped = 0

    init(maximumKeys: Int) {
        self.maximumKeys = max(1, maximumKeys)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Adds one view. Returns `nil` when counted, or the running total of
    /// dropped views when the tally is full and `key` is new.
    func add(_ key: Key) -> Int? {
        locked {
            if let current = counts[key] {
                counts[key] = current + 1
                return nil
            }
            guard counts.count < maximumKeys else {
                dropped += 1
                return dropped
            }
            counts[key] = 1
            return nil
        }
    }

    /// Adds one view to each key, under one lock. Returns the running total
    /// of dropped counts when any key did not fit, else `nil`.
    func add<S: Sequence>(all keys: S) -> Int? where S.Element == Key {
        locked {
            var droppedNow = false
            for key in keys {
                if let current = counts[key] {
                    counts[key] = current + 1
                } else if counts.count < maximumKeys {
                    counts[key] = 1
                } else {
                    dropped += 1
                    droppedNow = true
                }
            }
            return droppedNow ? dropped : nil
        }
    }

    /// Takes every count, leaving the tally empty.
    func drain() -> [Key: Int] {
        locked {
            defer { counts = [:] }
            return counts
        }
    }

    /// Puts counts from a failed write back, as far as there is room. Returns
    /// how many views did not fit.
    func restore(_ restored: [Key: Int]) -> Int {
        locked {
            var lost = 0
            for (key, value) in restored {
                if let current = counts[key] {
                    counts[key] = current + value
                } else if counts.count < maximumKeys {
                    counts[key] = value
                } else {
                    lost += value
                }
            }
            return lost
        }
    }

    var pendingKeys: Int { locked { counts.count } }
}

/// The page view tally, keyed by site, path and quarter-hour.
typealias PageViewTally = CountTally<PageViewKey>

extension CountTally where Key == PageViewKey {
    /// A quarter-hour. Every time zone's offset from UTC is a whole number of
    /// quarter-hours, so every local hour and day boundary the dashboard draws
    /// falls between two of these buckets, never inside one.
    static var bucketSeconds: Int64 { 900 }

    /// The start of the quarter-hour holding `date`.
    static func bucketStart(for date: Date) -> Int64 {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let quotient = seconds / bucketSeconds
        let floored = (seconds % bucketSeconds != 0 && seconds < 0) ? quotient - 1 : quotient
        return floored * bucketSeconds
    }
}

/// Caps how many distinct values each campaign dimension stores per site and
/// day, since anyone can put anything in a `utm_` parameter.
final class CampaignValueCap: @unchecked Sendable {
    private struct Slot: Hashable {
        let siteKey: String
        let day: PageViewDay
        let dimension: PageViewDimension
    }

    static let dimensions: [PageViewDimension] = [.campaignSource, .campaignMedium, .campaignName, .campaignContent]

    let maximum: Int
    // Guarded by `lock`.
    private let lock = NSLock()
    private var seen: [Slot: Set<String>] = [:]
    private var newestDay: PageViewDay?

    init(maximum: Int) {
        self.maximum = max(1, maximum)
    }

    /// `facts` with any campaign value beyond the day's cap replaced by
    /// ``PageViewDimension/other``. `(none)` and `(other)` never use up the
    /// allowance.
    func capped(_ facts: PageViewFacts, siteKey: String, day: PageViewDay) -> PageViewFacts {
        lock.lock()
        defer { lock.unlock() }
        if newestDay.map({ day > $0 }) ?? true {
            newestDay = day
            // Keep yesterday for views counted around midnight; drop older.
            seen = seen.filter { $0.key.day.daysSince1970 >= day.daysSince1970 - 1 }
        }
        var facts = facts
        for dimension in Self.dimensions {
            guard let value = facts[dimension], value != PageViewDimension.none, value != PageViewDimension.other
            else { continue }
            let slot = Slot(siteKey: siteKey, day: day, dimension: dimension)
            var values = seen[slot] ?? []
            if values.contains(value) { continue }
            if values.count < maximum {
                values.insert(value)
                seen[slot] = values
            } else {
                facts.set(dimension, to: PageViewDimension.other)
            }
        }
        return facts
    }
}

/// Counts page views in memory and writes them in batches.
///
/// The flush loop starts with the first counted view, writes every
/// ``BotKitConfiguration/PageViews/flushInterval``, and is stopped with a
/// final write by ``shutdown()``, which `BotKit` registers as a lifecycle
/// handler. A failed write puts its counts back for the next attempt.
///
/// With dimensions on, each view also adds one to a counter per dimension
/// and per pair of dimensions (``PageViewDimension/pairs``), in their own
/// tallies with their own caps, so a burst of new dimension values can never
/// crowd out the page view count itself.
final class PageViewCounter: @unchecked Sendable {
    let tally: PageViewTally
    let dimensionTally: CountTally<PageViewDimensionKey>?
    let pairTally: CountTally<PageViewPairKey>?
    /// With time on page on: its readings, and the pages a reading may name.
    let timeOnPageTally: TimeOnPageTally?
    let knownPaths: KnownPagePaths?
    let campaignCap: CampaignValueCap
    /// The zone a view's day is taken in: the dashboard's.
    let timeZone: TimeZone
    /// Resolved at every flush, never at install: `app.db` traps when no
    /// database is registered, and the app may register it later.
    let database: @Sendable () -> (any SQLDatabase)?
    let flushInterval: TimeInterval
    let logger: Logger

    /// At most this many rows per statement: a handful of arrays of this
    /// length are well inside PostgreSQL's limits, and a quiet site never
    /// gets near it.
    static let rowsPerStatement = 5_000

    // Guarded by `lock`.
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var isShutDown = false
    private var reportedMissingDatabase = false

    init(
        database: @escaping @Sendable () -> (any SQLDatabase)?,
        configuration: BotKitConfiguration.PageViews,
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!,
        logger: Logger
    ) {
        self.tally = PageViewTally(maximumKeys: configuration.maximumPendingCounters)
        let dimensions = configuration.dimensions
        self.dimensionTally = dimensions.isEnabled
            ? CountTally(maximumKeys: dimensions.maximumPendingDimensionCounters) : nil
        self.pairTally = dimensions.isEnabled
            ? CountTally(maximumKeys: dimensions.maximumPendingPairCounters) : nil
        let timeOnPage = configuration.timeOnPage
        self.timeOnPageTally = timeOnPage.isEnabled
            ? TimeOnPageTally(maximumKeys: timeOnPage.maximumPendingCounters) : nil
        self.knownPaths = timeOnPage.isEnabled
            ? KnownPagePaths(maximumPerDay: configuration.maximumPendingCounters) : nil
        self.campaignCap = CampaignValueCap(maximum: dimensions.maximumCampaignValuesPerDay)
        self.timeZone = timeZone
        self.database = database
        self.flushInterval = max(1, configuration.flushInterval.isFinite ? configuration.flushInterval : 10)
        self.logger = logger
    }

    /// Counts one view of `path` on `siteKey` at `date`, and with `facts`,
    /// one per dimension and pair of dimensions. Synchronous and cheap: it
    /// never waits on the database.
    func record(siteKey: String, path: String, facts: PageViewFacts? = nil, at date: Date = Date()) {
        let siteKey = BotTrafficRecorder.storable(siteKey)
        let path = BotTrafficRecorder.storable(path)
        let key = PageViewKey(siteKey: siteKey, path: path, bucketStart: PageViewTally.bucketStart(for: date))
        if let dropped = tally.add(key), dropped == 1 || dropped % 1000 == 0 {
            logger.warning(
                "Dropped a page view: \(tally.maximumKeys) page counters are already waiting to be written (\(dropped) dropped so far). Raise pageViews.maximumPendingCounters, shorten pageViews.flushInterval or check the database."
            )
        }
        if let facts, let dimensionTally, let pairTally {
            recordDimensions(facts, siteKey: siteKey, path: path, date: date,
                             dimensionTally: dimensionTally, pairTally: pairTally)
        }
        knownPaths?.insert(siteKey: siteKey, path: path, day: PageViewDay(date, in: timeZone))
        startLoopIfNeeded()
    }

    /// Adds one time on page reading, when time on page is on and this
    /// process counted a view of `path` today or yesterday. Returns whether
    /// it was kept.
    ///
    /// A trailing slash is ignored when matching: an app that rewrites
    /// `/about/` to `/about` before routing counts the view as `/about`
    /// while the browser reports `/about/`. The reading is stored under the
    /// path the view was counted as, so the two line up on the dashboard.
    @discardableResult
    func recordTimeOnPage(siteKey: String, path: String, seconds: Int, at date: Date = Date()) -> Bool {
        guard let timeOnPageTally, let knownPaths else { return false }
        let siteKey = BotTrafficRecorder.storable(siteKey)
        let day = PageViewDay(date, in: timeZone)
        var candidates = [BotTrafficRecorder.storable(path)]
        if path.count > 1 {
            candidates.append(BotTrafficRecorder.storable(path.hasSuffix("/") ? String(path.dropLast()) : path + "/"))
        }
        guard let path = candidates.first(where: { knownPaths.contains(siteKey: siteKey, path: $0, day: day) }) else {
            return false
        }
        let seconds = min(max(0, seconds), TimeOnPageBand.maximumSeconds)
        let key = TimeOnPageKey(siteKey: siteKey, day: day, path: path, band: TimeOnPageBand(seconds: seconds))
        if let dropped = timeOnPageTally.add(key, seconds: seconds) {
            if dropped == 1 || dropped % 1000 == 0 {
                logger.warning(
                    "Dropped a time on page reading: \(timeOnPageTally.maximumKeys) counters are already waiting to be written (\(dropped) dropped so far). Raise pageViews.timeOnPage.maximumPendingCounters or check the database."
                )
            }
            return false
        }
        startLoopIfNeeded()
        return true
    }

    private func recordDimensions(
        _ facts: PageViewFacts,
        siteKey: String,
        path: String,
        date: Date,
        dimensionTally: CountTally<PageViewDimensionKey>,
        pairTally: CountTally<PageViewPairKey>
    ) {
        let day = PageViewDay(date, in: timeZone)
        let values = campaignCap.capped(facts, siteKey: siteKey, day: day).values
            .map { (dimension: $0.dimension, value: BotTrafficRecorder.storable($0.value, limit: 256)) }
        let dimensionKeys = values.map {
            PageViewDimensionKey(siteKey: siteKey, day: day, dimension: $0.dimension, value: $0.value, path: path)
        }
        if let dropped = dimensionTally.add(all: dimensionKeys), dropped <= values.count || dropped % 1000 < values.count {
            logger.warning(
                "Dropped page view dimension counts: \(dimensionTally.maximumKeys) dimension counters are already waiting to be written (\(dropped) dropped so far). The page views themselves are still counted. Raise pageViews.dimensions.maximumPendingDimensionCounters or check the database."
            )
        }
        var pairKeys: [PageViewPairKey] = []
        pairKeys.reserveCapacity(PageViewDimension.pairs.count)
        let byDimension = Dictionary(uniqueKeysWithValues: values.map { ($0.dimension, $0.value) })
        for (first, second) in PageViewDimension.pairs {
            guard let firstValue = byDimension[first], let secondValue = byDimension[second] else { continue }
            pairKeys.append(PageViewPairKey(siteKey: siteKey, day: day, first: first, firstValue: firstValue,
                                            second: second, secondValue: secondValue))
        }
        if let dropped = pairTally.add(all: pairKeys), dropped <= pairKeys.count || dropped % 1000 < pairKeys.count {
            logger.warning(
                "Dropped page view pair counts: \(pairTally.maximumKeys) pair counters are already waiting to be written (\(dropped) dropped so far). The page views themselves are still counted. Raise pageViews.dimensions.maximumPendingPairCounters or check the database."
            )
        }
    }

    private func startLoopIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard loop == nil, !isShutDown else { return }
        let nanoseconds = UInt64(flushInterval * 1_000_000_000)
        loop = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, let self else { return }
                await self.flush()
            }
        }
    }

    /// Writes every pending count, adding to any row already stored under
    /// the same key (another process's, or an earlier flush's).
    func flush() async {
        let database = database()
        if database == nil {
            var lost = 0
            lost += tally.restore(tally.drain())
            if let dimensionTally { lost += dimensionTally.restore(dimensionTally.drain()) }
            if let pairTally { lost += pairTally.restore(pairTally.drain()) }
            if let timeOnPageTally { lost += timeOnPageTally.restore(timeOnPageTally.drain()) }
            if tally.pendingKeys > 0 || lost > 0, shouldReportMissingDatabase() {
                logger.error(
                    "Page views are enabled but no SQL database is registered for BotKit, so counts are held in memory and not written\(lost > 0 ? " (\(lost) dropped)" : ""). This is logged once."
                )
            }
            return
        }
        guard let database else { return }
        await flush(tally, what: "page view counts", to: database, write: Self.writeViews)
        if let dimensionTally {
            await flush(dimensionTally, what: "page view dimension counts", to: database, write: Self.writeDimensions)
        }
        if let pairTally {
            await flush(pairTally, what: "page view pair counts", to: database, write: Self.writePairs)
        }
        if let timeOnPageTally {
            await flushTimeOnPage(timeOnPageTally, to: database)
        }
    }

    private func flushTimeOnPage(_ tally: TimeOnPageTally, to database: any SQLDatabase) async {
        let pending = tally.drain()
        guard !pending.isEmpty else { return }
        let entries = Array(pending)
        var start = 0
        while start < entries.count {
            let chunk = entries[start..<min(start + Self.rowsPerStatement, entries.count)]
            do {
                try await Self.writeDurations(chunk, to: database)
            } catch {
                let unwritten = Dictionary(uniqueKeysWithValues: entries[start...].map { ($0.key, $0.value) })
                let lost = tally.restore(unwritten)
                logger.warning(
                    "Could not write time on page readings; they are kept for the next attempt\(lost > 0 ? " except \(lost) that no longer fit" : ""): \(error)"
                )
                return
            }
            start += Self.rowsPerStatement
        }
    }

    private static func writeDurations(
        _ chunk: ArraySlice<(key: TimeOnPageKey, value: TimeOnPageTally.Sums)>,
        to database: any SQLDatabase
    ) async throws {
        let sites = chunk.map { $0.key.siteKey }
        let days = chunk.map { $0.key.day.isoDate }
        let paths = chunk.map { $0.key.path }
        let bands = chunk.map { $0.key.band.rawValue }
        let readings = chunk.map { $0.value.readings }
        let seconds = chunk.map { $0.value.seconds }
        try await database.raw("""
            INSERT INTO page_view_durations (site_key, day, path, band, readings, seconds)
            SELECT site_key, day::date, path, band::smallint, readings, seconds FROM unnest(
                \(bind: sites)::text[], \(bind: days)::text[], \(bind: paths)::text[],
                \(bind: bands)::bigint[], \(bind: readings)::bigint[], \(bind: seconds)::bigint[]
            ) AS t(site_key, day, path, band, readings, seconds)
            ON CONFLICT (site_key, day, path, band)
            DO UPDATE SET readings = page_view_durations.readings + EXCLUDED.readings,
                          seconds = page_view_durations.seconds + EXCLUDED.seconds
            """).run()
    }

    private func flush<Key>(
        _ tally: CountTally<Key>,
        what: String,
        to database: any SQLDatabase,
        write: (ArraySlice<(key: Key, value: Int)>, any SQLDatabase) async throws -> Void
    ) async {
        let pending = tally.drain()
        guard !pending.isEmpty else { return }
        let entries = Array(pending)
        var start = 0
        while start < entries.count {
            let chunk = entries[start..<min(start + Self.rowsPerStatement, entries.count)]
            do {
                try await write(chunk, database)
            } catch {
                let unwritten = Dictionary(uniqueKeysWithValues: entries[start...].map { ($0.key, $0.value) })
                let lost = tally.restore(unwritten)
                logger.warning(
                    "Could not write \(what); they are kept for the next attempt\(lost > 0 ? " except \(lost) that no longer fit" : ""): \(error)"
                )
                return
            }
            start += Self.rowsPerStatement
        }
    }

    private static func writeViews(
        _ chunk: ArraySlice<(key: PageViewKey, value: Int)>,
        to database: any SQLDatabase
    ) async throws {
        let sites = chunk.map { $0.key.siteKey }
        let paths = chunk.map { $0.key.path }
        let buckets = chunk.map { Date(timeIntervalSince1970: Double($0.key.bucketStart)) }
        let views = chunk.map { $0.value }
        try await database.raw("""
            INSERT INTO page_view_counts (site_key, path, bucket_start, views)
            SELECT * FROM unnest(
                \(bind: sites)::text[], \(bind: paths)::text[],
                \(bind: buckets)::timestamptz[], \(bind: views)::bigint[]
            )
            ON CONFLICT (site_key, bucket_start, path)
            DO UPDATE SET views = page_view_counts.views + EXCLUDED.views
            """).run()
    }

    private static func writeDimensions(
        _ chunk: ArraySlice<(key: PageViewDimensionKey, value: Int)>,
        to database: any SQLDatabase
    ) async throws {
        let sites = chunk.map { $0.key.siteKey }
        let days = chunk.map { $0.key.day.isoDate }
        let dimensions = chunk.map { $0.key.dimension.rawValue }
        let values = chunk.map { $0.key.value }
        let paths = chunk.map { $0.key.path }
        let views = chunk.map { $0.value }
        try await database.raw("""
            INSERT INTO page_view_dimension_counts (site_key, day, dimension, value, path, views)
            SELECT site_key, day::date, dimension, value, path, views FROM unnest(
                \(bind: sites)::text[], \(bind: days)::text[], \(bind: dimensions)::text[],
                \(bind: values)::text[], \(bind: paths)::text[], \(bind: views)::bigint[]
            ) AS t(site_key, day, dimension, value, path, views)
            ON CONFLICT (site_key, day, dimension, value, path)
            DO UPDATE SET views = page_view_dimension_counts.views + EXCLUDED.views
            """).run()
    }

    private static func writePairs(
        _ chunk: ArraySlice<(key: PageViewPairKey, value: Int)>,
        to database: any SQLDatabase
    ) async throws {
        let sites = chunk.map { $0.key.siteKey }
        let days = chunk.map { $0.key.day.isoDate }
        let firsts = chunk.map { $0.key.first.rawValue }
        let firstValues = chunk.map { $0.key.firstValue }
        let seconds = chunk.map { $0.key.second.rawValue }
        let secondValues = chunk.map { $0.key.secondValue }
        let views = chunk.map { $0.value }
        try await database.raw("""
            INSERT INTO page_view_pair_counts
                (site_key, day, first_dimension, first_value, second_dimension, second_value, views)
            SELECT site_key, day::date, first_dimension, first_value, second_dimension, second_value, views
            FROM unnest(
                \(bind: sites)::text[], \(bind: days)::text[], \(bind: firsts)::text[],
                \(bind: firstValues)::text[], \(bind: seconds)::text[], \(bind: secondValues)::text[],
                \(bind: views)::bigint[]
            ) AS t(site_key, day, first_dimension, first_value, second_dimension, second_value, views)
            ON CONFLICT (site_key, day, first_dimension, second_dimension, first_value, second_value)
            DO UPDATE SET views = page_view_pair_counts.views + EXCLUDED.views
            """).run()
    }

    /// Stops the loop and writes what is left. Views counted afterwards are
    /// still tallied but only written by a later explicit ``flush()``.
    func shutdown() async {
        takeLoopForShutdown()?.cancel()
        await flush()
    }

    private func shouldReportMissingDatabase() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { reportedMissingDatabase = true }
        return !reportedMissingDatabase
    }

    private func takeLoopForShutdown() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        isShutDown = true
        defer { loop = nil }
        return loop
    }
}

/// Writes the last counts when the application shuts down.
struct PageViewLifecycle: LifecycleHandler {
    let counter: PageViewCounter

    func shutdownAsync(_ application: Application) async {
        await counter.shutdown()
    }
}
