import XCTest
import XCTVapor
import NIOCore
@testable import SwiftlyBotKit

/// The defaults are the behaviour the package had before it was configurable.
/// A change here changes every app that relies on them, so it should be
/// deliberate.
final class ConfigurationDefaultsTests: XCTestCase {

    func testTopLevelDefaults() {
        let config = BotKitConfiguration()
        XCTAssertEqual(config.sites, [])
        XCTAssertEqual(config.signingSecret, .environment("BOT_DASHBOARD_SECRET"))
        XCTAssertEqual(config.recording, .default)
        XCTAssertEqual(config.detection, .default)
        XCTAssertEqual(config.verification, .default)
        XCTAssertEqual(config.dashboard, .default)
        guard case .lastForwardedFor = config.clientIP else {
            return XCTFail("The default client IP strategy must be the last X-Forwarded-For entry.")
        }
    }

    func testRecordingDefaults() {
        let recording = BotKitConfiguration.Recording.default
        XCTAssertTrue(recording.recordsAgents)
        XCTAssertTrue(recording.recordsReferrals)
        XCTAssertTrue(recording.isEnabled)
        XCTAssertEqual(recording.excludedPathPrefixes, [])
        XCTAssertEqual(recording.maximumPendingWrites, 256)
        XCTAssertEqual(recording.ignoredFileExtensions, [
            "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "ico",
            "css", "js", "mjs", "map", "woff", "woff2", "ttf", "otf",
            "mp4", "mov", "webm", "pdf", "zip",
        ])
        XCTAssertFalse(recording.ignoredFileExtensions.contains("txt"))
        XCTAssertFalse(recording.ignoredFileExtensions.contains("xml"))
    }

    func testDetectionDefaults() {
        let detection = BotKitConfiguration.Detection.default
        XCTAssertTrue(detection.includesBuiltInAgents)
        XCTAssertTrue(detection.includesBuiltInReferrers)
        XCTAssertEqual(detection.customAgents, [])
        XCTAssertEqual(detection.customReferrers, [])
        let classifier = BotRequestClassifier(configuration: BotKitConfiguration())
        XCTAssertEqual(classifier.agents.agents, AIAgentCatalog.all)
        XCTAssertEqual(classifier.referrers, LLMReferrer.builtInPlatforms)
    }

    func testVerificationDefaults() {
        let verification = BotKitConfiguration.Verification.default
        XCTAssertTrue(verification.isEnabled)
        XCTAssertEqual(verification.refreshInterval, 12 * 60 * 60)
        XCTAssertEqual(verification.feeds.map(\.url), [
            "https://openai.com/gptbot.json",
            "https://openai.com/searchbot.json",
            "https://openai.com/chatgpt-user.json",
            "https://claude.com/crawling/bots.json",
            "https://www.perplexity.ai/perplexitybot.json",
            "https://www.perplexity.ai/perplexity-user.json",
        ])
        XCTAssertEqual(
            verification.feeds.first { $0.url.contains("claude.com") }?.agentTokens,
            ["ClaudeBot", "Claude-User", "Claude-SearchBot"]
        )
    }

    func testDashboardDefaults() {
        let dashboard = BotKitConfiguration.Dashboard.default
        XCTAssertTrue(dashboard.isEnabled)
        XCTAssertEqual(dashboard.path, "/admin/ai-bots")
        XCTAssertEqual(dashboard.normalizedPath, "/admin/ai-bots")
        XCTAssertEqual(dashboard.username, .environment("BOT_DASHBOARD_USER"))
        XCTAssertEqual(dashboard.password, .environment("BOT_DASHBOARD_PASSWORD"))
        XCTAssertEqual(dashboard.title, "AI bot traffic")
        XCTAssertEqual(dashboard.timeZone, .utc)
        XCTAssertEqual(dashboard.timeZone.identifier, "UTC")
        XCTAssertEqual(dashboard.dateRanges, BotDateRange.allCases)
        XCTAssertEqual(dashboard.defaultDateRange, .week)
        XCTAssertEqual(dashboard.sessionCookieName, "botkit_dashboard")
        XCTAssertEqual(dashboard.sessionLifetime, 12 * 60 * 60)
        XCTAssertEqual(dashboard.secureCookies, .automatic)
        XCTAssertEqual(dashboard.loginLimit, .init(maximumFailures: 5, window: 15 * 60))
        XCTAssertEqual(dashboard.loginLimit.globalMaximumFailures, 50)
    }
}

