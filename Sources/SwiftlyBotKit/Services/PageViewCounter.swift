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

/// The counts gathered since the last write, keyed by site, path and
/// quarter-hour.
///
/// A lock rather than an actor, so counting a view on the request path is a
/// synchronous increment with no hop to another executor.
final class PageViewTally: @unchecked Sendable {

    struct Key: Hashable, Sendable {
        let siteKey: String
        let path: String
        /// Seconds since 1970, a multiple of ``PageViewTally/bucketSeconds``.
        let bucketStart: Int64
    }

    /// A quarter-hour. Every time zone's offset from UTC is a whole number of
    /// quarter-hours, so every local hour and day boundary the dashboard draws
    /// falls between two of these buckets, never inside one.
    static let bucketSeconds: Int64 = 900

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

    /// The start of the quarter-hour holding `date`.
    static func bucketStart(for date: Date) -> Int64 {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let quotient = seconds / bucketSeconds
        let floored = (seconds % bucketSeconds != 0 && seconds < 0) ? quotient - 1 : quotient
        return floored * bucketSeconds
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

/// Counts page views in memory and writes them in batches.
///
/// The flush loop starts with the first counted view, writes every
/// ``BotKitConfiguration/PageViews/flushInterval``, and is stopped with a
/// final write by ``shutdown()``, which `BotKit` registers as a lifecycle
/// handler. A failed write puts its counts back for the next attempt.
final class PageViewCounter: @unchecked Sendable {
    let tally: PageViewTally
    /// Resolved at every flush, never at install: `app.db` traps when no
    /// database is registered, and the app may register it later.
    let database: @Sendable () -> (any SQLDatabase)?
    let flushInterval: TimeInterval
    let logger: Logger

    /// At most this many rows per statement: four arrays of this length are
    /// well inside PostgreSQL's limits, and a quiet site never gets near it.
    static let rowsPerStatement = 5_000

    // Guarded by `lock`.
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var isShutDown = false
    private var reportedMissingDatabase = false

    init(database: @escaping @Sendable () -> (any SQLDatabase)?, configuration: BotKitConfiguration.PageViews, logger: Logger) {
        self.tally = PageViewTally(maximumKeys: configuration.maximumPendingCounters)
        self.database = database
        self.flushInterval = max(1, configuration.flushInterval.isFinite ? configuration.flushInterval : 10)
        self.logger = logger
    }

    /// Counts one view of `path` on `siteKey` at `date`. Synchronous and
    /// cheap: it never waits on the database.
    func record(siteKey: String, path: String, at date: Date = Date()) {
        let key = PageViewTally.Key(
            siteKey: BotTrafficRecorder.storable(siteKey),
            path: BotTrafficRecorder.storable(path),
            bucketStart: PageViewTally.bucketStart(for: date)
        )
        if let dropped = tally.add(key), dropped == 1 || dropped % 1000 == 0 {
            logger.warning(
                "Dropped a page view: \(tally.maximumKeys) page counters are already waiting to be written (\(dropped) dropped so far). Raise pageViews.maximumPendingCounters, shorten pageViews.flushInterval or check the database."
            )
        }
        startLoopIfNeeded()
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

    /// Writes every pending count, adding to any row already stored for the
    /// same site, path and quarter-hour (another process's, or an earlier
    /// flush's).
    func flush() async {
        let pending = tally.drain()
        guard !pending.isEmpty else { return }
        guard let database = database() else {
            let lost = tally.restore(pending)
            if shouldReportMissingDatabase() {
                logger.error(
                    "Page views are enabled but no SQL database is registered for BotKit, so counts are held in memory and not written\(lost > 0 ? " (\(lost) dropped)" : ""). This is logged once."
                )
            }
            return
        }
        let entries = Array(pending)
        var start = 0
        while start < entries.count {
            let chunk = entries[start..<min(start + Self.rowsPerStatement, entries.count)]
            do {
                try await write(chunk, to: database)
            } catch {
                let unwritten = Dictionary(uniqueKeysWithValues: entries[start...].map { ($0.key, $0.value) })
                let lost = tally.restore(unwritten)
                logger.warning(
                    "Could not write page view counts; they are kept for the next attempt\(lost > 0 ? " except \(lost) view(s) that no longer fit" : ""): \(error)"
                )
                return
            }
            start += Self.rowsPerStatement
        }
    }

    private func write(
        _ chunk: ArraySlice<(key: PageViewTally.Key, value: Int)>,
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
