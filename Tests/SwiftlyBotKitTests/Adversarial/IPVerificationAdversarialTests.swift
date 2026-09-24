import XCTest
import Vapor
import XCTVapor
import NIOCore
@testable import SwiftlyBotKit

// Adversarial review of client IP extraction and IP-range verification: the
// code that decides whether a hit is `verified`, `unverified` or `spoofed`.
//
// Every test asserts the correct, secure behaviour. A failing test is a
// finding, not a broken test.

// MARK: - Fixtures

/// Published ranges used throughout. Each agent gets its own blocks so a
/// cross-agent claim is detectable.
private enum Fixture {
    static let gptBotURL = "https://feeds.test/gptbot.json"
    static let chatGPTUserURL = "https://feeds.test/chatgpt-user.json"
    static let claudeURL = "https://feeds.test/claude.json"

    static let gptBotV4 = "20.171.206.0/24"
    static let gptBotV6 = "2600:1f1c::/32"
    static let chatGPTUserV4 = "23.98.142.176/28"
    static let chatGPTUserV6 = "2a06:98c0:3600::/48"
    static let claudeV4 = "160.79.104.0/23"

    static let gptBotIP = "20.171.206.10"
    static let chatGPTUserIP = "23.98.142.180"
    static let claudeIP = "160.79.105.7"
    static let attackerIP = "198.51.100.7"

    static let gptBotUA = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)"
    static let chatGPTUserUA = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot"
    static let claudeBotUA = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"
    static let claudeUserUA = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-User/1.0; +Claude-User@anthropic.com)"

    static let feeds: [CrawlerRangeFeed] = [
        .init(url: gptBotURL, agentTokens: ["GPTBot"]),
        .init(url: chatGPTUserURL, agentTokens: ["ChatGPT-User"]),
        .init(url: claudeURL, agentTokens: ["ClaudeBot", "Claude-User", "Claude-SearchBot"]),
    ]

    static func feedBody(v4: [String] = [], v6: [String] = []) -> String {
        let entries = v4.map { #"{"ipv4Prefix": "\#($0)"}"# } + v6.map { #"{"ipv6Prefix": "\#($0)"}"# }
        return #"{"creationTime": "2026-09-23T00:00:00.000000", "prefixes": [\#(entries.joined(separator: ","))]}"#
    }

    static func healthyBody(for url: String) -> String? {
        switch url {
        case gptBotURL: return feedBody(v4: [gptBotV4], v6: [gptBotV6])
        case chatGPTUserURL: return feedBody(v4: [chatGPTUserV4], v6: [chatGPTUserV6])
        case claudeURL: return feedBody(v4: [claudeV4])
        default: return nil
        }
    }
}

// MARK: - Stub client

/// A `Client` that never touches the network. `CrawlerIPDirectory` takes
/// `any Client`, which is the seam these tests use.
private final class StubFeedClient: Client, @unchecked Sendable {
    typealias Handler = @Sendable (ClientRequest) async throws -> ClientResponse

    let eventLoop: any EventLoop
    private let lock = NSLock()
    private var handler: Handler
    private var sent: [ClientRequest] = []

    init(eventLoop: any EventLoop, handler: @escaping Handler) {
        self.eventLoop = eventLoop
        self.handler = handler
    }

    /// Serves every fixture feed healthily.
    convenience init(healthyOn eventLoop: any EventLoop) {
        self.init(eventLoop: eventLoop) { request in
            guard let body = Fixture.healthyBody(for: request.url.string) else {
                return StubFeedClient.response(.notFound, "")
            }
            return StubFeedClient.response(.ok, body)
        }
    }

    var requests: [ClientRequest] { lock.withLock { sent } }
    var requestCount: Int { lock.withLock { sent.count } }

    func setHandler(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let handler = lock.withLock { () -> Handler in
            sent.append(request)
            return self.handler
        }
        return eventLoop.makeFutureWithTask { try await handler(request) }
    }

    static func response(_ status: HTTPResponseStatus, _ body: String, contentType: String = "application/octet-stream") -> ClientResponse {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: contentType)
        return ClientResponse(status: status, headers: headers, body: ByteBuffer(string: body))
    }
}

private struct StubNetworkError: Error {}

// MARK: - Tests