final class ConfigValueTests: XCTestCase {

    func testLiteralIsADirectValue() {
        let value: BotKitConfigValue = "owner"
        XCTAssertEqual(value, .value("owner"))
        XCTAssertEqual(value.resolve(), "owner")
    }

    func testEmptyAndUnsetResolveToNil() {
        XCTAssertNil(BotKitConfigValue.value("").resolve())
        XCTAssertNil(BotKitConfigValue.environment("BOTKIT_TEST_\(UUID().uuidString)").resolve())
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(BotKitConfigValue.value("  owner \n").resolve(), "owner")
        XCTAssertEqual(BotKitConfigValue.value("pass word").resolve(), "pass word", "inner whitespace is kept")
        XCTAssertNil(BotKitConfigValue.value(" \t\r\n").resolve())
    }

    func testEnvironmentIsReadAtResolveTime() {
        let key = "BOTKIT_TEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(key, "from-env", 1)
        defer { unsetenv(key) }
        XCTAssertEqual(BotKitConfigValue.environment(key).resolve(), "from-env")
    }
}

final class ClientIPStrategyTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    private func request(forwardedFor: String?, remote: String = "10.0.0.9") throws -> Request {
        var headers = HTTPHeaders()
        if let forwardedFor { headers.add(name: .xForwardedFor, value: forwardedFor) }
        return Request(
            application: app,
            headers: headers,
            remoteAddress: try SocketAddress(ipAddress: remote, port: 443),
            on: app.eventLoopGroup.next()
        )
    }

    /// The leftmost entry is whatever the client sent. Reading it would let a
    /// spoofer claim an operator's address and earn a `verified` badge.
    func testLastForwardedForIgnoresTheClientSuppliedEntry() throws {
        let req = try request(forwardedFor: "20.171.207.1, 203.0.113.7")
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: req), "203.0.113.7")
    }

    func testLastForwardedForFallsBackToTheSocket() throws {
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: try request(forwardedFor: nil)), "10.0.0.9")
    }

    func testTrustedProxyCountPicksFromTheRight() throws {
        let req = try request(forwardedFor: "1.1.1.1, 203.0.113.7, 198.51.100.2")
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 1).clientIP(for: req), "198.51.100.2")
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 2).clientIP(for: req), "203.0.113.7")
        // Fewer entries than proxies: every entry present was written by one
        // of them, so the first is the best answer.
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 5).clientIP(for: req), "1.1.1.1")
        XCTAssertEqual(ClientIPStrategy.forwardedFor(trustedProxies: 0).clientIP(for: req), "10.0.0.9")
    }

    func testRemoteAddressIgnoresTheHeader() throws {
        let req = try request(forwardedFor: "203.0.113.7")
        XCTAssertEqual(ClientIPStrategy.remoteAddress.clientIP(for: req), "10.0.0.9")
    }

    func testCustomStrategy() throws {
        var headers = HTTPHeaders()
        headers.add(name: "CF-Connecting-IP", value: "192.0.2.44")
        let req = Request(application: app, headers: headers, on: app.eventLoopGroup.next())
        let strategy = ClientIPStrategy.custom { $0.headers.first(name: "CF-Connecting-IP") }
        XCTAssertEqual(strategy.clientIP(for: req), "192.0.2.44")
    }

    /// Several header lines are one list, in order.
    /// Ports and brackets some proxies add are removed from the chosen entry.
    func testPortsAndBracketsAreStripped() throws {
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: try request(forwardedFor: "1.1.1.1, 1.2.3.4:5678")), "1.2.3.4")
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: try request(forwardedFor: "[2600::5]:443")), "2600::5")
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: try request(forwardedFor: "[2600::5]")), "2600::5")
        XCTAssertEqual(ClientIPStrategy.lastForwardedFor.clientIP(for: try request(forwardedFor: "2600::5")), "2600::5")
    }

    func testRepeatedHeadersAreOneList() throws {
        var headers = HTTPHeaders()
        headers.add(name: .xForwardedFor, value: "1.1.1.1")
        headers.add(name: .xForwardedFor, value: "203.0.113.7")
        XCTAssertEqual(ClientIPStrategy.forwardedEntry(in: headers, fromRight: 1), "203.0.113.7")
    }
}

