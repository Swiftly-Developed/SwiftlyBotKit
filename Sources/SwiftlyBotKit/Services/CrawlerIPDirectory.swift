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
actor CrawlerIPDirectory {

    private let feeds: [CrawlerRangeFeed]
    private let refreshInterval: TimeInterval
    private let client: any Client
    private let logger: Logger
    private var ranges: [String: [IPRange]] = [:]
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?

    init(
        feeds: [CrawlerRangeFeed] = CrawlerRangeFeed.defaults,
        refreshInterval: TimeInterval = BotKitConfiguration.Verification.default.refreshInterval,
        client: any Client,
        logger: Logger
    ) {
        self.feeds = feeds
        self.refreshInterval = refreshInterval
        self.client = client
        self.logger = logger
    }

    /// How much we believe a request that claims to be `agent`.
    ///
    /// The first call of the process awaits the fetch: there is nothing
    /// cached to answer from, and calling `.unverified` then would quietly
    /// mislabel the first minute of every process's traffic. Later calls answer
    /// from cache and let a stale refresh run behind them.
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
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < refreshInterval {
            return
        }
        if let refreshTask {
            // A refresh is already in flight. Wait for it only when we have
            // nothing at all to answer from.
            if ranges.isEmpty { await refreshTask.value }
            return
        }
        let task = Task { await self.refresh() }
        refreshTask = task
        if ranges.isEmpty {
            await task.value
        }
    }

    private func refresh() async {
        var collected: [String: [IPRange]] = [:]
        for source in feeds {
            do {
                let response = try await client.get(URI(string: source.url))
                guard response.status == .ok else {
                    logger.warning("AI crawler range feed \(source.url) answered \(response.status.code).")
                    continue
                }
                let parsed = try Self.ranges(fromFeed: Data(buffer: response.body ?? ByteBuffer()))
                guard !parsed.isEmpty else {
                    logger.warning("AI crawler range feed \(source.url) returned no usable prefixes.")
                    continue
                }
                for agent in source.agentTokens { collected[agent.lowercased()] = parsed }
            } catch {
                logger.warning("Could not refresh AI crawler ranges from \(source.url): \(error)")
            }
        }
        // A total failure (network down, every vendor down) must not wipe
        // ranges already held: that would turn every verified hit into a spoof.
        if !collected.isEmpty {
            ranges.merge(collected) { _, new in new }
            lastRefresh = Date()
        }
        refreshTask = nil
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
        try JSONDecoder().decode(PrefixFeed.self, from: body).prefixes.compactMap { entry in
            guard let cidr = entry.ipv4Prefix ?? entry.ipv6Prefix else { return nil }
            return IPRange(cidr: cidr)
        }
    }

    private struct PrefixFeed: Decodable {
        struct Prefix: Decodable {
            let ipv4Prefix: String?
            let ipv6Prefix: String?
        }
        let prefixes: [Prefix]
    }
}
