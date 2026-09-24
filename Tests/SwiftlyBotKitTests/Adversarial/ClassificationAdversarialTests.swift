import XCTest
import XCTVapor
import Fluent
import NIOCore
@testable import SwiftlyBotKit

// Adversarial tests for request classification and what gets recorded.
//
// Every assertion states the behaviour the package should have, per its README
// and DocC. A failing test here is a bug (or a documented promise the code does
// not keep), not a test to be "fixed" by loosening it.

// MARK: - Agent matching

final class ClassificationAdversarialAgentMatchingTests: XCTestCase {

    private let gptbotUA = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)"

    func testEmptyMissingAndBlankUserAgentsAreNotAgents() {
        XCTAssertNil(AIAgentCatalog.match(userAgent: nil))
        XCTAssertNil(AIAgentCatalog.match(userAgent: ""))
        XCTAssertNil(AIAgentCatalog.match(userAgent: " "))
        XCTAssertNil(AIAgentCatalog.match(userAgent: "\t\r\n"))
        let classifier = BotRequestClassifier(configuration: BotKitConfiguration())
        XCTAssertFalse(classifier.isWorthRecording(path: "/", userAgent: nil, referer: nil))
        XCTAssertFalse(classifier.isWorthRecording(path: "/", userAgent: "", referer: ""))
    }

    /// Tokens are documented as case-insensitive.
    func testMixedCaseTokensMatch() {
        for ua in ["gptbot/1.0", "GPTBOT/1.0", "gPtBoT", "Mozilla/5.0 (compatible; claude-user/1.0)"] {
            XCTAssertNotNil(AIAgentCatalog.match(userAgent: ua), ua)
        }
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "GPTBOT/1.0")?.token, "GPTBot")
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "applebot-extended")?.token, "Applebot-Extended")
    }

    /// DocC (CustomAgents.md): a token matches only as a whole word, so a
    /// short token cannot fire inside an unrelated product name.
    func testTokensEmbeddedInOtherWordsDoNotMatch() {
        XCTAssertNil(AIAgentCatalog.match(userAgent: "NotGPTBotAtAll"))
        XCTAssertNil(AIAgentCatalog.match(userAgent: "GPTBotanist/2.0"))
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "(GPTBot)")?.token, "GPTBot")
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "x+GPTBot;")?.token, "GPTBot")
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "GPTBot_1")?.token, "GPTBot", "underscore is not a letter or digit")
    }

    /// A custom token that starts or ends in punctuation is only checked for
    /// a boundary on the sides that are letters or digits.
    func testBoundaryIsOnlyCheckedOnWordCharacterEdges() {
        let matcher = AIAgentMatcher(agents: [AIAgent(token: "-Bot", purpose: .agent)])
        XCTAssertEqual(matcher.match(userAgent: "Acme-Bot/1")?.token, "-Bot")
        XCTAssertNil(matcher.match(userAgent: "Acme-Bots/1"))
    }

    /// Among equally long tokens, a custom one beats a built-in one even when
    /// the built-in appears first in the header.
    func testCustomTokenBeatsEqualLengthBuiltInWhereverItSits() {
        var config = BotKitConfiguration()
        config.detection.customAgents = [AIAgent(token: "AcmeAI", purpose: .agent, operatorName: "Acme")]
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertEqual(classifier.agent(userAgent: "GPTBot/1.0 AcmeAI/1.0")?.token, "AcmeAI")
    }

    /// Longest token wins regardless of where each token sits in the header.
    func testLongestTokenWinsWhateverTheOrderInTheHeader() {
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "Applebot/0.1 Applebot-Extended/0.1")?.token, "Applebot-Extended")
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "Applebot-Extended/0.1 Applebot/0.1")?.token, "Applebot-Extended")
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "omgili omgilibot")?.token, "omgilibot")
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "Bytespider; spider-feedback@bytedance.com")?.token, "Bytespider")
    }

    /// Every catalog entry must be reachable: a header consisting of exactly its
    /// own token has to match that entry and not some other one.
    func testEveryCatalogTokenMatchesItself() {
        for agent in AIAgentCatalog.all {
            let matched = AIAgentCatalog.match(userAgent: agent.token)
            XCTAssertEqual(matched?.token.lowercased(), agent.token.lowercased(), "\(agent.token) is shadowed by \(matched?.token ?? "nil")")
        }
    }

    /// The catalog carries both `MistralAI-User` (aiSearch) and
    /// `MistralAI-User/1.0` (userTriggered). The same agent must not change
    /// purpose when it bumps its version number.
    func testAgentPurposeDoesNotDependOnVersionNumber() {
        let v1 = AIAgentCatalog.match(userAgent: "Mozilla/5.0 (compatible; MistralAI-User/1.0; +https://docs.mistral.ai/robots)")
        let v2 = AIAgentCatalog.match(userAgent: "Mozilla/5.0 (compatible; MistralAI-User/2.0; +https://docs.mistral.ai/robots)")
        XCTAssertEqual(v1?.purpose, v2?.purpose)
        XCTAssertEqual(v2?.purpose, .userTriggered)
    }

    func testCatalogHasNoCaseInsensitiveDuplicateTokens() {
        var seen: [String: String] = [:]
        for agent in AIAgentCatalog.all {
            let key = agent.token.lowercased()
            XCTAssertNil(seen[key], "Duplicate token: \(agent.token) and \(seen[key] ?? "")")
            seen[key] = agent.token
        }
    }

    /// The real GPTBot user agent contains two catalog tokens of equal length:
    /// `GPTBot` and `OpenAI` (from `+https://openai.com/gptbot`). Which wins
    /// must not depend on the incidental order of the input list.
    func testEqualLengthTieDoesNotDependOnInputOrder() {
        let forward = AIAgentMatcher(agents: AIAgentCatalog.all)
        let reversed = AIAgentMatcher(agents: AIAgentCatalog.all.reversed())
        XCTAssertEqual(forward.match(userAgent: gptbotUA)?.token, "GPTBot")
        XCTAssertEqual(reversed.match(userAgent: gptbotUA)?.token, "GPTBot",
                       "Tie between equal-length tokens is broken by input order")
    }

    /// README/DocC: a custom agent whose token equals a built-in one replaces
    /// it, "which is how to reclassify an agent". Reclassifying GPTBot must
    /// still catch real GPTBot traffic.
    func testReclassifyingGPTBotStillMatchesRealGPTBotTraffic() {
        var config = BotKitConfiguration()
        config.detection.customAgents = [AIAgent(token: "GPTBot", purpose: .aiSearch, operatorName: "OpenAI")]
        let classifier = BotRequestClassifier(configuration: config)
        let agent = classifier.agent(userAgent: gptbotUA)
        XCTAssertEqual(agent?.token, "GPTBot")
        XCTAssertEqual(agent?.purpose, .aiSearch)
    }

    func testCustomAgentOverridesBuiltInCaseInsensitively() {
        var config = BotKitConfiguration()
        config.detection.customAgents = [AIAgent(token: "claudebot", purpose: .aiSearch, operatorName: "Me")]
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertEqual(classifier.agent(userAgent: "ClaudeBot/1.0")?.operatorName, "Me")
        XCTAssertEqual(classifier.agents.agents.filter { $0.token.lowercased() == "claudebot" }.count, 1)
    }

    func testCustomAgentWithEmptyTokenMatchesNothing() {
        var config = BotKitConfiguration()
        config.detection.includesBuiltInAgents = false
        config.detection.customAgents = [AIAgent(token: "", purpose: .scraper)]
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertNil(classifier.agent(userAgent: "Mozilla/5.0 Safari"))
        XCTAssertFalse(classifier.isWorthRecording(path: "/", userAgent: "anything", referer: nil))
    }

    func testCustomAgentsOnlyWhenBuiltInsDisabled() {
        var config = BotKitConfiguration()
        config.detection.includesBuiltInAgents = false
        config.detection.customAgents = [AIAgent(token: "AcmeBot", purpose: .agent)]
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertNil(classifier.agent(userAgent: gptbotUA))
        XCTAssertEqual(classifier.agent(userAgent: "acmebot/2")?.purpose, .agent)
    }

    func testNonASCIIUserAgents() {
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "🤖🤖 GPTBot/1.0 مرحبا بالعالم")?.token, "GPTBot")
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "\u{202E}GPTBot/1.0\u{202C}")?.token, "GPTBot")
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "İstanbul ClaudeBot/1.0")?.token, "ClaudeBot")
        XCTAssertNil(AIAgentCatalog.match(userAgent: "Mozilla/5.0 (日本語; 한국어; עברית) 🦊"))
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "GPTBot\u{0}/1.0")?.token, "GPTBot")
    }

    /// NIO caps each header field at 80 KB, and the classifier runs on
    /// every request synchronously, so a pathological header must stay cheap.
    func testVeryLongUserAgentsAreClassifiedCorrectlyAndQuickly() {
        let classifier = BotRequestClassifier(configuration: BotKitConfiguration())
        for size in [80 * 1024, 1024 * 1024] {
            let padding = String(repeating: "a", count: size)
            let clock = ContinuousClock()
            var hit = false
            var miss = true
            let elapsed = clock.measure {
                hit = classifier.isWorthRecording(path: "/", userAgent: padding + " GPTBot/1.0", referer: nil)
                miss = classifier.isWorthRecording(path: "/", userAgent: padding, referer: nil)
            }
            XCTAssertTrue(hit, "token at the end of a \(size)-byte header")
            XCTAssertFalse(miss)
            print("[adversarial] classify 2x \(size) bytes: \(elapsed)")
            // 80 KB is the largest single header NIO accepts. Classification
            // runs synchronously on the event loop for every request, so it
            // has to be far below a millisecond per KB. (Budget is generous
            // enough for a debug build.)
            if size == 80 * 1024 {
                XCTAssertLessThan(elapsed, .milliseconds(100), "80 KB User-Agent blocks the event loop for \(elapsed)")
            }
        }
    }

    /// The classifier runs on every request, human or not. An ordinary
    /// browser user agent must cost microseconds, not milliseconds.
    func testOrdinaryUserAgentClassificationIsCheap() {
        let classifier = BotRequestClassifier(configuration: BotKitConfiguration())
        let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
        let iterations = 2_000
        let clock = ContinuousClock()
        var hits = 0
        let elapsed = clock.measure {
            for _ in 0..<iterations where classifier.isWorthRecording(path: "/pricing/", userAgent: chrome, referer: "https://www.google.com/") {
                hits += 1
            }
        }
        XCTAssertEqual(hits, 0)
        let perCall = elapsed / iterations
        print("[adversarial] ordinary UA classification: \(perCall) per request")
        XCTAssertLessThan(perCall, .microseconds(200), "each ordinary request spends \(perCall) in the classifier")
    }

    /// Ordinary browsers and non-AI crawlers must not be filed as AI agents:
    /// the README says ordinary traffic is never recorded, and every false
    /// positive inflates the dashboard's AI numbers.
    func testOrdinaryBrowsersAndNonAICrawlersAreNotAgents() {
        let notAI: [String: String] = [
            "Chrome/Windows": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
            "Safari/iOS": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            "Firefox": "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0",
            "Edge": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.2739.42",
            "Samsung": "Mozilla/5.0 (Linux; Android 14; SM-S921B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Mobile Safari/537.36",
            "Facebook in-app": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/470.0.0.0;FBBV/600000000;FBDV/iPhone15,2;FBMD/iPhone;FBSN/iOS;FBSV/17.5;FBSS/3;FBID/phone;FBLC/en_US;FBOP/5]",
            "Googlebot": "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
            "Bingbot": "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
            "Baiduspider": "Mozilla/5.0 (compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html)",
            "Sogou": "Sogou web spider/4.0(+http://www.sogou.com/docs/help/webmasters.htm#07)",
            "360Spider": "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0); 360Spider",
            "YandexBot": "Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)",
            "DuckDuckBot": "DuckDuckBot/1.1; (+http://duckduckgo.com/duckduckbot.html)",
            "Screaming Frog": "Screaming Frog SEO Spider/20.2",
            "Twitterbot": "Twitterbot/1.0",
            "Slackbot": "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
            "VS Code webview": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Code/1.93.1 Chrome/124.0.6367.243 Electron/30.4.0 Safari/537.36",
            "UptimeRobot": "Mozilla/5.0+(compatible; UptimeRobot/2.0; http://www.uptimerobot.com/)",
            "curl": "curl/8.7.1",
        ]
        for (name, ua) in notAI.sorted(by: { $0.key < $1.key }) {
            let match = AIAgentCatalog.match(userAgent: ua)
            XCTAssertNil(match, "\(name) classified as AI agent \(match?.token ?? "") (\(match.map { "\($0.purpose)" } ?? ""))")
        }
    }
}

