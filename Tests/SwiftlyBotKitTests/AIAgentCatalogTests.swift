import XCTest
@testable import SwiftlyBotKit

final class AIAgentCatalogTests: XCTestCase {

    func testCatalogParsed() {
        XCTAssertGreaterThan(AIAgentCatalog.all.count, 150)
        // Sorted longest token first: the basis of `match`.
        let lengths = AIAgentCatalog.all.map(\.token.utf8.count)
        XCTAssertEqual(lengths, lengths.sorted(by: >))
    }

    func testMatchesRealUserAgents() {
        let gptbot = AIAgentCatalog.match(
            userAgent: "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)"
        )
        XCTAssertEqual(gptbot?.token, "GPTBot")
        XCTAssertEqual(gptbot?.purpose, .training)
        XCTAssertEqual(gptbot?.operatorName, "OpenAI")

        let user = AIAgentCatalog.match(
            userAgent: "Mozilla/5.0 (compatible; ChatGPT-User/1.0; +https://openai.com/bot)"
        )
        XCTAssertEqual(user?.token, "ChatGPT-User")
        XCTAssertEqual(user?.purpose, .userTriggered)
    }

    /// The reason the list is sorted by token length: `Applebot-Extended`
    /// contains `Applebot`, and the two have different purposes. Shortest-first
    /// matching would file every training fetch as AI search.
    func testLongestTokenWins() {
        let extended = AIAgentCatalog.match(userAgent: "Mozilla/5.0 (compatible; Applebot-Extended/0.1)")
        XCTAssertEqual(extended?.token, "Applebot-Extended")
        XCTAssertEqual(extended?.purpose, .training)

        let plain = AIAgentCatalog.match(userAgent: "Mozilla/5.0 (compatible; Applebot/0.1)")
        XCTAssertEqual(plain?.token, "Applebot")
        XCTAssertEqual(plain?.purpose, .aiSearch)
    }

    func testThreeClaudeAgentsAreDistinguished() {
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "ClaudeBot/1.0")?.purpose, .training)
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "Claude-User/1.0")?.purpose, .userTriggered)
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "Claude-SearchBot/1.0")?.purpose, .aiSearch)
    }

    func testDocumentedRobotsRefusalIsCarried() {
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "Perplexity-User/1.0")?.respectsRobotsTxt, false)
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "PerplexityBot/1.0")?.respectsRobotsTxt, true)
    }

    /// Real user agents, as the operators document them. Matching is on whole
    /// words, so each of these has to survive the boundary rules.
    func testOperatorsPublishedUserAgentsMatch() {
        let cases: [(ua: String, token: String, purpose: AIAgentPurpose)] = [
            ("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)", "GPTBot", .training),
            ("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot", "ChatGPT-User", .userTriggered),
            ("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; OAI-SearchBot/1.0; +https://openai.com/searchbot", "OAI-SearchBot", .aiSearch),
            ("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)", "ClaudeBot", .training),
            ("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-User/1.0; +Claude-User@anthropic.com)", "Claude-User", .userTriggered),
            ("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-SearchBot/1.0; +Claude-SearchBot@anthropic.com)", "Claude-SearchBot", .aiSearch),
            ("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)", "PerplexityBot", .aiSearch),
            ("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Perplexity-User/1.0; +https://perplexity.ai/perplexity-user)", "Perplexity-User", .userTriggered),
            ("CCBot/2.0 (https://commoncrawl.org/faq/)", "CCBot", .training),
            ("Mozilla/5.0 (Linux; Android 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; Bytespider; spider-feedback@bytedance.com)", "Bytespider", .training),
            ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.1.1 Safari/605.1.15 (Applebot/0.1; +http://www.apple.com/go/applebot)", "Applebot", .aiSearch),
            ("meta-externalagent/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)", "meta-externalagent", .training),
            ("meta-externalfetcher/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)", "meta-externalfetcher", .userTriggered),
            ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/600.2.5 (KHTML, like Gecko) Version/8.0.2 Safari/600.2.5 (Amazonbot/0.1; +https://developer.amazon.com/support/amazonbot)", "Amazonbot", .aiSearch),
            ("DuckAssistBot/1.2; (+http://duckduckgo.com/duckassistbot.html)", "DuckAssistBot", .userTriggered),
            ("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; MistralAI-User/1.0; +https://docs.mistral.ai/robots)", "MistralAI-User", .userTriggered),
            ("cohere-ai", "cohere-ai", .userTriggered),
            ("Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.1.2) Gecko/20090729 Firefox/3.5.2 (.NET CLR 3.5.30729; Diffbot/0.1; +http://www.diffbot.com)", "Diffbot", .training),
            ("Mozilla/5.0 (compatible; YouBot/1.0; +https://about.you.com/youbot/)", "YouBot", .aiSearch),
        ]
        for (ua, token, purpose) in cases {
            let match = AIAgentCatalog.match(userAgent: ua)
            XCTAssertEqual(match?.token, token, ua)
            XCTAssertEqual(match?.purpose, purpose, ua)
        }
    }

    /// `Google-Extended` and `Applebot-Extended` are robots.txt product
    /// tokens only: Google and Apple crawl as `Googlebot` and `Applebot`. They
    /// stay in the catalog (a header carrying them still matches) but real
    /// traffic is filed under the crawler that actually fetched.
    func testRobotsOnlyTokensDoNotHijackTheRealCrawler() {
        XCTAssertNil(AIAgentCatalog.match(userAgent: "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"))
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "Google-Extended")?.token, "Google-Extended")
        XCTAssertEqual(AIAgentCatalog.match(userAgent: "Applebot-Extended")?.token, "Applebot-Extended")
    }

    func testCatalogIsCleanedForUserAgentMatching() {
        let tokens = AIAgentCatalog.all.map(\.token)
        XCTAssertFalse(tokens.contains { $0.contains("/") }, "a version suffix survived")
        XCTAssertFalse(tokens.contains("Spider"))
        XCTAssertFalse(tokens.contains("Code"))
        XCTAssertEqual(Set(tokens.map { $0.lowercased() }).count, tokens.count)
    }

    func testOrdinaryBrowsersAreNotAgents() {
        let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        XCTAssertNil(AIAgentCatalog.match(userAgent: safari))
        XCTAssertNil(AIAgentCatalog.match(userAgent: nil))
        XCTAssertNil(AIAgentCatalog.match(userAgent: ""))
    }
}
