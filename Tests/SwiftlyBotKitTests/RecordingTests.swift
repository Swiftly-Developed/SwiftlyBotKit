import XCTest
@testable import SwiftlyBotKit

final class LLMReferrerTests: XCTestCase {

    func testKnownPlatforms() {
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://chatgpt.com/c/abc"), "ChatGPT")
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://claude.ai/chat/123"), "Claude")
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://www.perplexity.ai/search/x"), "Perplexity")
        XCTAssertEqual(LLMReferrer.platform(forReferer: "https://gemini.google.com/app"), "Gemini")
    }

    func testOrdinaryReferrersAreIgnored() {
        XCTAssertNil(LLMReferrer.platform(forReferer: "https://www.google.com/search?q=x"))
        XCTAssertNil(LLMReferrer.platform(forReferer: "https://news.ycombinator.com/"))
        XCTAssertNil(LLMReferrer.platform(forReferer: nil))
    }

    /// Suffix matching must not let `notchatgpt.com` or `chatgpt.com.evil.test`
    /// through: it is a host match, not a substring one.
    func testLookalikeHostsAreNotMatched() {
        XCTAssertNil(LLMReferrer.platform(forReferer: "https://notchatgpt.com/x"))
        XCTAssertNil(LLMReferrer.platform(forReferer: "https://chatgpt.com.evil.test/x"))
    }
}

final class RecorderFilterTests: XCTestCase {

    private let gptbot = "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)"
    private let classifier = BotRequestClassifier(configuration: BotKitConfiguration())

    func testRecordsKnownAgentsAndReferrals() {
        XCTAssertTrue(classifier.isWorthRecording(path: "/insights/", userAgent: gptbot, referer: nil))
        XCTAssertTrue(classifier.isWorthRecording(path: "/pricing/", userAgent: "Safari", referer: "https://chatgpt.com/c/1"))
    }

    func testIgnoresOrdinaryTraffic() {
        XCTAssertFalse(classifier.isWorthRecording(path: "/", userAgent: "Safari", referer: nil))
        XCTAssertFalse(classifier.isWorthRecording(path: "/", userAgent: nil, referer: nil))
    }

    /// Assets a crawler pulls alongside a page would multiply every page view by
    /// its image count.
    func testIgnoresStaticAssets() {
        XCTAssertFalse(classifier.isWorthRecording(path: "/images/logo.svg", userAgent: gptbot, referer: nil))
        XCTAssertFalse(classifier.isWorthRecording(path: "/app.css", userAgent: gptbot, referer: nil))
    }

    /// robots.txt and sitemap.xml are deliberately still recorded: a crawler
    /// asking for either is exactly the signal this package exists to show.
    func testStillRecordsRobotsAndSitemap() {
        XCTAssertTrue(classifier.isWorthRecording(path: "/robots.txt", userAgent: gptbot, referer: nil))
        XCTAssertTrue(classifier.isWorthRecording(path: "/sitemap.xml", userAgent: gptbot, referer: nil))
    }

    func testDoesNotRecordItsOwnDashboard() {
        XCTAssertFalse(classifier.isWorthRecording(path: "/admin/ai-bots/", userAgent: gptbot, referer: nil))
        XCTAssertFalse(classifier.isWorthRecording(path: "/admin/ai-bots/login", userAgent: gptbot, referer: nil))
    }
}

final class BotSignerTests: XCTestCase {

    func testSessionTokenRoundTrip() {
        let signer = BotSigner(secret: "test-secret")
        let token = signer.sessionToken(expiresAt: Date().addingTimeInterval(3600))
        XCTAssertTrue(signer.isValidSessionToken(token))
    }

    func testExpiredTokenIsRejected() {
        let signer = BotSigner(secret: "test-secret")
        let token = signer.sessionToken(expiresAt: Date().addingTimeInterval(-1))
        XCTAssertFalse(signer.isValidSessionToken(token))
    }

    /// The expiry is inside the signed payload, so editing the cookie to buy
    /// another year breaks the signature.
    func testTamperedExpiryIsRejected() {
        let signer = BotSigner(secret: "test-secret")
        let token = signer.sessionToken(expiresAt: Date().addingTimeInterval(60))
        let mac = token.split(separator: ".", maxSplits: 1)[1]
        let forged = "\(Int(Date().timeIntervalSince1970) + 31_536_000).\(mac)"
        XCTAssertFalse(signer.isValidSessionToken(forged))
    }

    func testTokensDoNotTransferBetweenSecrets() {
        let token = BotSigner(secret: "secret-a").sessionToken(expiresAt: Date().addingTimeInterval(3600))
        XCTAssertFalse(BotSigner(secret: "secret-b").isValidSessionToken(token))
        XCTAssertFalse(BotSigner(secret: "secret-a").isValidSessionToken(nil))
        XCTAssertFalse(BotSigner(secret: "secret-a").isValidSessionToken("garbage"))
    }

    func testCredentialComparison() {
        let signer = BotSigner(secret: "test-secret")
        XCTAssertTrue(signer.matches("hunter2", expected: "hunter2"))
        XCTAssertFalse(signer.matches("hunter3", expected: "hunter2"))
        XCTAssertFalse(signer.matches("", expected: "hunter2"))
    }

    func testIPHashIsStableAndKeyed() {
        XCTAssertEqual(BotSigner(secret: "s").hashIP("1.2.3.4"), BotSigner(secret: "s").hashIP("1.2.3.4"))
        XCTAssertNotEqual(BotSigner(secret: "s").hashIP("1.2.3.4"), BotSigner(secret: "t").hashIP("1.2.3.4"))
        XCTAssertFalse(BotSigner(secret: "s").hashIP("1.2.3.4").contains("1.2.3.4"))
    }
}