// MARK: - Referrers

final class ClassificationAdversarialReferrerTests: XCTestCase {

    func testLookalikeAndSmuggledHostsAreNotMatched() {
        let spoofs = [
            "https://chatgpt.com.evil.com/",
            "https://evil.com/?r=chatgpt.com",
            "https://evil.com/chatgpt.com",
            "https://evil.com/#chatgpt.com",
            "https://chatgpt.com@evil.com/",
            "https://user:pw@chatgpt.com.evil.com/",
            "https://notchatgpt.com/",
            "https://chatgptcom/",
            "https://ch\u{0430}tgpt.com/",        // Cyrillic a
            "https://xn--chtgpt-9ve.com/",        // punycode lookalike
            "https://claude.ai.evil.com/",
        ]
        for referer in spoofs {
            XCTAssertNil(LLMReferrer.platform(forReferer: referer), referer)
        }
    }

    /// A scheme-less referer is documented as accepted. It must still be read
    /// as a host, not as a string whose tail happens to look like one.
    func testSchemelessRefererCannotSmuggleAHostInTheQueryOrFragment() {
        XCTAssertEqual(LLMReferrer.platform(forReferer: "chatgpt.com/c/1"), "ChatGPT")
        XCTAssertEqual(LLMReferrer.platform(forReferer: "chatgpt.com"), "ChatGPT")
        XCTAssertNil(LLMReferrer.platform(forReferer: "evil.com?x=.chatgpt.com"))
        XCTAssertNil(LLMReferrer.platform(forReferer: "evil.com#.chatgpt.com"))
        XCTAssertNil(LLMReferrer.platform(forReferer: "evil.com/.chatgpt.com"))
    }