final class DetectionConfigurationTests: XCTestCase {

    private func classifier(_ configure: (inout BotKitConfiguration) -> Void) -> BotRequestClassifier {
        var config = BotKitConfiguration()
        configure(&config)
        return BotRequestClassifier(configuration: config)
    }

    func testCustomAgentIsRecognised() {
        let classifier = classifier {
            $0.detection.customAgents = [
                AIAgent(token: "AcmeResearchBot", purpose: .userTriggered, operatorName: "Acme"),
            ]
        }
        let agent = classifier.agent(userAgent: "Mozilla/5.0 (compatible; acmeresearchbot/2.0)")
        XCTAssertEqual(agent?.token, "AcmeResearchBot")
        XCTAssertEqual(agent?.purpose, .userTriggered)
        // Built-ins still match alongside it.
        XCTAssertEqual(classifier.agent(userAgent: "GPTBot/1.2")?.token, "GPTBot")
    }

    func testCustomAgentReplacesTheBuiltInEntry() {
        let classifier = classifier {
            $0.detection.customAgents = [AIAgent(token: "gptbot", purpose: .scraper, operatorName: "Me")]
        }
        let agent = classifier.agent(userAgent: "GPTBot/1.2")
        XCTAssertEqual(agent?.purpose, .scraper)
        XCTAssertEqual(agent?.operatorName, "Me")
        XCTAssertEqual(classifier.agents.agents.count, AIAgentCatalog.all.count)
    }

    func testBuiltInCatalogCanBeTurnedOff() {
        let classifier = classifier {
            $0.detection.includesBuiltInAgents = false
            $0.detection.customAgents = [AIAgent(token: "OnlyBot", purpose: .agent)]
        }
        XCTAssertNil(classifier.agent(userAgent: "GPTBot/1.2"))
        XCTAssertEqual(classifier.agent(userAgent: "OnlyBot/1")?.operatorName, "Unknown")
    }

    func testCustomReferrers() {
        let classifier = classifier {
            $0.detection.customReferrers = [.init(hostSuffix: "assistant.example", name: "Example AI")]
        }
        XCTAssertEqual(classifier.referrerPlatform(referer: "https://chat.assistant.example/x"), "Example AI")
        XCTAssertEqual(classifier.referrerPlatform(referer: "https://claude.ai/chat/1"), "Claude")
        XCTAssertNil(classifier.referrerPlatform(referer: "https://notassistant.example/"))

        let only = self.classifier {
            $0.detection.includesBuiltInReferrers = false
            $0.detection.customReferrers = [.init(hostSuffix: "assistant.example", name: "Example AI")]
        }
        XCTAssertNil(only.referrerPlatform(referer: "https://claude.ai/chat/1"))
    }

    func testCustomReferrerReplacesTheBuiltInEntry() {
        let classifier = classifier {
            $0.detection.customReferrers = [.init(hostSuffix: "Claude.ai", name: "Anthropic Claude")]
        }
        XCTAssertEqual(classifier.referrerPlatform(referer: "https://claude.ai/chat/1"), "Anthropic Claude")
    }
}

final class RecordingConfigurationTests: XCTestCase {

    private let gptbot = "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)"

    func testExcludedPathPrefixes() {
        var config = BotKitConfiguration()
        config.recording.excludedPathPrefixes = ["/healthz", "/api/internal/"]
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertFalse(classifier.isWorthRecording(path: "/healthz", userAgent: gptbot, referer: nil))
        XCTAssertFalse(classifier.isWorthRecording(path: "/api/internal/x", userAgent: gptbot, referer: nil))
        XCTAssertTrue(classifier.isWorthRecording(path: "/api/public/", userAgent: gptbot, referer: nil))
    }

