import XCTest
@testable import SwiftlyBotKit

final class AIAgentCatalogTests: XCTestCase {

    func testCatalogParsed() {
        XCTAssertGreaterThan(AIAgentCatalog.all.count, 150)
        // Sorted longest token first: the basis of `match`.
        let lengths = AIAgentCatalog.all.map(\.token.count)
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

    func testOrdinaryBrowsersAreNotAgents() {
        let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        XCTAssertNil(AIAgentCatalog.match(userAgent: safari))
        XCTAssertNil(AIAgentCatalog.match(userAgent: nil))
        XCTAssertNil(AIAgentCatalog.match(userAgent: ""))
    }
}