    func testLegitimateVariantsAreMatched() {
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://www.perplexity.ai/search/x"), "Perplexity")
        XCTAssertEqual(LLMReferrer.platform(forReferer: "HTTPS://CHATGPT.COM/c/1"), "ChatGPT")
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://ChatGPT.com:443/c/1"), "ChatGPT")
        XCTAssertEqual(LLMReferrer.platform(forReferer: "http://claude.ai"), "Claude")
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://chat.openai.com/"), "ChatGPT")
    }

    /// `chatgpt.com.` is the fully qualified form of the same host.
    func testTrailingDotHostIsTheSameHost() {
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://chatgpt.com./c/1"), "ChatGPT")
    }

    func testMalformedReferrersDoNotMatchOrCrash() {
        for referer in ["", " ", "://", "https://", "https:///chatgpt.com", "not a url", "http://[::1",
                        "javascript:chatgpt.com", "\u{0}", String(repeating: "/", count: 10_000),
                        String(repeating: "a.", count: 50_000)] {
            XCTAssertNil(LLMReferrer.platform(forReferer: referer), referer.prefix(40).description)
        }
    }

    func testCustomReferrerHostsAreCaseInsensitiveAndOverrideBuiltIns() {
        let platforms = LLMReferrer.platforms(
            includesBuiltIn: true,
            custom: [.init(hostSuffix: "Example.AI", name: "Example"), .init(hostSuffix: "claude.ai", name: "Anthropic")]
        )
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://www.example.ai/x", in: platforms), "Example")
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://claude.ai/chat/1", in: platforms), "Anthropic")
        XCTAssertEqual(platforms.filter { $0.hostSuffix == "claude.ai" }.count, 1)
    }

