import Foundation
import Vapor

/// The IP ranges the big AI operators publish for their own crawlers, so a
/// request claiming to be `ChatGPT-User` can be checked rather than believed.
///
/// Note the asymmetry between vendors, which the dashboard's wording has to
/// respect: OpenAI publishes a **separate list per agent**, so a `ChatGPT-User`
/// hit can be checked against the chatgpt-user ranges specifically. Anthropic
/// publishes **one list for all three Claude agents**, so a verified Claude hit
/// proves "genuinely Anthropic" and the user agent is what says which of the
/// three it was. Both beat taking the header at its word; they are not equally
/// strong, and `BotVerification` does not pretend otherwise.
///
/// Google and Common Crawl want forward-confirmed reverse DNS instead of a
/// range check, which is a DNS round trip per request. Not done here: those two
/// simply stay `.unverified`.
///
/// Each feed is tracked on its own. A feed that fails keeps the ranges it last
/// delivered and is retried with exponential back-off (``minimumRetryDelay``
/// doubling up to ``maximumRetryDelay``), so a vendor outage never turns into
/// one outbound fetch per recorded hit. Several feeds naming the same agent
/// are unioned.
actor CrawlerIPDirectory {

    /// The deadline for one feed fetch, connection to last byte. Vapor's
    /// default HTTP client has none, and a feed that accepts the connection
    /// and then stalls would otherwise hold the refresh forever.
    static let fetchTimeoutSeconds: Int64 = 10

    /// The largest feed body accepted. The real feeds are a few kilobytes.
    static let maximumFeedBytes = 2 * 1024 * 1024

    /// The first retry after a failed fetch, doubled per consecutive failure.
    static let minimumRetryDelay: TimeInterval = 60

    /// The longest wait between retries of a failing feed.
    static let maximumRetryDelay: TimeInterval = 15 * 60

    /// Prefixes shorter than these are refused: no operator publishes a block
    /// anywhere near that broad, and a `/0` in a feed that was served wrong
    /// would verify every spoofer on the internet.
    static let minimumIPv4PrefixLength = 8
    static let minimumIPv6PrefixLength = 16

    /// What one feed has delivered and when it may be fetched again.
    private struct FeedState {
        var ranges: [IPRange] = []
        var lastSuccess: Date?
        var consecutiveFailures = 0
        var retryAfter: Date?
    }

    private let feeds: [CrawlerRangeFeed]
    private let refreshInterval: TimeInterval
    private let clientProvider: @Sendable () -> (any Client)?
    private let logger: Logger
    private var states: [FeedState]
    /// Lowercased agent token to the union of every feed that names it.
    private var ranges: [String: [IPRange]] = [:]
    private var refreshTask: Task<Void, Never>?
    /// Feed URLs whose over-broad prefixes have already been logged.
    private var reportedBroadPrefixes: Set<String> = []

    /// Resolves the HTTP client lazily, on the first fetch, so building the
    /// directory never touches `app.client` (which would freeze the app's
    /// HTTP client configuration at install time).
    init(
        feeds: [CrawlerRangeFeed] = CrawlerRangeFeed.defaults,
        refreshInterval: TimeInterval = BotKitConfiguration.Verification.default.refreshInterval,
        clientProvider: @escaping @Sendable () -> (any Client)?,
        logger: Logger
    ) {
        self.feeds = feeds
        self.refreshInterval = refreshInterval
        self.clientProvider = clientProvider
        self.logger = logger
        self.states = Array(repeating: FeedState(), count: feeds.count)
    }

    init(
        feeds: [CrawlerRangeFeed] = CrawlerRangeFeed.defaults,
        refreshInterval: TimeInterval = BotKitConfiguration.Verification.default.refreshInterval,
        client: any Client,
        logger: Logger
    ) {
        self.init(feeds: feeds, refreshInterval: refreshInterval, clientProvider: { client }, logger: logger)
    }

    /// How much we believe a request that claims to be `agent`.
    ///
    /// While nothing at all is cached, a call awaits the fetch in flight (or
    /// the one it starts): calling `.unverified` then would quietly mislabel
    /// the first minute of every process's traffic. Every fetch has a deadline
    /// of ``fetchTimeoutSeconds``. Once ranges are cached, calls answer from cache and
    /// let a due refresh run behind them.
    func verify(agentToken: String, clientIP: String?) async -> BotVerification {
        await ensureFresh()
        guard let published = ranges[agentToken.lowercased()], !published.isEmpty else {
            return .unverified
        }
        guard let clientIP, let bytes = IPRange.parse(address: clientIP) else {
            return .spoofed
        }
        return published.contains(where: { $0.contains(bytes) }) ? .verified : .spoofed
    }

    private func ensureFresh() async {
        if let refreshTask {
            // A refresh is already in flight. Wait for it only when we have
            // nothing at all to answer from.
            if ranges.isEmpty { await refreshTask.value }
            return
        }
        let due = dueFeeds(now: Date())
        guard !due.isEmpty else { return }
        let task = Task { await self.refresh(due) }
        refreshTask = task
        if ranges.isEmpty {
            await task.value
        }
    }

    /// Feeds never fetched successfully, or older than the refresh interval,
    /// and not waiting out a back-off.
    private func dueFeeds(now: Date) -> [Int] {
        states.indices.filter { index in
            let state = states[index]
            if let retryAfter = state.retryAfter, now < retryAfter { return false }
            guard let lastSuccess = state.lastSuccess else { return true }
            return now.timeIntervalSince(lastSuccess) >= refreshInterval
        }
    }

    private func refresh(_ indices: [Int]) async {
        let client = clientProvider()
        let results = await withTaskGroup(of: (Int, Result<ParsedFeed, any Error>).self) { group in
            for index in indices {
                let url = feeds[index].url
                group.addTask {
                    guard let client else { return (index, .failure(FeedError.noClient)) }
                    do {
                        return (index, .success(try await Self.fetch(url, client: client)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<ParsedFeed, any Error>)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        let now = Date()
        for (index, result) in results {
            let url = feeds[index].url
            switch result {
            case .success(let parsed):
                if !parsed.rejectedBroad.isEmpty, !reportedBroadPrefixes.contains(url) {
                    reportedBroadPrefixes.insert(url)
                    logger.warning(
                        "AI crawler range feed \(url) lists implausibly broad prefixes, which were ignored: \(parsed.rejectedBroad.prefix(5).joined(separator: ", "))"
                    )
                }
                states[index].ranges = parsed.ranges
                states[index].lastSuccess = now
                states[index].consecutiveFailures = 0
                states[index].retryAfter = nil
            case .failure(let error):
                // The ranges this feed delivered before are kept: dropping
                // them would turn every verified hit into a spoof.
                states[index].consecutiveFailures += 1
                let delay = Self.retryDelay(afterFailures: states[index].consecutiveFailures)
                states[index].retryAfter = now.addingTimeInterval(delay)
                logger.warning(
                    "Could not refresh AI crawler ranges from \(url): \(error). Ranges already held for it are kept; retrying in \(Int(delay)) seconds."
                )
            }
        }
        rebuildRanges()
        refreshTask = nil
    }

    /// 1, 2, 4, 8 minutes, then 15 minutes for as long as the feed keeps failing.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        let exponent = min(max(failures - 1, 0), 10)
        return min(minimumRetryDelay * pow(2, Double(exponent)), maximumRetryDelay)
    }

    private func rebuildRanges() {
        var union: [String: [IPRange]] = [:]
        for (index, feed) in feeds.enumerated() where !states[index].ranges.isEmpty {
            for agent in Set(feed.agentTokens.map { $0.lowercased() }) {
                union[agent, default: []].append(contentsOf: states[index].ranges)
            }
        }
        ranges = union
    }

    // MARK: Fetching and decoding

    private enum FeedError: Error, CustomStringConvertible {
        case noClient
        case status(UInt)
        case tooLarge
        case empty

        var description: String {
            switch self {
            case .noClient: return "no HTTP client is available (the application has shut down)"
            case .status(let code): return "the feed answered HTTP \(code)"
            case .tooLarge: return "the feed body is larger than \(CrawlerIPDirectory.maximumFeedBytes) bytes"
            case .empty: return "the feed contains no usable prefixes"
            }
        }
    }

    struct ParsedFeed: Sendable {
        var ranges: [IPRange]
        /// Prefixes dropped by ``minimumIPv4PrefixLength`` and
        /// ``minimumIPv6PrefixLength``.
        var rejectedBroad: [String]
    }

    /// One fetch with a deadline and a size cap.
    ///
    /// Redirects are followed or not according to the app's own HTTP client
    /// configuration (Vapor's `Client` offers no per-request switch); only a
    /// final `200` is accepted, and the broad-prefix filter bounds what a
    /// feed served from the wrong place can do.
    private static func fetch(_ url: String, client: any Client) async throws -> ParsedFeed {
        var headers = HTTPHeaders()
        headers.add(name: .accept, value: "application/json")
        let request = ClientRequest(method: .GET, url: URI(string: url), headers: headers, body: nil, timeout: .seconds(fetchTimeoutSeconds))
        let response = try await client.send(request).get()
        guard response.status == .ok else { throw FeedError.status(response.status.code) }
        if let declared = response.headers.first(name: .contentLength).flatMap(Int.init), declared > maximumFeedBytes {
            throw FeedError.tooLarge
        }
        let body = response.body ?? ByteBuffer()
        guard body.readableBytes <= maximumFeedBytes else { throw FeedError.tooLarge }
        let parsed = try parseFeed(Data(buffer: body))
        guard !parsed.ranges.isEmpty else { throw FeedError.empty }
        return parsed
    }

    /// The ranges in one published feed body.
    ///
    /// Decoded from the raw bytes, never through `response.content`, because
    /// that dispatches on the `Content-Type` header and vendors do not agree on
    /// it: OpenAI serves `chatgpt-user.json` as `application/octet-stream`,
    /// which Vapor rejects with a 415, and for as long as it did every
    /// `ChatGPT-User` hit fell back to `.unverified`. The feeds are all the same
    /// JSON shape whatever they are labelled.
    static func ranges(fromFeed body: Data) throws -> [IPRange] {
        try parseFeed(body).ranges
    }

    /// Throws when the body is not an object with a `prefixes` array. Within
    /// the array decoding is per entry: an entry of the wrong type is skipped,
    /// and one carrying both `ipv4Prefix` and `ipv6Prefix` contributes both.
    static func parseFeed(_ body: Data) throws -> ParsedFeed {
        let entries = try JSONDecoder().decode(PrefixFeed.self, from: body).prefixes
        var parsed = ParsedFeed(ranges: [], rejectedBroad: [])
        parsed.ranges.reserveCapacity(entries.count)
        for entry in entries {
            for cidr in [entry.ipv4Prefix, entry.ipv6Prefix].compactMap({ $0 }) {
                guard let range = IPRange(cidr: cidr) else { continue }
                let minimum = range.isIPv4 ? minimumIPv4PrefixLength : minimumIPv6PrefixLength
                if range.prefixLength < minimum {
                    parsed.rejectedBroad.append(cidr)
                } else {
                    parsed.ranges.append(range)
                }
            }
        }
        return parsed
    }

    private struct PrefixFeed: Decodable {
        let prefixes: [LenientPrefix]
    }

    /// Never throws: anything that is not an object with string prefixes
    /// decodes as an entry with none.
    private struct LenientPrefix: Decodable {
        let ipv4Prefix: String?
        let ipv6Prefix: String?

        private enum CodingKeys: String, CodingKey {
            case ipv4Prefix, ipv6Prefix
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            ipv4Prefix = (try? container?.decodeIfPresent(String.self, forKey: .ipv4Prefix)) ?? nil
            ipv6Prefix = (try? container?.decodeIfPresent(String.self, forKey: .ipv6Prefix)) ?? nil
        }
    }
}