    func testCustomDashboardPathIsExcludedAndTheOldOneIsNot() {
        var config = BotKitConfiguration()
        config.dashboard.path = "internal/bots/"
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertFalse(classifier.isWorthRecording(path: "/internal/bots/", userAgent: gptbot, referer: nil))
        XCTAssertTrue(classifier.isWorthRecording(path: "/admin/ai-bots/", userAgent: gptbot, referer: nil))
    }

    func testIgnoredExtensionsAreConfigurable() {
        var config = BotKitConfiguration()
        config.recording.ignoredFileExtensions = ["txt"]
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertFalse(classifier.isWorthRecording(path: "/robots.txt", userAgent: gptbot, referer: nil))
        XCTAssertTrue(classifier.isWorthRecording(path: "/logo.png", userAgent: gptbot, referer: nil))
    }

    func testAgentAndReferralRecordingCanBeTurnedOffSeparately() {
        var config = BotKitConfiguration()
        config.recording.recordsAgents = false
        var classifier = BotRequestClassifier(configuration: config)
        XCTAssertFalse(classifier.isWorthRecording(path: "/", userAgent: gptbot, referer: nil))
        XCTAssertTrue(classifier.isWorthRecording(path: "/", userAgent: "Safari", referer: "https://chatgpt.com/"))

        config.recording.recordsAgents = true
        config.recording.recordsReferrals = false
        classifier = BotRequestClassifier(configuration: config)
        XCTAssertTrue(classifier.isWorthRecording(path: "/", userAgent: gptbot, referer: nil))
        XCTAssertFalse(classifier.isWorthRecording(path: "/", userAgent: "Safari", referer: "https://chatgpt.com/"))

        config.recording.recordsAgents = false
        XCTAssertFalse(config.recording.isEnabled)
    }
}

final class DashboardConfigurationTests: XCTestCase {

    func testPathNormalisation() {
        var dashboard = BotKitConfiguration.Dashboard()
        dashboard.path = "internal//bots/"
        XCTAssertEqual(dashboard.normalizedPath, "/internal/bots")
        XCTAssertEqual(dashboard.pathComponents, ["internal", "bots"])
        dashboard.path = "/"
        XCTAssertEqual(dashboard.normalizedPath, "/")
        XCTAssertEqual(dashboard.basePath, "")
    }

    func testDateRangeSelection() {
        var dashboard = BotKitConfiguration.Dashboard()
        XCTAssertEqual(dashboard.dateRange(forQuery: nil), .week)
        XCTAssertEqual(dashboard.dateRange(forQuery: "90d"), .quarter)
        XCTAssertEqual(dashboard.dateRange(forQuery: "bogus"), .week)

        dashboard.dateRanges = [.day, .month]
        dashboard.defaultDateRange = .month
        XCTAssertEqual(dashboard.dateRange(forQuery: "90d"), .month, "An unoffered range falls back to the default.")
        XCTAssertEqual(dashboard.dateRange(forQuery: "24h"), .day)

        dashboard.defaultDateRange = .quarter
        XCTAssertEqual(dashboard.dateRange(forQuery: nil), .day, "A default that is not offered falls back to the first offered range.")
    }

    func testRenderingUsesPathTitleRangesAndTimeZone() {
        var options = BotKitConfiguration.Dashboard()
        options.path = "/internal/bots"
        options.title = "Crawler watch"
        options.dateRanges = [.day, .week]
        options.timeZone = .americaNewYork

        let html = DashboardPage.render(
            data: BotDashboardData(),
            range: .week,
            sites: [],
            selectedSite: nil,
            generatedAt: Date(),
            options: options,
            knownAgentCount: 3
        )
        XCTAssertTrue(html.contains("Crawler watch"))
        XCTAssertFalse(html.contains("AI bot traffic"))
        XCTAssertTrue(html.contains("action=\"/internal/bots/logout\""))
        XCTAssertTrue(html.contains("/internal/bots/?site=all&amp;range=24h"))
        XCTAssertFalse(html.contains("range=30d"))
        XCTAssertFalse(html.contains("/admin/ai-bots"))

        var data = BotDashboardData()
        data.totals.botVisits = 1
        let populated = DashboardPage.render(
            data: data, range: .week, sites: [], selectedSite: nil,
            generatedAt: Date(), options: options, knownAgentCount: 3
        )
        XCTAssertTrue(populated.contains("America/New_York"))
        XCTAssertTrue(populated.contains("3 known agents"))

        let login = LoginPage.render(error: nil, options: options)
        XCTAssertTrue(login.contains("action=\"/internal/bots/login\""))
        XCTAssertTrue(login.contains("Crawler watch"))
    }