    /// An empty custom suffix is a configuration mistake; it must not turn
    /// into a match for any host ending in a dot.
    func testEmptyCustomReferrerSuffixMatchesNothing() {
        let platforms = LLMReferrer.platforms(includesBuiltIn: false, custom: [.init(hostSuffix: "", name: "Oops")])
        XCTAssertNil(LLMReferrer.platform(forReferer: "https://evil.com./", in: platforms))
        XCTAssertNil(LLMReferrer.platform(forReferer: "https://evil.com/", in: platforms))
    }

    /// `.example.com` is a common way to write "this domain and its
    /// subdomains"; it should not silently never match.
    func testLeadingDotCustomSuffixStillMatches() {
        let platforms = LLMReferrer.platforms(includesBuiltIn: false, custom: [.init(hostSuffix: ".example.com", name: "Ex")])
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://www.example.com/", in: platforms), "Ex")
    }

    func testReferralRecordingCanBeTurnedOff() {
        var config = BotKitConfiguration()
        config.recording.recordsReferrals = false
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertFalse(classifier.isWorthRecording(path: "/", userAgent: "Safari", referer: "https://chatgpt.com/"))
    }
}

// MARK: - Skip rules

final class ClassificationAdversarialSkipRuleTests: XCTestCase {

    private let gptbot = "GPTBot/1.2"
    private let classifier = BotRequestClassifier(configuration: BotKitConfiguration())