final class IPVerificationAdversarialTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    // MARK: Helpers

    private func request(forwardedFor: [String] = [], remote: String? = "10.0.0.9") throws -> Request {
        var headers = HTTPHeaders()
        for line in forwardedFor { headers.add(name: .xForwardedFor, value: line) }
        return Request(
            application: app,
            headers: headers,
            remoteAddress: try remote.map { try SocketAddress(ipAddress: $0, port: 443) },
            on: app.eventLoopGroup.next()
        )
    }

    private func directory(
        _ client: StubFeedClient,
        feeds: [CrawlerRangeFeed] = Fixture.feeds,
        refreshInterval: TimeInterval = 3600
    ) -> CrawlerIPDirectory {
        CrawlerIPDirectory(feeds: feeds, refreshInterval: refreshInterval, client: client, logger: app.logger)
    }

    /// The recorder's own decision, minus the database write: classify the
    /// user agent, extract the client IP with `strategy`, verify.
    private func verdict(
        userAgent: String,
        forwardedFor: [String] = [],
        remote: String? = "10.0.0.9",
        strategy: ClientIPStrategy = .lastForwardedFor,
        directory: CrawlerIPDirectory
    ) async throws -> BotVerification? {
        let classifier = BotRequestClassifier(configuration: BotKitConfiguration())
        guard let agent = classifier.agent(userAgent: userAgent) else { return nil }
        let ip = strategy.clientIP(for: try request(forwardedFor: forwardedFor, remote: remote))
        return await directory.verify(agentToken: agent.token, clientIP: ip)
    }

    // MARK: - X-Forwarded-For parsing

    func testEmptyEntriesAndWhitespaceAreIgnored() throws {
        let cases: [(String, String)] = [
            ("1.1.1.1,,203.0.113.7", "203.0.113.7"),
            ("  1.1.1.1 ,   203.0.113.7  ", "203.0.113.7"),
            ("1.1.1.1,\t203.0.113.7\t", "203.0.113.7"),
            ("1.1.1.1, 203.0.113.7,", "203.0.113.7"),
            ("1.1.1.1, 203.0.113.7, , ,", "203.0.113.7"),
        ]
        for (header, expected) in cases {
            let req = try request(forwardedFor: [header])
            XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: req), expected, "XFF: \(header)")
        }
    }

    /// A header of nothing but separators carries no address: fall back to
    /// the socket rather than returning an empty string.
    func testOnlySeparatorsFallsBackToTheSocket() throws {
        for header in [",", ",,,", " , , ", "\t,\t", ""] {
            let req = try request(forwardedFor: [header])
            XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: req), "10.0.0.9", "XFF: \(header.debugDescription)")
            XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 3).clientIP(for: req), "10.0.0.9")
        }
    }

    func testTrustedProxyCountBoundaries() throws {
        let req = try request(forwardedFor: ["1.1.1.1, 203.0.113.7, 198.51.100.2"])
        for n in [0, -1, Int.min] {
            XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: n).clientIP(for: req), "10.0.0.9", "n = \(n)")
        }
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 3).clientIP(for: req), "1.1.1.1")
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 4).clientIP(for: req), "1.1.1.1")
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: Int.max).clientIP(for: req), "1.1.1.1")
    }

    /// Several header lines are one list, and counting from the right crosses
    /// line boundaries.
    func testMultipleHeaderLinesAreCountedAsOneList() throws {
        let req = try request(forwardedFor: ["20.171.206.10, 1.1.1.1", "203.0.113.7", "198.51.100.2"])
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: req), "198.51.100.2")
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 2).clientIP(for: req), "203.0.113.7")
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 3).clientIP(for: req), "1.1.1.1")
    }

    /// Some proxies (Azure App Service, some ingress controllers) append
    /// `ip:port`. A genuine crawler behind one must not be filed as a spoof,
    /// so the port should be stripped before verification.
    func testPortIsStrippedFromIPv4Entry() throws {
        let req = try request(forwardedFor: ["20.171.206.10:51234"])
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: req), "20.171.206.10")
    }

    func testBracketedIPv6EntryIsUnwrapped() throws {
        let withPort = try request(forwardedFor: ["[2600:1f1c::5]:443"])
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: withPort), "2600:1f1c::5")
        let bare = try request(forwardedFor: ["[2600:1f1c::5]"])
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: bare), "2600:1f1c::5")
    }

    /// A plain unbracketed IPv6 entry contains colons but no port; stripping a
    /// port must not truncate it.
    func testUnbracketedIPv6EntryIsLeftWhole() throws {
        let req = try request(forwardedFor: ["2600:1f1c::5"])
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: req), "2600:1f1c::5")
    }

    /// Unix sockets and some test harnesses have no peer address.
    func testNoPeerAddressGivesNoClientIP() throws {
        let req = try request(remote: nil)
        XCTAssertNil(ClientIPStrategy.remoteAddress.clientIP(for: req))
        XCTAssertNil(ClientIPStrategy.lastForwardedFor.clientIP(for: req))
        XCTAssertNil(ClientIPStrategy.forwardedFor(trustedProxies: 0).clientIP(for: req))
    }

    /// 100k entries must stay cheap: this runs on every recorded request.
    func testHugeForwardedForHeaderIsHandledQuickly() throws {
        let header = (0..<100_000).map { "10.\($0 >> 16 & 255).\($0 >> 8 & 255).\($0 & 255)" }.joined(separator: ", ")
        let req = try request(forwardedFor: [header + ", 203.0.113.7"])
        let start = Date()
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: req), "203.0.113.7")
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 2).clientIP(for: req), "10.1.134.159")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    // MARK: - Address parsing

    /// `020.001.002.003` is 20.1.2.3 to some parsers and 16.1.2.3 to others.
    /// Anything ambiguous must be rejected, never silently read one way.
    func testLeadingZeroOctetsAreRejected() {
        XCTAssertNil(IPRange.parse(address: "020.001.002.003"))
        XCTAssertNil(IPRange.parse(address: "020.171.206.010"))
        XCTAssertFalse(IPRange(cidr: Fixture.gptBotV4)!.contains("020.171.206.010"))
    }

    func testNonDottedQuadFormsAreRejected() {
        for form in ["335544320", "0x14ABCE0A", "20.171.206", "20.171", "0x14.0xab.0xce.0x0a",
                     "20.171.206.10.", "20.171.206.256", "-20.171.206.10", "20.171.206.10/32"] {
            XCTAssertNil(IPRange.parse(address: form), form)
        }
    }

    func testWhitespaceInsideAnAddressIsRejected() {
        for form in [" 20.171.206.10", "20.171.206.10 ", "20.171.206.10\n", "20.171.206.10\0", "20.171.206.10\r\n"] {
            XCTAssertNil(IPRange.parse(address: form), form.debugDescription)
        }
    }

    func testIPv6SpellingsAllMatch() {
        let range = IPRange(cidr: Fixture.gptBotV6)!
        XCTAssertTrue(range.contains("2600:1f1c::5"))
        XCTAssertTrue(range.contains("2600:1F1C::5"))
        XCTAssertTrue(range.contains("2600:1f1c:0000:0000:0000:0000:0000:0005"))
        XCTAssertTrue(range.contains("2600:1f1c:0:0:0:0:0:5"))
    }

    /// A link-local address with a zone id is never a crawler, and must not
    /// crash or match anything.
    func testZoneIDsNeverMatch() {
        XCTAssertNil(IPRange.parse(address: "fe80::1%en0"))
        XCTAssertFalse(IPRange(cidr: "fe80::/10")!.contains("fe80::1%en0"))
        XCTAssertFalse(IPRange(cidr: Fixture.gptBotV6)!.contains("2600:1f1c::5%1"))
    }

    /// Only the IPv4-mapped form (`::ffff:a.b.c.d`) is the same host as its
    /// IPv4 address. The deprecated IPv4-compatible form, SIIT, NAT64 and 6to4
    /// embed an IPv4 address but are different hosts on the wire and must
    /// never borrow a v4 block's trust.
    func testOnlyIPv4MappedFormBorrowsIPv4Trust() {
        let range = IPRange(cidr: Fixture.gptBotV4)!
        XCTAssertTrue(range.contains("::ffff:20.171.206.10"))
        XCTAssertTrue(range.contains("::FFFF:20.171.206.10"))
        XCTAssertTrue(range.contains("::ffff:14ab:ce0a"))
        XCTAssertTrue(range.contains("0:0:0:0:0:ffff:14ab:ce0a"))

        XCTAssertFalse(range.contains("::20.171.206.10"), "IPv4-compatible")
        XCTAssertFalse(range.contains("::ffff:0:20.171.206.10"), "SIIT IPv4-translated")
        XCTAssertFalse(range.contains("64:ff9b::20.171.206.10"), "NAT64")
        XCTAssertFalse(range.contains("2002:14ab:ce0a::1"), "6to4")
        XCTAssertFalse(range.contains("::1:ffff:20.171.206.10"))
    }

    // MARK: - CIDR parsing

    func testPrefixLengthBounds() {
        XCTAssertNotNil(IPRange(cidr: "0.0.0.0/0"))
        XCTAssertNotNil(IPRange(cidr: "20.171.206.10/32"))
        XCTAssertNotNil(IPRange(cidr: "::/0"))
        XCTAssertNotNil(IPRange(cidr: "2600:1f1c::5/128"))
        XCTAssertTrue(IPRange(cidr: "2600:1f1c::5/128")!.contains("2600:1f1c::5"))
        XCTAssertFalse(IPRange(cidr: "2600:1f1c::5/128")!.contains("2600:1f1c::4"))

        for bad in ["20.171.206.0/33", "2600:1f1c::/129", "20.171.206.0/-1", "20.171.206.0/",
                    "/24", "/", "20.171.206.0/24/8", "20.171.206.0/ 24", "20.171.206.0/24 ",
                    "20.171.206.0/99999999999999999999", "20.171.206.0/0x18", "20.171.206.0\\24",
                    "::ffff:20.171.206.0/120"] {
            XCTAssertNil(IPRange(cidr: bad), bad)
        }
    }

    /// `20.171.206.10/24` has host bits set. Both sides are masked, so it
    /// means the same block as `20.171.206.0/24`.
    func testHostBitsSetStillMeanTheBlock() {
        let range = IPRange(cidr: "20.171.206.10/24")!
        XCTAssertTrue(range.contains("20.171.206.0"))
        XCTAssertTrue(range.contains("20.171.206.255"))
        XCTAssertFalse(range.contains("20.171.207.0"))
        XCTAssertFalse(range.contains("20.171.205.255"))
    }

    func testIPv6PrefixesThatAreNotByteAligned() {
        let r31 = IPRange(cidr: "2600:1f1c::/31")!
        XCTAssertTrue(r31.contains("2600:1f1d:ffff::1"))
        XCTAssertFalse(r31.contains("2600:1f1e::1"))
        XCTAssertFalse(r31.contains("2600:1f1b:ffff::1"))

        let r33 = IPRange(cidr: "2600:1f1c::/33")!
        XCTAssertTrue(r33.contains("2600:1f1c:7fff::1"))
        XCTAssertFalse(r33.contains("2600:1f1c:8000::1"))

        let r127 = IPRange(cidr: "2600:1f1c::4/127")!
        XCTAssertTrue(r127.contains("2600:1f1c::5"))
        XCTAssertFalse(r127.contains("2600:1f1c::6"))

        let r1 = IPRange(cidr: "128.0.0.0/1")!
        XCTAssertTrue(r1.contains("255.255.255.255"))
        XCTAssertFalse(r1.contains("127.255.255.255"))
    }

    func testFamiliesNeverCross() {
        XCTAssertFalse(IPRange(cidr: "::/0")!.contains("20.171.206.10"))
        XCTAssertFalse(IPRange(cidr: "0.0.0.0/0")!.contains("2600:1f1c::5"))
        // Mapped addresses fold to v4, so an IPv6 catch-all must not claim them.
        XCTAssertFalse(IPRange(cidr: "::/0")!.contains("::ffff:20.171.206.10"))
    }

    // MARK: - Feed decoding

    /// One entry with a wrong type (a vendor typo, a number) should cost that
    /// entry, not every range in the feed.
    func testOneMistypedEntryDoesNotDiscardTheFeed() throws {
        let body = Data(#"{"prefixes": [{"ipv4Prefix": 42}, {"ipv4Prefix": "20.171.206.0/24"}]}"#.utf8)
        let ranges = try CrawlerIPDirectory.ranges(fromFeed: body)
        XCTAssertEqual(ranges.count, 1)
    }

    /// An entry carrying both keys should contribute both blocks, not only the
    /// IPv4 one.
    func testEntryWithBothFamiliesKeepsBoth() throws {
        let body = Data(#"{"prefixes": [{"ipv4Prefix": "20.171.206.0/24", "ipv6Prefix": "2600:1f1c::/32"}]}"#.utf8)
        let ranges = try CrawlerIPDirectory.ranges(fromFeed: body)
        XCTAssertTrue(ranges.contains { $0.contains("20.171.206.10") })
        XCTAssertTrue(ranges.contains { $0.contains("2600:1f1c::5") })
    }

    /// Google-style feeds carry extra top-level keys; an AWS-style feed uses
    /// other key names. Neither may crash; the unknown shape yields nothing.
    func testForeignFeedShapesDegradeToNothing() throws {
        let google = Data(#"{"syncToken": "1", "creationTime": "x", "prefixes": [{"ipv6Prefix": "2001:4860:4801:10::/64"}, {"ipv4Prefix": "66.249.64.0/27"}]}"#.utf8)
        XCTAssertEqual(try CrawlerIPDirectory.ranges(fromFeed: google).count, 2)

        let aws = Data(#"{"prefixes": [{"ip_prefix": "3.5.140.0/22", "region": "x"}], "ipv6_prefixes": [{"ipv6_prefix": "2600:1f14::/35"}]}"#.utf8)
        XCTAssertEqual(try CrawlerIPDirectory.ranges(fromFeed: aws).count, 0)

        for junk in ["", "null", "[]", #"{"prefixes": null}"#, #"{"prefixes": {}}"#, "<!doctype html><title>Moved</title>", "\u{FEFF}{"] {
            XCTAssertThrowsError(try CrawlerIPDirectory.ranges(fromFeed: Data(junk.utf8)), junk)
        }
        XCTAssertEqual(try CrawlerIPDirectory.ranges(fromFeed: Data(#"{"prefixes": []}"#.utf8)).count, 0)
    }

    /// A feed is fetched over the network. If it is ever served wrong
    /// (captured, misconfigured, or a redirect somewhere it should not go), a
    /// catch-all block would mark every spoofer on the internet as verified.
    /// No operator publishes anything close to that broad.
    func testImplausiblyBroadFeedPrefixesAreRejected() throws {
        let body = Data(Fixture.feedBody(v4: ["0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", Fixture.gptBotV4], v6: ["::/0", "2000::/3"]).utf8)
        let ranges = try CrawlerIPDirectory.ranges(fromFeed: body)
        XCTAssertFalse(ranges.contains { $0.contains(Fixture.attackerIP) }, "a /0 or /1 in a feed verifies everyone")
        XCTAssertFalse(ranges.contains { $0.contains("2001:db8::1") })
        XCTAssertTrue(ranges.contains { $0.contains(Fixture.gptBotIP) })
    }

    func testHugeFeedDecodesAndMatchesQuickly() throws {
        let v4 = (0..<100_000).map { "10.\($0 >> 8 & 255).\($0 & 255).0/24" }
        let body = Data(Fixture.feedBody(v4: v4).utf8)
        var start = Date()
        let ranges = try CrawlerIPDirectory.ranges(fromFeed: body)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0, "decoding")
        XCTAssertEqual(ranges.count, 100_000)
        start = Date()
        let bytes = IPRange.parse(address: Fixture.attackerIP)!
        XCTAssertFalse(ranges.contains { $0.contains(bytes) })
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "one lookup (a linear scan; fine at vendor feed sizes)")
    }

    // MARK: - Directory: agent-to-feed mapping

    func testPerAgentListsDoNotCrossVerify() async throws {
        let client = StubFeedClient(healthyOn: app.eventLoopGroup.next())
        let dir = directory(client)

        // Each agent inside its own list.
        let ownGPT = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.gptBotIP)
        let ownChatGPT = await dir.verify(agentToken: "ChatGPT-User", clientIP: Fixture.chatGPTUserIP)
        let ownClaude = await dir.verify(agentToken: "ClaudeBot", clientIP: Fixture.claudeIP)
        XCTAssertEqual(ownGPT, .verified)
        XCTAssertEqual(ownChatGPT, .verified)
        XCTAssertEqual(ownClaude, .verified)

        // OpenAI publishes per agent: another OpenAI agent's address is not enough.
        let chatGPTFromGPTBot = await dir.verify(agentToken: "ChatGPT-User", clientIP: Fixture.gptBotIP)
        let gptFromChatGPT = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.chatGPTUserIP)
        let chatGPTFromGPTBotV6 = await dir.verify(agentToken: "ChatGPT-User", clientIP: "2600:1f1c::5")
        XCTAssertEqual(chatGPTFromGPTBot, .spoofed)
        XCTAssertEqual(gptFromChatGPT, .spoofed)
        XCTAssertEqual(chatGPTFromGPTBotV6, .spoofed)

        // Across operators.
        let gptFromClaude = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.claudeIP)
        let claudeFromGPT = await dir.verify(agentToken: "ClaudeBot", clientIP: Fixture.gptBotIP)
        XCTAssertEqual(gptFromClaude, .spoofed)
        XCTAssertEqual(claudeFromGPT, .spoofed)

        // Anthropic's one shared list: documented as operator-level proof.
        let claudeUserFromBot = await dir.verify(agentToken: "Claude-User", clientIP: Fixture.claudeIP)
        XCTAssertEqual(claudeUserFromBot, .verified)

        // Token lookup is case-insensitive.
        let lower = await dir.verify(agentToken: "chatgpt-user", clientIP: Fixture.chatGPTUserIP)
        XCTAssertEqual(lower, .verified)

        // No usable address for a covered agent is a spoof, never verified.
        for ip in [nil, "", "unknown", "garbage", "fe80::1%en0", "20.171.206.10:443"] as [String?] {
            let result = await dir.verify(agentToken: "GPTBot", clientIP: ip)
            XCTAssertNotEqual(result, .verified, "clientIP: \(ip.debugDescription)")
        }

        // An agent with no feed is unverified, never spoofed.
        let noFeed = await dir.verify(agentToken: "CCBot", clientIP: Fixture.attackerIP)
        XCTAssertEqual(noFeed, .unverified)
    }

    /// End to end through the default strategy and the real catalog matcher.
    func testForgedClaimsThroughTheDefaultStrategy() async throws {
        let dir = directory(StubFeedClient(healthyOn: app.eventLoopGroup.next()))

        // Behind one appending proxy, a forged leftmost entry buys nothing.
        let forged = try await verdict(userAgent: Fixture.chatGPTUserUA,
                                       forwardedFor: ["\(Fixture.chatGPTUserIP), \(Fixture.attackerIP)"], directory: dir)
        XCTAssertEqual(forged, .spoofed)

        // Two forged header lines, proxy appends a third.
        let forgedLines = try await verdict(userAgent: Fixture.gptBotUA,
                                            forwardedFor: [Fixture.gptBotIP, Fixture.gptBotIP, Fixture.attackerIP], directory: dir)
        XCTAssertEqual(forgedLines, .spoofed)

        // A GPTBot user agent from a ChatGPT-User address.
        let crossed = try await verdict(userAgent: Fixture.gptBotUA,
                                        forwardedFor: ["1.2.3.4, \(Fixture.chatGPTUserIP)"], directory: dir)
        XCTAssertEqual(crossed, .spoofed)

        // A UA carrying two tokens is judged as the longer one only.
        let both = try await verdict(userAgent: "GPTBot ChatGPT-User",
                                     forwardedFor: [Fixture.gptBotIP], directory: dir)
        XCTAssertEqual(both, .spoofed)

        // A genuine hit through a dual-stack hop.
        let mapped = try await verdict(userAgent: Fixture.claudeUserUA,
                                       forwardedFor: ["::ffff:\(Fixture.claudeIP)"], directory: dir)
        XCTAssertEqual(mapped, .verified)

        // Genuine, with the proxy's own address as the peer.
        let genuine = try await verdict(userAgent: Fixture.claudeBotUA,
                                        forwardedFor: [Fixture.claudeIP], remote: "10.0.0.9", directory: dir)
        XCTAssertEqual(genuine, .verified)

        // No peer, no header.
        let noPeer = try await verdict(userAgent: Fixture.gptBotUA, remote: nil, directory: dir)
        XCTAssertEqual(noPeer, .spoofed)
    }

    /// The default strategy reads `X-Forwarded-For` whoever the peer is, so
    /// an app that faces the internet directly lets a client write the "last"
    /// entry itself. That default is deliberate (it is right behind the one
    /// appending proxy of a PaaS router) and documented: an exposed-directly
    /// deployment must use `.remoteAddress`. These assert both halves of that
    /// documented behaviour.
    func testDirectClientCannotForgeTheClientIPUnderRemoteAddress() async throws {
        let dir = directory(StubFeedClient(healthyOn: app.eventLoopGroup.next()))
        let result = try await verdict(userAgent: Fixture.chatGPTUserUA,
                                       forwardedFor: [Fixture.chatGPTUserIP],
                                       remote: Fixture.attackerIP,
                                       strategy: .remoteAddress,
                                       directory: dir)
        XCTAssertEqual(result, .spoofed, "under .remoteAddress a client-set X-Forwarded-For must be ignored")

        // The default trusts the header, as documented: it assumes a proxy
        // that appends the address it saw.
        guard case .lastForwardedFor = BotKitConfiguration().clientIP else {
            return XCTFail("The documented default is .lastForwardedFor.")
        }
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: try request(forwardedFor: [Fixture.chatGPTUserIP],
                                                                                  remote: Fixture.attackerIP)),
                       Fixture.chatGPTUserIP)
    }

    /// `forwardedFor(trustedProxies: 2)` is only honest when every request
    /// passes through the outer proxy (the CDN), which the docs require the
    /// origin to enforce. With that in place a forged entry sits left of both
    /// appended ones and buys nothing.
    func testForgedEntryBuysNothingWhenTheOriginIsLockedToTheOuterProxy() async throws {
        let dir = directory(StubFeedClient(healthyOn: app.eventLoopGroup.next()))
        // Client forges the GPTBot address; the CDN appends the attacker's
        // real address; the load balancer appends the CDN edge.
        let result = try await verdict(userAgent: Fixture.gptBotUA,
                                       forwardedFor: ["\(Fixture.gptBotIP), \(Fixture.attackerIP), 104.16.0.1"],
                                       strategy: .forwardedFor(trustedProxies: 2),
                                       directory: dir)
        XCTAssertEqual(result, .spoofed)
    }

    /// When two configured feeds cover the same agent (the documented
    /// `defaults + [...]` pattern), both lists should count. Overwriting
    /// makes genuine hits from the first list read as spoofs.
    func testTwoFeedsForOneAgentAreUnioned() async throws {
        let extraURL = "https://feeds.test/gptbot-extra.json"
        let client = StubFeedClient(eventLoop: app.eventLoopGroup.next()) { request in
            if request.url.string == extraURL {
                return StubFeedClient.response(.ok, Fixture.feedBody(v4: ["52.230.152.0/24"]))
            }
            return StubFeedClient.response(.ok, Fixture.healthyBody(for: request.url.string) ?? "")
        }
        let dir = directory(client, feeds: Fixture.feeds + [.init(url: extraURL, agentTokens: ["gptbot"])])
        let fromOfficial = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.gptBotIP)
        let fromExtra = await dir.verify(agentToken: "GPTBot", clientIP: "52.230.152.9")
        XCTAssertEqual(fromExtra, .verified)
        XCTAssertEqual(fromOfficial, .verified, "the second feed replaced the first instead of adding to it")
    }

    // MARK: - Directory: failure handling

    /// Every way a feed can fail leaves its agents unverified, never
    /// spoofed and never verified.
    func testFailedFeedsLeaveAgentsUnverified() async throws {
        let failures: [(String, StubFeedClient.Handler)] = [
            ("500", { _ in StubFeedClient.response(.internalServerError, Fixture.feedBody(v4: ["0.0.0.0/0"])) }),
            ("302", { _ in StubFeedClient.response(.found, "") }),
            ("HTML 200", { _ in StubFeedClient.response(.ok, "<!doctype html><h1>Just a moment...</h1>", contentType: "text/html") }),
            ("malformed JSON", { _ in StubFeedClient.response(.ok, #"{"prefixes": [{"ipv4Prefix": "20.171.206.0/24"}"#) }),
            ("empty prefixes", { _ in StubFeedClient.response(.ok, #"{"prefixes": []}"#) }),
            ("only unusable prefixes", { _ in StubFeedClient.response(.ok, Fixture.feedBody(v4: ["nope", "1.2.3.4"])) }),
            ("no body", { _ in ClientResponse(status: .ok) }),
            ("network error", { _ in throw StubNetworkError() }),
        ]
        for (name, handler) in failures {
            let dir = directory(StubFeedClient(eventLoop: app.eventLoopGroup.next(), handler: handler))
            let attacker = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.attackerIP)
            let genuine = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.gptBotIP)
            XCTAssertEqual(attacker, .unverified, name)
            XCTAssertEqual(genuine, .unverified, name)
        }
    }

    /// A refresh that fails after a good one keeps the ranges already held.
    func testStaleRangesSurviveAFailedRefresh() async throws {
        let client = StubFeedClient(healthyOn: app.eventLoopGroup.next())
        let dir = directory(client, refreshInterval: 0)
        let first = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.gptBotIP)
        XCTAssertEqual(first, .verified)

        client.setHandler { _ in StubFeedClient.response(.ok, "<html>") }
        for _ in 0..<5 {
            _ = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.gptBotIP)
            try await Task.sleep(for: .milliseconds(20))
        }
        let genuine = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.gptBotIP)
        let attacker = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.attackerIP)
        XCTAssertEqual(genuine, .verified)
        XCTAssertEqual(attacker, .spoofed)
    }

    /// A burst of first requests shares one fetch per feed.
    func testConcurrentFirstRequestsShareOneFetch() async throws {
        let loop = app.eventLoopGroup.next()
        let client = StubFeedClient(eventLoop: loop) { request in
            try await Task.sleep(for: .milliseconds(100))
            return StubFeedClient.response(.ok, Fixture.healthyBody(for: request.url.string) ?? "")
        }
        let dir = directory(client)
        let results = await withTaskGroup(of: BotVerification.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await dir.verify(agentToken: "GPTBot", clientIP: i.isMultiple(of: 2) ? Fixture.gptBotIP : Fixture.attackerIP)
                }
            }
            return await group.reduce(into: [BotVerification]()) { $0.append($1) }
        }
        XCTAssertEqual(results.filter { $0 == .verified }.count, 50)
        XCTAssertEqual(results.filter { $0 == .spoofed }.count, 50)
        XCTAssertEqual(client.requestCount, Fixture.feeds.count)
    }

    /// While every feed is down, each recorded agent hit currently starts a
    /// fresh round of fetches. Anyone can send `-A GPTBot` in a loop, so this
    /// turns the site into a request amplifier against the vendors' feed
    /// endpoints and keeps every recorder task waiting on the network. After a
    /// failed round there should be some back-off.
    func testFailedLoadBacksOffInsteadOfRefetchingPerRequest() async throws {
        let client = StubFeedClient(eventLoop: app.eventLoopGroup.next()) { _ in throw StubNetworkError() }
        let dir = directory(client)
        for _ in 0..<20 {
            _ = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.attackerIP)
        }
        XCTAssertLessThanOrEqual(client.requestCount, Fixture.feeds.count * 2,
                                 "20 forged hits caused \(client.requestCount) outbound feed fetches")
    }

    /// Vapor's default HTTP client has no read timeout or deadline. A feed
    /// that accepts the connection and then stalls holds `refreshTask` forever:
    /// ranges are never refreshed again, and before the first success every
    /// recorder task awaits it and piles up in memory. Each fetch needs a
    /// deadline of its own.
    func testFeedFetchesCarryATimeout() async throws {
        let client = StubFeedClient(healthyOn: app.eventLoopGroup.next())
        let dir = directory(client)
        _ = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.gptBotIP)
        XCTAssertFalse(client.requests.isEmpty)
        for request in client.requests {
            XCTAssertNotNil(request.timeout, "no timeout on \(request.url)")
            if let timeout = request.timeout {
                XCTAssertLessThanOrEqual(timeout, .seconds(60))
            }
        }
    }

    /// 1, 2, 4, 8 minutes, then capped at 15.
    func testRetryBackOffSchedule() {
        XCTAssertEqual(CrawlerIPDirectory.retryDelay(afterFailures: 1), 60)
        XCTAssertEqual(CrawlerIPDirectory.retryDelay(afterFailures: 2), 120)
        XCTAssertEqual(CrawlerIPDirectory.retryDelay(afterFailures: 4), 480)
        XCTAssertEqual(CrawlerIPDirectory.retryDelay(afterFailures: 5), 900)
        XCTAssertEqual(CrawlerIPDirectory.retryDelay(afterFailures: 1_000), 900)
    }

    /// One feed down at boot: the others verify, and the failed one is not
    /// refetched on every hit but waits out its back-off.
    func testPartiallyFailedFirstLoadBacksOffOnlyTheFailedFeed() async throws {
        let client = StubFeedClient(eventLoop: app.eventLoopGroup.next()) { request in
            if request.url.string == Fixture.chatGPTUserURL { throw StubNetworkError() }
            return StubFeedClient.response(.ok, Fixture.healthyBody(for: request.url.string) ?? "")
        }
        let dir = directory(client)
        for _ in 0..<10 {
            let gpt = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.gptBotIP)
            let chat = await dir.verify(agentToken: "ChatGPT-User", clientIP: Fixture.chatGPTUserIP)
            XCTAssertEqual(gpt, .verified)
            XCTAssertEqual(chat, .unverified)
        }
        XCTAssertEqual(client.requestCount, Fixture.feeds.count)
    }

    /// A body over the size cap is refused whole, even with valid JSON.
    func testOversizedFeedIsRefused() async throws {
        let padding = String(repeating: " ", count: CrawlerIPDirectory.maximumFeedBytes)
        let client = StubFeedClient(eventLoop: app.eventLoopGroup.next()) { _ in
            StubFeedClient.response(.ok, Fixture.feedBody(v4: [Fixture.gptBotV4]) + padding)
        }
        let dir = directory(client, feeds: [Fixture.feeds[0]])
        let result = await dir.verify(agentToken: "GPTBot", clientIP: Fixture.gptBotIP)
        XCTAssertEqual(result, .unverified)
    }

    /// Only the chosen entry has its port or brackets removed.
    func testHostOnlyEdgeCases() {
        XCTAssertEqual(ClientIPStrategy.hostOnly("1.2.3.4:5678"), "1.2.3.4")
        XCTAssertEqual(ClientIPStrategy.hostOnly("[2600::5]:443"), "2600::5")
        XCTAssertEqual(ClientIPStrategy.hostOnly("[2600::5]"), "2600::5")
        XCTAssertEqual(ClientIPStrategy.hostOnly("2600::5"), "2600::5")
        XCTAssertEqual(ClientIPStrategy.hostOnly("1.2.3.4:"), "1.2.3.4:")
        XCTAssertEqual(ClientIPStrategy.hostOnly("1.2.3.4:http"), "1.2.3.4:http")
        XCTAssertEqual(ClientIPStrategy.hostOnly("[2600::5"), "[2600::5")
        XCTAssertEqual(ClientIPStrategy.hostOnly("[2600::5]x"), "[2600::5]x")
    }

    /// With verification off, nothing is fetched and no directory exists, so
    /// the recorder falls back to `.unverified` for every agent.
    func testVerificationDisabledNeverFetches() async throws {
        let client = StubFeedClient(healthyOn: app.eventLoopGroup.next())
        var config = BotKitConfiguration(signingSecret: "s")
        config.verification.isEnabled = false
        let runtime = BotKitRuntime(configuration: config, client: client, logger: app.logger)
        XCTAssertNil(runtime.directory)
        XCTAssertEqual(client.requestCount, 0)
    }
}