    /// A single-site app has nothing to switch between.
    func testSwitcherIsHiddenForFewerThanTwoSites() {
        let one = DashboardPage.render(
            data: BotDashboardData(), range: .week,
            sites: [BotDashboardSite(key: "default", name: "My site")],
            selectedSite: nil, generatedAt: Date()
        )
        XCTAssertFalse(one.contains("class=\"switcher\""))
    }

    /// The same instant falls in different daily buckets in different zones,
    /// and the bucket list follows the configured one.
    func testBucketsFollowTheConfiguredTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let buckets = BotDateRange.week.buckets(now: now, in: tokyo)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        for bucket in buckets {
            XCTAssertEqual(calendar.component(.hour, from: bucket), 0)
        }
        XCTAssertNotEqual(buckets, BotDateRange.week.buckets(now: now, in: TimeZone(identifier: "UTC")!))
    }

    func testSecureCookiePolicy() {
        let https: HTTPHeaders = ["X-Forwarded-Proto": "https"]
        XCTAssertTrue(BotDashboardController.isSecure(policy: .automatic, headers: https, scheme: nil))
        XCTAssertTrue(BotDashboardController.isSecure(policy: .automatic, headers: [:], scheme: "https"))
        XCTAssertFalse(BotDashboardController.isSecure(policy: .automatic, headers: [:], scheme: "http"))
        XCTAssertTrue(BotDashboardController.isSecure(policy: .always, headers: [:], scheme: nil))
        XCTAssertFalse(BotDashboardController.isSecure(policy: .never, headers: https, scheme: "https"))
    }

    func testDuplicateDateRangesAreOfferedOnce() {
        var dashboard = BotKitConfiguration.Dashboard()
        dashboard.dateRanges = [.day, .week, .day, .week]
        XCTAssertEqual(dashboard.offeredDateRanges, [.day, .week])
    }

    func testLoginLimitGlobalCeilingIsConfigurable() async throws {
        let limit = BotKitConfiguration.LoginLimit(maximumFailures: 3, window: 60, globalMaximumFailures: 9)
        let configured = await LoginAttemptLimiter(limit: limit).globalMaximumFailures
        XCTAssertEqual(configured, 9)
        // Never below the per-client limit.
        let clamped = await LoginAttemptLimiter(limit: .init(maximumFailures: 20, globalMaximumFailures: 5)).globalMaximumFailures
        XCTAssertEqual(clamped, 20)
        let defaulted = await LoginAttemptLimiter().globalMaximumFailures
        XCTAssertEqual(defaulted, 50)

        var config = BotKitConfiguration(signingSecret: "limit-wiring-secret-that-is-long-enough")
        config.verification.isEnabled = false
        config.dashboard.loginLimit = limit
        let runtime = BotKitRuntime(configuration: config, clientProvider: { nil }, logger: Logger(label: "test"))
        let wired = await runtime.loginAttempts.globalMaximumFailures
        XCTAssertEqual(wired, 9)
    }

    func testDashboardPathValidation() {
        for valid in ["/admin/ai-bots", "admin", "/a/b/c/", "/x.y_z~1"] {
            var dashboard = BotKitConfiguration.Dashboard()
            dashboard.path = valid
            XCTAssertNoThrow(try dashboard.validatePath(), valid)
        }
        for invalid in ["/", "", "/:id", "/*", "/**", "/a b", "/a?b", "/caf\u{E9}", "/a/../b", "/a%20b", "/a\u{0}b"] {
            var dashboard = BotKitConfiguration.Dashboard()
            dashboard.path = invalid
            XCTAssertThrowsError(try dashboard.validatePath(), invalid.debugDescription)
        }
    }

    func testSessionCookieNameValidation() {
        for valid in ["botkit_dashboard", "swiftly_bot_dashboard", "__Host-x", "a.b!#$%&'*+-^`|~"] {
            var dashboard = BotKitConfiguration.Dashboard()
            dashboard.sessionCookieName = valid
            XCTAssertNoThrow(try dashboard.validateCookieName(), valid)
        }
        for invalid in ["", "a b", "a;b", "a=b", "a,b", "a\"b", "a/b", "caf\u{E9}", "a\tb", "a\u{7F}"] {
            var dashboard = BotKitConfiguration.Dashboard()
            dashboard.sessionCookieName = invalid
            XCTAssertThrowsError(try dashboard.validateCookieName(), invalid.debugDescription) { error in
                XCTAssertEqual(error as? BotKitConfigurationError, .invalidSessionCookieName(invalid))
            }
        }
    }

    func testIntervalDescriptions() {
        XCTAssertEqual(BotDashboardController.describe(15 * 60), "15 minutes")
        XCTAssertEqual(BotDashboardController.describe(3600), "1 hour")
        XCTAssertEqual(BotDashboardController.describe(90), "90 seconds")
    }
}