    private func records(_ path: String, _ classifier: BotRequestClassifier? = nil) -> Bool {
        (classifier ?? self.classifier).isWorthRecording(path: path, userAgent: gptbot, referer: nil)
    }

    func testIgnoredExtensionsAreCaseInsensitive() {
        XCTAssertFalse(records("/a.PNG"))
        XCTAssertFalse(records("/fonts/X.WoFf2"))
        XCTAssertFalse(records("/a.html.png"))
        XCTAssertTrue(records("/a.png.html"))
    }

    func testRobotsSitemapAndTextFilesAreRecorded() {
        for path in ["/robots.txt", "/sitemap.xml", "/sitemap-index.xml", "/llms.txt", "/feed.xml", "/ROBOTS.TXT"] {
            XCTAssertTrue(records(path), path)
        }
    }

    func testDotfilesAndPlainPathsAreRecorded() {
        XCTAssertTrue(records("/"))
        XCTAssertTrue(records("/.well-known/ai-plugin.json"))
        XCTAssertTrue(records("/insights/"))
        XCTAssertTrue(records("/v1.2/"))
    }

    /// FileMiddleware percent-decodes the path before serving, so `%2E` is a
    /// real dot as far as the asset served is concerned.
    func testPercentEncodedAssetExtensionIsStillAnAsset() {
        XCTAssertFalse(records("/images/logo%2Epng"))
    }

    /// Always excluded, even when the dashboard is not mounted (CLAUDE.md,
    /// Recording.excludedPathPrefixes doc comment).
    func testDashboardPathExcludedEvenWhenDashboardDisabled() {
        var config = BotKitConfiguration()
        config.dashboard.isEnabled = false
        config.dashboard.username = nil
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertFalse(records("/admin/ai-bots", classifier))
        XCTAssertFalse(records("/admin/ai-bots/", classifier))
        XCTAssertFalse(records("/admin/ai-bots/login", classifier))
    }

    func testDashboardPathNormalisationVariants() {
        var config = BotKitConfiguration()
        config.dashboard.path = "internal/bots/"
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertFalse(records("/internal/bots/", classifier))
        XCTAssertTrue(records("/admin/ai-bots/", classifier))
    }

    /// `/admin/ai-botsnet/` is not the dashboard's path; only the path itself
    /// and what sits below it are.
    func testDashboardExclusionDoesNotSwallowLookalikePaths() {
        XCTAssertTrue(records("/admin/ai-botsnet/"))
        XCTAssertTrue(records("/admin/ai-bots-archive/"))
    }

    /// Vapor's router ignores empty path components, so `//admin/ai-bots/`
    /// reaches the dashboard, and must be excluded like `/admin/ai-bots/`.
    func testDoubleSlashDashboardPathIsExcluded() {
        XCTAssertFalse(records("//admin/ai-bots/"))
    }

    /// Documented as plain path *prefixes*. `/healthz` covers `/healthz/live`.
    /// Note the consequence: `/health` would also cover `/health-insurance/`.
    /// This asserts the documented string-prefix semantics; see report.
    func testExcludedPathPrefixesAreStringPrefixes() {
        var config = BotKitConfiguration()
        config.recording.excludedPathPrefixes = ["/healthz", ""]
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertFalse(records("/healthz", classifier))
        XCTAssertFalse(records("/healthz/live", classifier))
        XCTAssertFalse(records("/healthzcheck", classifier))
        XCTAssertTrue(records("/health", classifier))
        XCTAssertTrue(records("/", classifier), "an empty prefix must not exclude everything")
    }
}

// MARK: - Fake database

private struct ClassifyNoDriverConfiguration: DatabaseConfiguration {
    var middleware: [any AnyModelMiddleware] = []
    func makeDriver(for databases: Databases) -> any DatabaseDriver { fatalError("not used") }
}

/// Captures every insert, and can be told to fail or stall.
private final class ClassifyFakeStore: @unchecked Sendable {
    enum Mode { case succeed, fail, stall(Duration) }
    struct Failure: Error {}

    private let lock = NSLock()
    private var _rows: [[FieldKey: DatabaseQuery.Value]] = []
    private var _attempts = 0
    let mode: Mode

    init(mode: Mode = .succeed) { self.mode = mode }

    var rows: [[FieldKey: DatabaseQuery.Value]] { lock.withLock { _rows } }
    var attempts: Int { lock.withLock { _attempts } }

    func handle(_ query: DatabaseQuery) async throws {
        lock.withLock { _attempts += 1 }
        switch mode {
        case .succeed: break
        case .fail: throw Failure()
        case .stall(let duration): try await Task.sleep(for: duration)
        }
        for case .dictionary(let row) in query.input {
            lock.withLock { _rows.append(row) }
        }
    }
}

private struct ClassifyFakeDatabase: Database {
    let store: ClassifyFakeStore
    let context: DatabaseContext
    var inTransaction: Bool { false }

    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> ()) -> EventLoopFuture<Void> {
        let store = self.store
        return context.eventLoop.makeFutureWithTask { try await store.handle(query) }
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { context.eventLoop.makeSucceededVoidFuture() }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { context.eventLoop.makeSucceededVoidFuture() }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> { closure(self) }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> { closure(self) }
}

private extension Dictionary where Key == FieldKey, Value == DatabaseQuery.Value {
    func string(_ key: String) -> String? {
        switch self[FieldKey(stringLiteral: key)] {
        case .bind(let value): return value as? String
        case .enumCase(let value): return value
        default: return nil
        }
    }
    func int(_ key: String) -> Int? {
        if case .bind(let value) = self[FieldKey(stringLiteral: key)] { return value as? Int }
        return nil
    }
}

// MARK: - Recorder

final class ClassificationAdversarialRecorderTests: XCTestCase {

    private func recorder(_ store: ClassifyFakeStore, config: BotKitConfiguration = BotKitConfiguration()) -> BotTrafficRecorder {
        let context = DatabaseContext(
            configuration: ClassifyNoDriverConfiguration(),
            logger: Logger(label: "test"),
            eventLoop: MultiThreadedEventLoopGroup.singleton.next()
        )
        return BotTrafficRecorder(
            database: ClassifyFakeDatabase(store: store, context: context),
            classifier: BotRequestClassifier(configuration: config),
            directory: nil,
            signer: BotSigner(secret: "s"),
            logger: Logger(label: "test")
        )
    }

    private func candidate(userAgent: String?, referer: String? = nil) -> BotVisitCandidate {
        BotVisitCandidate(siteKey: "site", path: "/p/", method: "GET", statusCode: 200,
                          userAgent: userAgent, referer: referer, clientIP: "192.0.2.1")
    }

    func testTruncationNeverSplitsACharacterAndIsAPrefix() async {
        let inputs = [
            "GPTBot " + String(repeating: "é", count: 1000),
            "GPTBot " + String(repeating: "🇧🇪", count: 1000),
            "GPTBot " + String(repeating: "👩‍👩‍👧‍👦", count: 1000),
            "GPTBot " + String(repeating: "مرحبا", count: 300),
        ]
        for ua in inputs {
            let store = ClassifyFakeStore()
            await recorder(store).record(candidate(userAgent: ua))
            guard let stored = store.rows.first?.string("user_agent") else { return XCTFail("nothing stored") }
            XCTAssertLessThanOrEqual(stored.count, 512)
            XCTAssertTrue(ua.hasPrefix(stored))
            XCTAssertEqual(String(decoding: Array(stored.utf8), as: UTF8.self), stored)
        }
    }

    /// DocC says the raw user agent is "truncated to 512 characters". The
    /// database counts characters as code points, and Swift's `prefix(512)`
    /// counts grapheme clusters, which have no length limit: one letter
    /// followed by thousands of combining marks is a single `Character`.
    func testTruncationBoundsStoredLengthForCombiningMarkBombs() async {
        let ua = "GPTBot " + "a" + String(repeating: "\u{0301}", count: 20_000)
        let store = ClassifyFakeStore()
        await recorder(store).record(candidate(userAgent: ua))
        let stored = store.rows.first?.string("user_agent") ?? ""
        XCTAssertLessThanOrEqual(stored.unicodeScalars.count, 512, "stored \(stored.unicodeScalars.count) code points")
    }