/// The dashboard's routes, end to end, without a database: signing in and the
/// sign-in page never touch one.
final class DashboardRoutingTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    private func configuration() -> BotKitConfiguration {
        var config = BotKitConfiguration(signingSecret: "test-secret")
        // No database in these tests, so nothing may try to write a row.
        config.recording = .init(recordsAgents: false, recordsReferrals: false)
        config.verification.isEnabled = false
        config.dashboard.path = "/internal/bots"
        config.dashboard.username = "owner"
        config.dashboard.password = "correct horse"
        config.dashboard.sessionCookieName = "test_session"
        config.dashboard.loginLimit = .init(maximumFailures: 2, window: 60)
        return config
    }

    func testCustomPathServesTheSignInPage() async throws {
        try BotKit.configureRoutes(for: app, config: configuration())
        try await app.test(.GET, "/internal/bots/") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("action=\"/internal/bots/login\""))
            XCTAssertEqual(res.headers.first(name: "x-robots-tag"), "noindex, nofollow")
        }
        try await app.test(.GET, "/admin/ai-bots/") { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    func testSignInSetsTheConfiguredCookieAndRedirectsToThePath() async throws {
        try BotKit.configureRoutes(for: app, config: configuration())
        try await app.test(.POST, "/internal/bots/login", beforeRequest: { req in
            req.headers.add(name: "X-Forwarded-Proto", value: "https")
            try req.content.encode(["username": "owner", "password": "correct horse"], as: .urlEncodedForm)
        }) { res async in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/internal/bots/")
            let cookie = res.headers.setCookie?["test_session"]
            XCTAssertNotNil(cookie)
            XCTAssertEqual(cookie?.isSecure, true)
        }
    }

    func testLoginLimitIsConfigurable() async throws {
        try BotKit.configureRoutes(for: app, config: configuration())
        for expected in [HTTPStatus.unauthorized, .unauthorized, .tooManyRequests] {
            try await app.test(.POST, "/internal/bots/login", beforeRequest: { req in
                try req.content.encode(["username": "owner", "password": "wrong"], as: .urlEncodedForm)
            }) { res async in
                XCTAssertEqual(res.status, expected)
                if expected == .tooManyRequests {
                    XCTAssertTrue(res.body.string.contains("1 minute"))
                }
            }
        }
    }

    func testDashboardIsNotMountedWithoutCredentials() async throws {
        var config = configuration()
        config.dashboard.password = .environment("BOTKIT_TEST_UNSET_\(UUID().uuidString)")
        try BotKit.configureRoutes(for: app, config: config)
        try await app.test(.GET, "/internal/bots/") { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    /// Signs in and returns the session token from the scoped cookie.
    private func signInToken() async throws -> String {
        var token: String?
        try await app.test(.POST, "/internal/bots/login", beforeRequest: { req in
            try req.content.encode(["username": "owner", "password": "correct horse"], as: .urlEncodedForm)
        }) { res async in
            token = res.headers[.setCookie]
                .first { $0.contains("Path=/internal/bots") }
                .flatMap { $0.split(separator: ";").first }
                .map { String($0.split(separator: "=", maxSplits: 1)[1]) }
        }
        return try XCTUnwrap(token)
    }

    /// No database is registered here, so a signed-in GET answers 503 and a
    /// signed-out one the 200 sign-in page.
    private func isSignedIn(cookieHeader: String) async throws -> Bool {
        var status: HTTPStatus = .ok
        try await app.test(.GET, "/internal/bots/", headers: ["Cookie": cookieHeader]) { res async in status = res.status }
        return status == .serviceUnavailable
    }

    /// Sign-in and sign-out also expire a same-named `Path=/` cookie left by
    /// earlier versions.
    func testSignInAndSignOutClearTheLegacyRootCookie() async throws {
        try BotKit.configureRoutes(for: app, config: configuration())
        for endpoint in ["login", "logout"] {
            try await app.test(.POST, "/internal/bots/\(endpoint)", beforeRequest: { req in
                try req.content.encode(["username": "owner", "password": "correct horse"], as: .urlEncodedForm)
            }) { res async in
                let setCookies = res.headers[.setCookie]
                XCTAssertEqual(setCookies.filter { $0.hasPrefix("test_session=") }.count, 2, "\(endpoint): \(setCookies)")
                let legacy = setCookies.first { $0.contains("Path=/;") || $0.hasSuffix("Path=/") }
                XCTAssertNotNil(legacy, endpoint)
                XCTAssertTrue(legacy?.contains("Max-Age=0") == true, endpoint)
                XCTAssertTrue(legacy?.hasPrefix("test_session=;") == true, endpoint)
                XCTAssertTrue(setCookies.contains { $0.contains("Path=/internal/bots") }, endpoint)
            }
        }
    }

    /// A browser holding the stale root cookie sends both under one name, in
    /// either order. Any valid one signs the owner in.
    func testAValidTokenAmongSameNamedCookiesIsAccepted() async throws {
        try BotKit.configureRoutes(for: app, config: configuration())
        let token = try await signInToken()
        let bothOrders = [
            "test_session=\(token); test_session=stale",
            "test_session=stale; test_session=\(token)",
            "other=1; test_session=stale; test_session=\(token)",
        ]
        for header in bothOrders {
            let signedIn = try await isSignedIn(cookieHeader: header)
            XCTAssertTrue(signedIn, header)
        }
        let staleOnly = try await isSignedIn(cookieHeader: "test_session=stale; test_session=also-stale")
        XCTAssertFalse(staleOnly)
        let otherName = try await isSignedIn(cookieHeader: "not_test_session=\(token)")
        XCTAssertFalse(otherName)
    }

    func testCookieValuesParsing() {
        let headers: HTTPHeaders = ["Cookie": "a=1; b=2; a=\"3\"", "cookie": "a=4"]
        XCTAssertEqual(BotDashboardController.cookieValues(named: "a", in: headers), ["1", "3", "4"])
        XCTAssertEqual(BotDashboardController.cookieValues(named: "c", in: headers), [])
    }

    func testDashboardCanBeDisabled() async throws {
        var config = configuration()
        config.dashboard.isEnabled = false
        try BotKit.configureRoutes(for: app, config: config)
        try await app.test(.GET, "/internal/bots/") { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }
}

final class MigrationNameTests: XCTestCase {
    /// Apps record this string in `_fluent_migrations`; changing it makes an
    /// upgraded app try to create the table again.
    func testMigrationNameIsPinned() {
        XCTAssertEqual(CreateAIBotVisit().name, "SwiftlyBotKit.CreateAIBotVisit")
    }
}