    /// A request that is both an agent and a referral is stored once, as the
    /// agent (the model's two row shapes are told apart by which column is set).
    func testAgentThatAlsoCarriesAssistantReferrerIsOneAgentRow() async {
        let store = ClassifyFakeStore()
        await recorder(store).record(candidate(userAgent: "ChatGPT-User/1.0", referer: "https://chatgpt.com/"))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows.first?.string("agent_name"), "ChatGPT-User")
        XCTAssertNil(store.rows.first?.string("referrer_platform"))
        XCTAssertEqual(store.rows.first?.string("verification"), "unverified")
    }

    func testWithAgentsOffAnAgentWithAssistantReferrerIsAReferral() async {
        var config = BotKitConfiguration()
        config.recording.recordsAgents = false
        let store = ClassifyFakeStore()
        await recorder(store, config: config).record(candidate(userAgent: "GPTBot/1.0", referer: "https://claude.ai/"))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertNil(store.rows.first?.string("agent_name"))
        XCTAssertEqual(store.rows.first?.string("referrer_platform"), "Claude")
        XCTAssertEqual(store.rows.first?.string("verification"), "notApplicable")
    }

    func testDatabaseFailureIsSwallowed() async {
        let store = ClassifyFakeStore(mode: .fail)
        await recorder(store).record(candidate(userAgent: "GPTBot/1.0"))
        XCTAssertEqual(store.attempts, 1)
        XCTAssertEqual(store.rows.count, 0)
    }

    func testNonMatchingCandidateWritesNothing() async {
        let store = ClassifyFakeStore()
        await recorder(store).record(candidate(userAgent: "Safari", referer: "https://google.com/"))
        XCTAssertEqual(store.attempts, 0)
    }
}

// MARK: - Middleware, end to end through Vapor

final class ClassificationAdversarialMiddlewareTests: XCTestCase {

    private var app: Application!
    private var store: ClassifyFakeStore!
    private let gptbot: HTTPHeaders = ["User-Agent": "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)"]

    private func boot(mode: ClassifyFakeStore.Mode = .succeed, config: BotKitConfiguration = BotKitConfiguration()) async throws {
        app = try await Application.make(.testing)
        store = ClassifyFakeStore(mode: mode)
        let context = DatabaseContext(configuration: ClassifyNoDriverConfiguration(), logger: app.logger, eventLoop: app.eventLoopGroup.next())
        let recorder = BotTrafficRecorder(
            database: ClassifyFakeDatabase(store: store, context: context),
            classifier: BotRequestClassifier(configuration: config),
            directory: nil,
            signer: BotSigner(secret: "s"),
            logger: app.logger
        )
        app.middleware.use(AIBotTrackingMiddleware(recorder: recorder, siteKey: { _ in "site" }, clientIP: .lastForwardedFor))

        app.get("ok") { _ -> Response in
            var headers = HTTPHeaders()
            headers.add(name: "X-Custom", value: "kept")
            headers.add(name: .contentType, value: "text/plain")
            return Response(status: .ok, headers: headers, body: .init(string: "hello"))
        }
        app.get("moved") { req in req.redirect(to: "/ok", redirectType: .permanent) }
        app.get("forbidden") { _ -> String in throw Abort(.forbidden, reason: "nope") }
        app.get("stream") { _ -> Response in
            Response(status: .ok, body: .init(asyncStream: { writer in
                try await writer.write(.buffer(ByteBuffer(string: "part1-")))
                try await writer.write(.buffer(ByteBuffer(string: "part2")))
                try await writer.write(.end)
            }))
        }
        app.get("pricing", "") { _ in "pricing" }
    }

    override func tearDown() async throws {
        try await app?.asyncShutdown()
        app = nil
    }

    /// Waits for the detached write, or times out.
    private func waitForRows(_ count: Int, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while store.rows.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testResponsePassesThroughUnchanged() async throws {
        try await boot()
        for headers in [HTTPHeaders(), gptbot] {
            try await app.test(.GET, "/ok", headers: headers) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.string, "hello")
                XCTAssertEqual(res.headers.first(name: "X-Custom"), "kept")
            }
            try await app.test(.GET, "/stream", headers: headers) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.string, "part1-part2")
            }
            try await app.test(.GET, "/moved", headers: headers) { res async in
                XCTAssertEqual(res.status, .movedPermanently)
                XCTAssertEqual(res.headers.first(name: .location), "/ok")
            }
            try await app.test(.GET, "/forbidden", headers: headers) { res async in
                XCTAssertEqual(res.status, .forbidden)
            }
            try await app.test(.GET, "/nowhere", headers: headers) { res async in
                XCTAssertEqual(res.status, .notFound)
            }
        }
    }

    func testRecordsOkAndRedirectWithTheirStatus() async throws {
        try await boot()
        try await app.test(.GET, "/ok", headers: gptbot) { _ async in }
        try await app.test(.GET, "/moved", headers: gptbot) { _ async in }
        try await waitForRows(2)
        XCTAssertEqual(Set(store.rows.compactMap { $0.int("status_code") }), [200, 301])
        XCTAssertEqual(store.rows.first?.string("agent_name"), "GPTBot")
        XCTAssertEqual(store.rows.first?.string("site_key"), "site")
    }

    /// README/AIBotTrackingMiddleware doc: "A crawler hammering URLs that 404 is
    /// worth seeing", and the recorded status should include 404s. Vapor
    /// signals an unrouted path by *throwing* `RouteNotFound` through the
    /// middleware chain (ErrorMiddleware turns it into the 404 higher up).
    func testThrownNotFoundIsStillRecordedAs404() async throws {
        try await boot()
        try await app.test(.GET, "/does-not-exist", headers: gptbot) { res async in
            XCTAssertEqual(res.status, .notFound)
        }
        try await waitForRows(1)
        XCTAssertEqual(store.rows.count, 1, "a GPTBot 404 left no row")
        XCTAssertEqual(store.rows.first?.int("status_code"), 404)
    }

    func testThrownAbortIsStillRecordedWithItsStatus() async throws {
        try await boot()
        try await app.test(.GET, "/forbidden", headers: gptbot) { res async in
            XCTAssertEqual(res.status, .forbidden)
        }
        try await waitForRows(1)
        XCTAssertEqual(store.rows.first?.int("status_code"), 403, "a GPTBot 403 left no row")
    }

    func testQueryStringIsDroppedAndAssetsWithQueriesAreSkipped() async throws {
        try await boot()
        try await app.test(.GET, "/pricing/?utm_source=chatgpt.com&x=1", headers: gptbot) { _ async in }
        try await app.test(.GET, "/logo.png?v=2", headers: gptbot) { _ async in }
        try await app.test(.GET, "/LOGO.PNG", headers: gptbot) { _ async in }
        try await waitForRows(1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.rows.compactMap { $0.string("path") }, ["/pricing/"])
    }

    func testReferralWithQueryOnlyMentionOfAssistantIsNotRecorded() async throws {
        try await boot()
        try await app.test(.GET, "/pricing/", headers: ["Referer": "https://evil.example/?r=chatgpt.com"]) { _ async in }
        try await app.test(.GET, "/pricing/", headers: ["Referer": "https://chatgpt.com/c/1", "User-Agent": "Safari"]) { _ async in }
        try await waitForRows(1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows.first?.string("referrer_platform"), "ChatGPT")
        XCTAssertNil(store.rows.first?.string("agent_name"))
    }

    func testDatabaseFailureDoesNotAffectTheResponse() async throws {
        try await boot(mode: .fail)
        try await app.test(.GET, "/ok", headers: gptbot) { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "hello")
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while store.attempts == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.attempts, 1)
    }

    /// "The response is never delayed": a database that takes seconds to
    /// answer must not hold the response.
    func testSlowDatabaseDoesNotDelayTheResponse() async throws {
        try await boot(mode: .stall(.seconds(3)))
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await app.test(.GET, "/ok", headers: gptbot) { res async in
                XCTAssertEqual(res.status, .ok)
            }
        }
        XCTAssertLessThan(elapsed, .milliseconds(500))
    }

    func testDashboardPathNotRecordedEvenWhenUnmounted() async throws {
        var config = BotKitConfiguration()
        config.dashboard.isEnabled = false
        try await boot(config: config)
        try await app.test(.GET, "/admin/ai-bots/", headers: gptbot) { res async in
            XCTAssertEqual(res.status, .notFound)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.attempts, 0)
    }
}
