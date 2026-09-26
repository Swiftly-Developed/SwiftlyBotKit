import XCTest
import XCTVapor
import Fluent
import Logging
import NIOCore
import NIOConcurrencyHelpers
@testable import SwiftlyBotKit

// Adversarial review of configuration edge cases, concurrency and memory.
//
// Every test asserts what a reasonable integrator would expect, or what the
// doc comments promise. A failing test here is a bug or an API surprise, and
// its failure message says which. Nothing in this file needs a real database:
// `CfgAdvDatabase` below accepts every write and counts them.
//
// Tests that would crash the whole test process (arithmetic traps) are skipped
// unless `BOTKIT_ADVERSARIAL_TRAPS=1` is set, so they can be demonstrated one at
// a time with `--filter`.

// MARK: - Test doubles

/// Counts the rows the recorder writes.
final class CfgAdvWriteCounter: Sendable {
    private let box = NIOLockedValueBox<Int>(0)
    var count: Int { box.withLockedValue { $0 } }
    func increment() { box.withLockedValue { $0 += 1 } }
}

private struct CfgAdvDatabaseConfiguration: DatabaseConfiguration {
    var middleware: [any AnyModelMiddleware] = []
    let counter: CfgAdvWriteCounter
    func makeDriver(for databases: Databases) -> any DatabaseDriver { CfgAdvDriver(counter: counter) }
}

private struct CfgAdvDriver: DatabaseDriver {
    let counter: CfgAdvWriteCounter
    func makeDatabase(with context: DatabaseContext) -> any Database {
        CfgAdvDatabase(context: context, counter: counter)
    }
    func shutdown() {}
}

private struct CfgAdvDatabase: Database {
    let context: DatabaseContext
    let counter: CfgAdvWriteCounter

    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> ()) -> EventLoopFuture<Void> {
        if case .create = query.action { counter.increment() }
        return context.eventLoop.makeSucceededFuture(())
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { context.eventLoop.makeSucceededFuture(()) }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { context.eventLoop.makeSucceededFuture(()) }
    var inTransaction: Bool { false }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> { closure(self) }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> { closure(self) }
}

/// Answers every feed request with a fixed status and counts the requests.
private struct CfgAdvFeedClient: Client {
    let eventLoop: any EventLoop
    let status: HTTPStatus
    let body: String
    let requests: CfgAdvWriteCounter

    func delegating(to eventLoop: any EventLoop) -> any Client {
        CfgAdvFeedClient(eventLoop: eventLoop, status: status, body: body, requests: requests)
    }
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        requests.increment()
        return eventLoop.makeSucceededFuture(ClientResponse(status: status, body: ByteBuffer(string: body)))
    }
}

/// Collects log messages so warnings can be asserted on.
final class CfgAdvLogCapture: Sendable {
    private let box = NIOLockedValueBox<[(Logger.Level, String)]>([])
    var messages: [(Logger.Level, String)] { box.withLockedValue { $0 } }
    func append(_ level: Logger.Level, _ message: String) { box.withLockedValue { $0.append((level, message)) } }
    func warnings(containing text: String) -> Int {
        messages.filter { $0.0 >= .warning && $0.1.localizedCaseInsensitiveContains(text) }.count
    }
}

private struct CfgAdvLogHandler: LogHandler {
    let capture: CfgAdvLogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        capture.append(level, message.description)
    }
}

private let cfgAdvGPTBot = "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)"

/// Polls until `condition` holds or `timeout` passes. Recording happens in a
/// detached task, so a written row lags the response.
private func cfgAdvEventually(timeout: TimeInterval = 3, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Base class: an application with a fake default database and a log capture.
class CfgAdvAppTestCase: XCTestCase {
    var app: Application!
    let writes = CfgAdvWriteCounter()
    let logs = CfgAdvLogCapture()

    override func setUp() async throws {
        app = try await Application.make(.testing)
        let capture = logs
        app.logger = Logger(label: "adversarial") { _ in CfgAdvLogHandler(capture: capture) }
        app.databases.use(CfgAdvDatabaseConfiguration(counter: writes), as: DatabaseID(string: "fake"), isDefault: true)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    /// Credentials set, verification off (no network), recording off unless asked.
    func configuration(path: String = "/admin/ai-bots", recording: Bool = false) -> BotKitConfiguration {
        var config = BotKitConfiguration(signingSecret: "adversarial-secret")
        config.recording = .init(recordsAgents: recording, recordsReferrals: recording)
        config.verification.isEnabled = false
        config.dashboard.path = path
        config.dashboard.username = "owner"
        config.dashboard.password = "correct horse"
        return config
    }

    func signIn(at base: String, cookieName: String? = nil) async throws -> XCTHTTPResponse {
        var captured: XCTHTTPResponse!
        try await app.test(.POST, "\(base)/login", beforeRequest: { req in
            try req.content.encode(["username": "owner", "password": "correct horse"], as: .urlEncodedForm)
        }) { res async in captured = res }
        return captured
    }
}

// MARK: - Dashboard path

final class CfgAdvDashboardPathAdversarialTests: CfgAdvAppTestCase {

    func testNormalisationTable() {
        let cases: [(String, String, String)] = [
            // path, normalizedPath, basePath
            ("", "/", ""),
            ("/", "/", ""),
            ("//", "/", ""),
            ("admin", "/admin", "/admin"),
            ("/admin/", "/admin", "/admin"),
            ("/admin//x", "/admin/x", "/admin/x"),
            ("/Admin", "/Admin", "/Admin"),
        ]
        for (path, normalized, base) in cases {
            var dashboard = BotKitConfiguration.Dashboard()
            dashboard.path = path
            XCTAssertEqual(dashboard.normalizedPath, normalized, "normalizedPath for \(path.debugDescription)")
            XCTAssertEqual(dashboard.basePath, base, "basePath for \(path.debugDescription)")
        }
    }

    func testRelativeAndDoubledSlashPathsAreServed() async throws {
        try BotKit.configureRoutes(for: app, config: configuration(path: "/admin//x/"))
        try await app.test(.GET, "/admin/x/") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("action=\"/admin/x/login\""))
        }
        let signIn = try await signIn(at: "/admin/x")
        XCTAssertEqual(signIn.headers.first(name: .location), "/admin/x/")
    }

    func testMixedCasePathIsCaseSensitiveEverywhere() async throws {
        try BotKit.configureRoutes(for: app, config: configuration(path: "/Admin"))
        try await app.test(.GET, "/Admin/") { res async in XCTAssertEqual(res.status, .ok) }
        try await app.test(.GET, "/admin/") { res async in XCTAssertEqual(res.status, .notFound) }
        // Recording exclusion follows the router: case-sensitive, so the two agree.
        let classifier = BotRequestClassifier(configuration: configuration(path: "/Admin", recording: true))
        XCTAssertFalse(classifier.isWorthRecording(path: "/Admin/", userAgent: cfgAdvGPTBot, referer: nil))
    }

    /// A dashboard at the root would take over `/`, `/login` and `/logout`,
    /// and Vapor's router silently lets the later registration win. The root
    /// is refused with a descriptive error instead, and nothing is mounted.
    func testRootPathIsRejectedAndTheAppsOwnRoutesSurvive() async throws {
        app.get { _ in "home" }
        app.post("login") { _ in "app login" }
        for path in ["/", "", "//"] {
            XCTAssertThrowsError(try BotKit.configureRoutes(for: app, config: configuration(path: path)), path) { error in
                guard case BotKitConfigurationError.invalidDashboardPath(_, let reason) = error else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("root"), reason)
            }
        }
        try await app.test(.GET, "/") { res async in XCTAssertEqual(res.body.string, "home") }
        try await app.test(.POST, "/login") { res async in XCTAssertEqual(res.body.string, "app login") }
    }

    /// Formerly: with the dashboard at `/`, its own `/login` was recorded as
    /// site traffic. Moot now that a root dashboard is refused; what remains
    /// is that the refusal also happens with the dashboard disabled, so the
    /// exclusion can never be silently off.
    func testRootDashboardStillExcludesItsOwnEndpointsFromRecording() {
        var config = configuration(path: "", recording: true)
        config.dashboard.isEnabled = false
        XCTAssertThrowsError(try BotKit.configureRoutes(for: app, config: config))
    }

    /// `hasPrefix` without a segment boundary: `/admin` also swallows
    /// `/administrator`, `/admin-tools` and so on.
    func testExclusionRespectsPathSegmentBoundaries() {
        let classifier = BotRequestClassifier(configuration: configuration(path: "/admin", recording: true))
        XCTAssertFalse(classifier.isWorthRecording(path: "/admin", userAgent: cfgAdvGPTBot, referer: nil))
        XCTAssertFalse(classifier.isWorthRecording(path: "/admin/login", userAgent: cfgAdvGPTBot, referer: nil))
        XCTAssertTrue(classifier.isWorthRecording(path: "/administrator-guide/", userAgent: cfgAdvGPTBot, referer: nil),
            "BUG: dashboard path /admin also stops recording /administrator-guide/ (prefix match without a / boundary).")
        let defaults = BotRequestClassifier(configuration: BotKitConfiguration())
        XCTAssertTrue(defaults.isWorthRecording(path: "/admin/ai-bots-explained/", userAgent: cfgAdvGPTBot, referer: nil),
            "BUG: the default dashboard path stops recording the public page /admin/ai-bots-explained/.")
    }

    /// Route syntax in the configured path is refused rather than turned
    /// into a parameter, wildcard or catch-all.
    func testRouteSyntaxInThePathIsRejected() async throws {
        app.get("pricing") { _ in "pricing" }
        for path in ["/:section", "/*", "/**", "/admin/:id", "/admin/*x"] {
            XCTAssertThrowsError(try BotKit.configureRoutes(for: app, config: configuration(path: path)), path)
        }
        try await app.test(.GET, "/anything-at-all/") { res async in XCTAssertEqual(res.status, .notFound) }
        try await app.test(.GET, "/pricing") { res async in XCTAssertEqual(res.status, .ok) }
    }

    /// Characters a browser would encode, reserved characters, non-ASCII and
    /// dot segments are refused with a descriptive error.
    func testPathsThatCannotRoundTripAreRejected() {
        for path in ["/admin bots", "/admin\tbots", "/admin?tab=1", "/admin#x", "/admin%2Fbots",
                     "/tableau-de-bord-\u{E4}", "/admin/./x", "/admin/../x", "/a\"b", "/a<b"] {
            XCTAssertThrowsError(try BotKit.configureRoutes(for: app, config: configuration(path: path)), path) { error in
                XCTAssertTrue(error is BotKitConfigurationError, "\(error)")
                XCTAssertFalse(String(describing: error).isEmpty)
            }
        }
    }

    func testUnreservedCharactersAreAccepted() async throws {
        try BotKit.configureRoutes(for: app, config: configuration(path: "/internal_tools/ai-bots.v2~x"))
        try await app.test(.GET, "/internal_tools/ai-bots.v2~x/") { res async in XCTAssertEqual(res.status, .ok) }
    }
}

// MARK: - Date ranges

final class CfgAdvDateRangeAdversarialTests: XCTestCase {

    private func render(_ options: BotKitConfiguration.Dashboard, range: BotDateRange) -> String {
        DashboardPage.render(data: BotDashboardData(), range: range, sites: [], selectedSite: nil,
                             generatedAt: Date(), options: options, knownAgentCount: 1)
    }

    func testEmptyRangesOfferTheDefaultOnly() {
        var options = BotKitConfiguration.Dashboard()
        options.dateRanges = []
        options.defaultDateRange = .month
        XCTAssertEqual(options.offeredDateRanges, [.month])
        XCTAssertEqual(options.dateRange(forQuery: "24h"), .month)
        XCTAssertEqual(options.dateRange(forQuery: nil), .month)
        let html = render(options, range: .month)
        XCTAssertTrue(html.contains("range=30d"))
        XCTAssertFalse(html.contains("range=24h"))
    }

    func testDefaultNotOfferedFallsBackToFirst() {
        var options = BotKitConfiguration.Dashboard()
        options.dateRanges = [.quarter, .day]
        options.defaultDateRange = .week
        XCTAssertEqual(options.dateRange(forQuery: nil), .quarter)
        XCTAssertEqual(options.dateRange(forQuery: "7d"), .quarter)
    }

    func testDuplicateRangesRenderOnePillEach() {
        var options = BotKitConfiguration.Dashboard()
        options.dateRanges = [.day, .day, .week]
        let html = render(options, range: .day)
        let pills = html.components(separatedBy: "range=24h").count - 1
        XCTAssertEqual(pills, 1, "API SURPRISE: duplicate dateRanges render duplicate filter pills (\(pills) for 24h).")
    }
}

// MARK: - Sites

final class CfgAdvSiteAdversarialTests: XCTestCase {

    private let sites = [
        BotDashboardSite(key: "a", name: "Site A"),
        BotDashboardSite(key: "b", name: "Site B"),
    ]

    /// `all` is the all-sites sentinel, so a site keyed `all` could never be
    /// selected. It is refused at configuration time.
    func testSiteKeyedAllIsRejected() async throws {
        let app = try await Application.make(.testing)
        var config = BotKitConfiguration(sites: sites + [BotDashboardSite(key: "all", name: "All-hands intranet")])
        config.verification.isEnabled = false
        config.recording = .init(recordsAgents: false, recordsReferrals: false)
        XCTAssertThrowsError(try BotKit.configureRoutes(for: app, config: config)) { error in
            XCTAssertEqual(error as? BotKitConfigurationError, .reservedSiteKey("all"))
        }
        XCTAssertNil(config.site(forKey: "all", hostSiteKey: "a"), "?site=all is always the all-sites view")
        try await app.asyncShutdown()
    }

    /// Duplicate keys are deduplicated before rendering (first entry wins).
    func testDuplicateKeysAreNotBothOffered() {
        let duplicated = sites + [BotDashboardSite(key: "a", name: "Site A (copy)")]
        let unique = BotKitConfiguration.uniqueSites(duplicated)
        XCTAssertEqual(unique.map(\.name), ["Site A", "Site B"])
        let config = BotKitConfiguration(sites: duplicated)
        XCTAssertEqual(config.duplicateSiteKeys, ["a"])
        XCTAssertEqual(config.site(forKey: "a", hostSiteKey: "b")?.name, "Site A", "First entry wins.")
        let html = DashboardPage.render(data: BotDashboardData(), range: .week, sites: unique,
                                        selectedSite: config.site(forKey: "a", hostSiteKey: "b"),
                                        generatedAt: Date())
        XCTAssertFalse(html.contains("Site A (copy)"), "the duplicate entry must not be offered")
        XCTAssertTrue(html.contains("Site B"))
    }

    func testEmptyKeyAndUnknownHostKeys() {
        let config = BotKitConfiguration(sites: sites + [BotDashboardSite(key: "", name: "Blank")])
        // No `?site=`: the host's key decides.
        XCTAssertEqual(config.site(forKey: nil, hostSiteKey: "")?.name, "Blank")
        XCTAssertNil(config.site(forKey: nil, hostSiteKey: "unknown"), "Unknown host key opens the all-sites view.")
        XCTAssertNil(config.site(forKey: nil, hostSiteKey: "all"),
            "A siteKey closure returning \"all\" opens the all-sites view.")
        // `?site=` present but empty selects the blank-keyed site, not all sites.
        XCTAssertEqual(config.site(forKey: "", hostSiteKey: "a")?.name, "Blank")
    }

    func testHTMLInSiteNamesAndLogosIsEscaped() {
        let hostile = [
            BotDashboardSite(key: "x\"><script>k()</script>", name: "\"><script>alert(1)</script>",
                             logoPath: "x\" onerror=\"alert(2)"),
            BotDashboardSite(key: "b", name: "B & <b>bold</b>"),
        ]
        let html = DashboardPage.render(data: BotDashboardData(), range: .week, sites: hostile,
                                        selectedSite: hostile[0], generatedAt: Date())
        // `<` inside a double-quoted attribute (the summary aria-label) is inert;
        // what matters is that the quote is escaped and no element is opened.
        XCTAssertFalse(html.contains("\"><script>alert(1)"), "BUG: site name breaks out of an attribute.")
        XCTAssertFalse(html.contains(">\"><script>alert(1)") || html.contains("<span>\"><script>"), "BUG: site name reaches element content unescaped.")
        XCTAssertFalse(html.contains("<script>k()"), "BUG: site key reaches markup unescaped.")
        XCTAssertFalse(html.contains("onerror=\"alert(2)"), "BUG: logoPath breaks out of its attribute.")
        XCTAssertFalse(html.contains("<b>bold</b>"))
    }

    func testTitleWithHTMLIsEscaped() {
        var options = BotKitConfiguration.Dashboard()
        options.title = "</title><script>x()</script>"
        XCTAssertFalse(LoginPage.render(error: nil, options: options).contains("<script>x()"))
        XCTAssertFalse(DashboardPage.render(data: BotDashboardData(), range: .week, sites: [], selectedSite: nil,
                                            generatedAt: Date(), options: options).contains("<script>x()"))
    }
}

// MARK: - Sessions, login limit, cookie name

final class CfgAdvSessionAdversarialTests: CfgAdvAppTestCase {

    /// The `name=value` of the session Set-Cookie header: what a browser
    /// sends back. Sign-in also sends an empty `Path=/` cookie that expires
    /// the one earlier versions set; that one is skipped.
    private func cookiePair(from res: XCTHTTPResponse) -> String? {
        res.headers[.setCookie]
            .compactMap { $0.split(separator: ";", maxSplits: 1).first.map(String.init) }
            .first { !$0.hasSuffix("=") }
    }

    /// Black-box session check, independent of the token format: a signed-in
    /// GET gets past the sign-in page to the database step, which answers 503
    /// on the fake (non-SQL) database; a signed-out GET gets the 200 sign-in
    /// page.
    private func isSignedIn(cookie: String?, at base: String = "/admin/ai-bots") async throws -> Bool {
        guard let cookie else { return false }
        var status: HTTPStatus = .ok
        try await app.test(.GET, "\(base)/", headers: ["Cookie": cookie]) { res async in status = res.status }
        return status == .serviceUnavailable
    }

    /// A zero or negative lifetime signs the user in and hands back a cookie
    /// that is already expired: the owner is bounced back to the sign-in page
    /// forever, with no error anywhere.
    func testZeroAndNegativeSessionLifetime() async throws {
        for lifetime: TimeInterval in [0, -60] {
            try await app.asyncShutdown()
            try await setUp()
            var config = configuration()
            config.dashboard.sessionLifetime = lifetime
            try BotKit.configureRoutes(for: app, config: config)
            let res = try await signIn(at: "/admin/ai-bots")
            XCTAssertEqual(res.status, .seeOther)
            let signedIn = try await isSignedIn(cookie: cookiePair(from: res))
            XCTAssertTrue(signedIn,
                "API SURPRISE: sessionLifetime \(lifetime) is accepted, sign-in 'succeeds', and the cookie is already expired (sign-in loop, no validation or warning).")
        }
    }

    /// `Int(expiresAt.timeIntervalSince1970)` traps once the lifetime pushes
    /// the expiry past `Int.max` seconds (for example `.infinity` or `1e300`
    /// meaning "never expire"). That crashes the server on the first sign-in.
    func testHugeSessionLifetimeDoesNotTrap() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOTKIT_ADVERSARIAL_TRAPS"] == "1",
                          "Traps the process; set BOTKIT_ADVERSARIAL_TRAPS=1 to demonstrate.")
        var config = configuration()
        config.dashboard.sessionLifetime = .infinity
        try BotKit.configureRoutes(for: app, config: config)
        _ = try await signIn(at: "/admin/ai-bots")
    }

    /// Same trap in the lockout message: `describe(window)` does
    /// `Int(interval.rounded())`.
    func testHugeLoginWindowDoesNotTrap() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOTKIT_ADVERSARIAL_TRAPS"] == "1",
                          "Traps the process; set BOTKIT_ADVERSARIAL_TRAPS=1 to demonstrate.")
        _ = BotDashboardController.describe(.infinity)
    }

    /// Large but finite lifetimes below the trap threshold work.
    func testLongButFiniteSessionLifetime() async throws {
        var config = configuration()
        config.dashboard.sessionLifetime = 100 * 365 * 24 * 3600
        try BotKit.configureRoutes(for: app, config: config)
        let res = try await signIn(at: "/admin/ai-bots")
        let signedIn = try await isSignedIn(cookie: cookiePair(from: res))
        XCTAssertTrue(signedIn, "A 100-year lifetime (capped or not) must still yield a working session.")
    }

    /// `maximumFailures: 0` reads as "no throttling" but means "blocked before
    /// the first attempt": `0 >= 0`. The correct password is refused with 429
    /// forever.
    func testZeroMaximumFailuresDoesNotLockOutTheOwner() async throws {
        var config = configuration()
        config.dashboard.loginLimit = .init(maximumFailures: 0, window: 60)
        try BotKit.configureRoutes(for: app, config: config)
        let res = try await signIn(at: "/admin/ai-bots")
        XCTAssertEqual(res.status, .seeOther,
            "BUG: loginLimit.maximumFailures 0 (or negative) permanently locks out correct credentials with 429.")
    }

    /// A zero or negative window prunes every failure immediately, silently
    /// disabling brute-force protection.
    func testNonPositiveWindowStillThrottles() async throws {
        for window: TimeInterval in [0, -60] {
            let limiter = LoginAttemptLimiter(limit: .init(maximumFailures: 2, window: window))
            let now = Date()
            for _ in 0..<10 { await limiter.recordFailure("k", now: now) }
            let blocked = await limiter.isBlocked("k", now: now)
            XCTAssertTrue(blocked,
                "API SURPRISE: loginLimit.window \(window) silently disables throttling (10 failures, never blocked).")
        }
    }

    func testDescribeEdgeValues() {
        XCTAssertEqual(BotDashboardController.describe(0), "0 seconds")
        XCTAssertEqual(BotDashboardController.describe(0.4), "0 seconds")
        XCTAssertEqual(BotDashboardController.describe(1), "1 second")
        XCTAssertEqual(BotDashboardController.describe(7200), "2 hours")
        XCTAssertEqual(BotDashboardController.describe(3660), "61 minutes")
        XCTAssertFalse(BotDashboardController.describe(-60).hasPrefix("-"),
            "API SURPRISE: a negative window is shown to users as \(BotDashboardController.describe(-60).debugDescription).")
    }

    /// A cookie name must be an RFC 6265 token. Nothing validates it, so a
    /// name with `;`, `=` or a space produces a Set-Cookie header the browser
    /// splits differently, and the session is never read back: a sign-in loop.
    func testInvalidCookieNamesRoundTripOrAreRejected() async throws {
        for name in ["bad;name", "bad name", "bad=name"] {
            try await app.asyncShutdown()
            try await setUp()
            var config = configuration()
            config.dashboard.sessionCookieName = name
            var threw = false
            do { try BotKit.configureRoutes(for: app, config: config) } catch { threw = true }
            if threw { continue }
            let res = try await signIn(at: "/admin/ai-bots")
            guard let setCookie = res.headers.first(name: .setCookie) else {
                XCTFail("No Set-Cookie for \(name.debugDescription)"); continue
            }
            // Send back what a browser would: `name=value` up to the first `;`.
            let signedIn = try await isSignedIn(cookie: cookiePair(from: res))
            XCTAssertTrue(signedIn,
                "BUG: sessionCookieName \(name.debugDescription) is accepted, but the cookie never reads back (Set-Cookie: \(setCookie.prefix(60))...). Validate it as an RFC 6265 token.")
        }
    }
}

// MARK: - Config values and secrets

final class CfgAdvConfigValueAdversarialTests: CfgAdvAppTestCase {

    private func envKey() -> String {
        "BOTKIT_ADV_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

    func testEmptyEnvironmentVariableIsUnset() {
        let key = envKey()
        setenv(key, "", 1)
        defer { unsetenv(key) }
        XCTAssertNil(BotKitConfigValue.environment(key).resolve())
    }

    /// A value copied from a secrets manager often carries a newline or
    /// padding. Whitespace-only is then "configured", and a dashboard mounts
    /// with a blank-looking password.
    func testWhitespaceOnlyValuesCountAsUnset() {
        let key = envKey()
        setenv(key, "   \n", 1)
        defer { unsetenv(key) }
        XCTAssertNil(BotKitConfigValue.environment(key).resolve(),
            "API SURPRISE: a whitespace-only environment variable resolves as configured.")
        XCTAssertNil(BotKitConfigValue.value(" ").resolve(),
            "API SURPRISE: a whitespace-only value resolves as configured.")
    }

    func testTrailingNewlineIsNotPartOfThePassword() {
        let key = envKey()
        setenv(key, "hunter2\n", 1)
        defer { unsetenv(key) }
        XCTAssertEqual(BotKitConfigValue.environment(key).resolve(), "hunter2",
            "API SURPRISE: a trailing newline in the env var becomes part of the password.")
    }

    func testUsernameWithoutPasswordDoesNotMount() async throws {
        var config = configuration()
        config.dashboard.password = ""
        try BotKit.configureRoutes(for: app, config: config)
        try await app.test(.GET, "/admin/ai-bots/") { res async in XCTAssertEqual(res.status, .notFound) }
        XCTAssertEqual(logs.warnings(containing: "credentials are not configured"), 1)
    }

    func testEmptySigningSecretFallsBackToRandomWithAWarning() throws {
        var config = configuration()
        config.signingSecret = ""
        try BotKit.configureRoutes(for: app, config: config)
        XCTAssertEqual(logs.warnings(containing: "signing secret"), 1)
    }

    /// A one-character HMAC key is accepted silently. It makes the IP hash
    /// trivially reversible (brute-force the key, then the IPv4 space) and
    /// session cookies forgeable.
    func testTrivialSigningSecretIsWarnedAbout() throws {
        var config = configuration()
        config.signingSecret = "x"
        try BotKit.configureRoutes(for: app, config: config)
        XCTAssertGreaterThan(logs.warnings(containing: "secret"), 0,
            "API SURPRISE: a 1-character signingSecret is accepted with no warning.")
    }
}

// MARK: - Recording and dashboard toggles, double installation

final class CfgAdvInstallationAdversarialTests: CfgAdvAppTestCase {

    private func trackingMiddlewareCount() -> Int {
        app.middleware.resolve().filter { $0 is AIBotTrackingMiddleware }.count
    }

    private func registeredMigrationCount() -> Int {
        let storage = Mirror(reflecting: app.migrations).children.first { $0.label == "storage" }?.value
        guard let box = storage as? NIOLockedValueBox<[DatabaseID?: [any Migration]]> else { return -1 }
        return box.withLockedValue { $0.values.flatMap { $0 }.filter { $0 is CreateAIBotVisit }.count }
    }

    /// `BotKitRuntime` reads `app.client` inside `configureRoutes`, even with
    /// verification off. With the default provider that creates Vapor's shared
    /// `HTTPClient` there and then, so any `app.http.client.configuration`
    /// the app sets afterwards (timeouts, proxy, TLS) is ignored with only a
    /// warning, for the whole app, not just BotKit.
    func testConfigureRoutesDoesNotFreezeTheAppsHTTPClientConfiguration() throws {
        var config = configuration()
        config.verification.isEnabled = false
        try BotKit.configureRoutes(for: app, config: config)
        app.http.client.configuration.timeout = .init(connect: .seconds(1), read: .seconds(2))
        XCTAssertEqual(logs.warnings(containing: "Cannot modify client configuration"), 0,
            "BUG: after BotKit.configureRoutes (verification off, even), the app can no longer configure app.http.client; Vapor ignores the change.")
    }

    func testRecordingOffDashboardOn() async throws {
        try BotKit.configureRoutes(for: app, config: configuration(recording: false))
        XCTAssertEqual(trackingMiddlewareCount(), 0)
        try await app.test(.GET, "/admin/ai-bots/") { res async in XCTAssertEqual(res.status, .ok) }
    }

    func testRecordingOnDashboardOffStillExcludesTheDashboardPath() async throws {
        app.get("page") { _ in "page" }
        var config = configuration(recording: true)
        config.dashboard.isEnabled = false
        try BotKit.configureRoutes(for: app, config: config)
        XCTAssertEqual(trackingMiddlewareCount(), 1)
        try await app.test(.GET, "/admin/ai-bots/", headers: ["User-Agent": cfgAdvGPTBot]) { res async in
            XCTAssertEqual(res.status, .notFound)
        }
        try await app.test(.GET, "/page", headers: ["User-Agent": cfgAdvGPTBot]) { _ async in }
        let writes = self.writes
        let recorded = await cfgAdvEventually { writes.count >= 1 }
        XCTAssertTrue(recorded)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(writes.count, 1, "Only /page is recorded; the unmounted dashboard path stays excluded.")
    }

    /// `install` twice, or `configure` then `install`, would register the
    /// migration twice (the second `CREATE TYPE` fails) and install the
    /// middleware twice (every hit written twice). Both throw, and a throwing
    /// call registers nothing.
    func testDoubleInstallIsDetected() async throws {
        app.get("page") { _ in "page" }
        BotKit.configure(for: app)
        XCTAssertThrowsError(try BotKit.install(on: app, config: configuration(recording: true))) { error in
            guard case BotKitConfigurationError.alreadyInstalled(let detail) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(detail.contains("configure(for:database:pageViews:)"), detail)
        }
        XCTAssertEqual(registeredMigrationCount(), 1)
        XCTAssertEqual(trackingMiddlewareCount(), 0, "a refused install must not install the middleware")

        try BotKit.configureRoutes(for: app, config: configuration(recording: true))
        XCTAssertThrowsError(try BotKit.configureRoutes(for: app, config: configuration(recording: true)))
        XCTAssertEqual(trackingMiddlewareCount(), 1)
        try await app.test(.GET, "/page", headers: ["User-Agent": cfgAdvGPTBot]) { _ async in }
        let writes = self.writes
        _ = await cfgAdvEventually { writes.count >= 2 }
        XCTAssertEqual(writes.count, 1)
    }

    func testInstallTwiceThrows() throws {
        try BotKit.install(on: app, config: configuration(recording: true))
        XCTAssertThrowsError(try BotKit.install(on: app, config: configuration(recording: true)))
        XCTAssertEqual(registeredMigrationCount(), 1)
        XCTAssertEqual(trackingMiddlewareCount(), 1)
    }

    /// `configure` stays non-throwing: a repeat logs an error and is a no-op.
    func testConfigureTwiceLogsAndRegistersOnce() {
        BotKit.configure(for: app)
        BotKit.configure(for: app)
        XCTAssertEqual(registeredMigrationCount(), 1)
        XCTAssertEqual(logs.warnings(containing: "already registered"), 1)
    }

    /// An invalid configuration passed to `install` leaves nothing behind.
    func testInvalidInstallRegistersNothing() {
        XCTAssertThrowsError(try BotKit.install(on: app, config: configuration(path: "/")))
        XCTAssertEqual(registeredMigrationCount(), 0)
        XCTAssertEqual(trackingMiddlewareCount(), 0)
    }

    /// A siteKey closure returning the reserved `all` still records, filed as
    /// returned, and warns once per process.
    func testReservedSiteKeyAtRuntimeIsStoredAndWarnedOnce() async throws {
        app.get("page") { _ in "page" }
        var config = configuration(recording: true)
        config.siteKey = { _ in "all" }
        try BotKit.configureRoutes(for: app, config: config)
        for _ in 0..<3 {
            try await app.test(.GET, "/page", headers: ["User-Agent": cfgAdvGPTBot]) { _ async in }
        }
        let writes = self.writes
        let recorded = await cfgAdvEventually { writes.count >= 3 }
        XCTAssertTrue(recorded)
        XCTAssertEqual(logs.warnings(containing: "reserved for the dashboard's all-sites view"), 1)
    }

    /// Duplicate site keys are warned about at configuration time.
    func testDuplicateSiteKeysAreWarnedAbout() throws {
        var config = configuration()
        config.sites = [BotDashboardSite(key: "a", name: "A"), BotDashboardSite(key: "a", name: "A again")]
        try BotKit.configureRoutes(for: app, config: config)
        XCTAssertEqual(logs.warnings(containing: "more than once"), 1)
    }
}

/// A database whose writes stay pending until released, to hold recording
/// tasks in flight.
private final class CfgAdvStallingDatabaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [EventLoopPromise<Void>] = []
    private(set) var started = 0
    func hold(_ promise: EventLoopPromise<Void>) {
        lock.lock(); defer { lock.unlock() }
        pending.append(promise); started += 1
    }
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return started }
    func releaseAll() {
        lock.lock(); let held = pending; pending = []; lock.unlock()
        held.forEach { $0.succeed(()) }
    }
}

private struct CfgAdvStallingConfiguration: DatabaseConfiguration {
    var middleware: [any AnyModelMiddleware] = []
    let state: CfgAdvStallingDatabaseState
    func makeDriver(for databases: Databases) -> any DatabaseDriver { CfgAdvStallingDriver(state: state) }
}

private struct CfgAdvStallingDriver: DatabaseDriver {
    let state: CfgAdvStallingDatabaseState
    func makeDatabase(with context: DatabaseContext) -> any Database { CfgAdvStallingDatabase(context: context, state: state) }
    func shutdown() {}
}

private struct CfgAdvStallingDatabase: Database {
    let context: DatabaseContext
    let state: CfgAdvStallingDatabaseState
    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> ()) -> EventLoopFuture<Void> {
        let promise = context.eventLoop.makePromise(of: Void.self)
        state.hold(promise)
        return promise.futureResult
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { context.eventLoop.makeSucceededFuture(()) }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { context.eventLoop.makeSucceededFuture(()) }
    var inTransaction: Bool { false }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> { closure(self) }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> { closure(self) }
}

final class CfgAdvPendingWriteTests: XCTestCase {

    /// A stalled database plus a burst: in-flight writes stop at the cap, the
    /// rest are dropped with one warning, and the cap frees up afterwards.
    func testInFlightWritesAreCapped() async throws {
        let app = try await Application.make(.testing)
        let logs = CfgAdvLogCapture()
        app.logger = Logger(label: "pending") { _ in CfgAdvLogHandler(capture: logs) }
        let state = CfgAdvStallingDatabaseState()
        app.databases.use(CfgAdvStallingConfiguration(state: state), as: DatabaseID(string: "stall"), isDefault: true)
        app.get("page") { _ in "page" }
        var config = BotKitConfiguration(signingSecret: "pending-writes")
        config.verification.isEnabled = false
        config.dashboard.isEnabled = false
        config.recording.maximumPendingWrites = 2
        try BotKit.configureRoutes(for: app, config: config)

        for _ in 0..<6 {
            try await app.test(.GET, "/page", headers: ["User-Agent": cfgAdvGPTBot]) { _ async in }
        }
        let started = await cfgAdvEventually { state.startedCount >= 2 }
        XCTAssertTrue(started)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.startedCount, 2, "writes beyond the cap must be dropped, not queued")
        XCTAssertEqual(logs.warnings(containing: "Dropped an AI bot visit"), 1, "sampled: first drop only")

        state.releaseAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await app.test(.GET, "/page", headers: ["User-Agent": cfgAdvGPTBot]) { _ async in }
        let resumed = await cfgAdvEventually { state.startedCount >= 3 }
        XCTAssertTrue(resumed, "slots are released when writes finish")
        state.releaseAll()
        try await app.asyncShutdown()
    }

    func testDefaultAndClampedCap() {
        XCTAssertEqual(BotKitConfiguration.Recording.default.maximumPendingWrites, 256)
        XCTAssertEqual(PendingWriteLimiter(maximum: 0).maximum, 1)
        let limiter = PendingWriteLimiter(maximum: 1)
        XCTAssertTrue(limiter.acquire())
        XCTAssertFalse(limiter.acquire())
        limiter.release()
        XCTAssertTrue(limiter.acquire())
    }
}

// MARK: - Time zones

final class CfgAdvTimeZoneAdversarialTests: XCTestCase {

    func testIdentifierEdgeCases() {
        XCTAssertNil(BotKitTimeZone(identifier: ""), "Empty identifier is not a zone.")
        XCTAssertEqual(BotKitTimeZone(identifier: "UTC"), .utc)
        XCTAssertEqual(BotKitTimeZone(identifier: "Etc/UTC")?.foundationTimeZone.secondsFromGMT(), 0)
        XCTAssertEqual(BotKitTimeZone(identifier: "GMT")?.foundationTimeZone.secondsFromGMT(), 0)
    }

    /// Lowercase `utc`: Foundation may accept it (case-insensitive lookup) and
    /// hand back `.custom`, whose identifier then reaches PostgreSQL. Whatever
    /// happens, it must not be a different zone.
    func testLowercaseUTC() {
        if let zone = BotKitTimeZone(identifier: "utc") {
            XCTAssertEqual(zone.foundationTimeZone.secondsFromGMT(), 0)
            XCTAssertEqual(zone, .utc, "API SURPRISE: \"utc\" maps to \(zone) rather than .utc.")
        }
    }

    func testUTCAliasesMapToTheUTCCase() {
        for alias in ["Etc/UTC", "GMT", "Etc/GMT", "Zulu", "UCT"] {
            guard let zone = BotKitTimeZone(identifier: alias) else { continue }
            XCTAssertEqual(zone, .utc, "API SURPRISE: \(alias) maps to \(zone), not .utc, so it compares unequal to the default.")
        }
    }

    /// `US/Eastern` is a legacy link to `America/New_York`. It becomes
    /// `.custom`, which is not equal to `.americaNewYork`.
    func testLegacyAliasMapsToTheCanonicalCase() {
        guard let zone = BotKitTimeZone(identifier: "US/Eastern") else {
            return XCTFail("US/Eastern unknown to Foundation on this platform")
        }
        XCTAssertEqual(zone.foundationTimeZone.secondsFromGMT(for: Date(timeIntervalSince1970: 1_790_000_000)),
                       TimeZone(identifier: "America/New_York")!.secondsFromGMT(for: Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertEqual(zone, .americaNewYork,
            "API SURPRISE: BotKitTimeZone(identifier: \"US/Eastern\") is \(zone), not .americaNewYork.")
    }

    func testAllNamedIsUniqueByIdentifier() {
        let identifiers = BotKitTimeZone.allNamed.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for zone in BotKitTimeZone.allNamed {
            XCTAssertEqual(BotKitTimeZone(identifier: zone.identifier), zone, "Round trip \(zone.identifier)")
        }
    }

    /// Synthesised `Hashable` compares the case, not the zone: the same zone
    /// wrapped in `.custom` is a different value and a different hash bucket.
    func testCustomEqualsNamedForTheSameZone() {
        let tokyo = BotKitTimeZone.custom(TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(tokyo.identifier, BotKitTimeZone.asiaTokyo.identifier)
        XCTAssertEqual(tokyo, .asiaTokyo,
            "API SURPRISE: .custom(TimeZone(identifier: \"Asia/Tokyo\")!) != .asiaTokyo (synthesised Equatable compares cases).")
        XCTAssertEqual(Set([tokyo, .asiaTokyo]).count, 1)
    }

}

// MARK: - Concurrency stress

final class CfgAdvConcurrencyStressTests: XCTestCase {

    func testLoginLimiterUnderContention() async {
        let limiter = LoginAttemptLimiter(limit: .init(maximumFailures: 1_000, window: 3600))
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<50 {
                group.addTask {
                    for index in 0..<20 {
                        await limiter.recordFailure("shared", now: now)
                        await limiter.recordFailure("k\(task)-\(index % 3)", now: now)
                        _ = await limiter.isBlocked("k\(task)-\(index % 5)", now: now)
                        if index % 7 == 0 { await limiter.reset("k\(task)-0") }
                    }
                }
            }
        }
        let blocked = await limiter.isBlocked("shared", now: now)
        XCTAssertTrue(blocked, "Exactly 1000 failures must block at a limit of 1000.")
        await limiter.reset("shared")
        let afterReset = await limiter.isBlocked("shared", now: now)
        XCTAssertFalse(afterReset)
    }

    /// Failures are pruned only for the key being looked at. Keys never seen
    /// again (one per spoofed `X-Forwarded-For` value) stay forever.
    func testLoginLimiterDoesNotGrowWithoutBound() async {
        let limiter = LoginAttemptLimiter(limit: .init(maximumFailures: 5, window: 60))
        let then = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<5_000 { await limiter.recordFailure("ip-\(index)", now: then) }
        _ = await limiter.isBlocked("someone-else", now: then.addingTimeInterval(3600))
        let entries = (Mirror(reflecting: limiter).children.first { $0.label == "failures" }?.value
            as? [String: [Date]])?.count ?? -1
        XCTAssertLessThan(entries, 5_000,
            "BUG: \(entries) expired limiter entries remain an hour after their window closed; one entry per distinct client key is kept forever (memory growth under a spoofed-IP brute force).")
    }

    func testSignerIsDeterministicUnderContention() async {
        let signer = BotSigner(secret: "stress")
        let expiry = Date().addingTimeInterval(3600)
        let binding = signer.credentialBinding(username: "owner", password: "correct horse")
        let expectedToken = signer.sessionToken(expiresAt: expiry, binding: binding)
        let expectedHash = signer.hashIP("203.0.113.9")
        let mismatches = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    var bad = 0
                    for index in 0..<200 {
                        if signer.sessionToken(expiresAt: expiry, binding: binding) != expectedToken { bad += 1 }
                        if !signer.isValidSessionToken(expectedToken, binding: binding) { bad += 1 }
                        if signer.hashIP("203.0.113.9") != expectedHash { bad += 1 }
                        if !signer.matches("pw\(index)", expected: "pw\(index)") { bad += 1 }
                    }
                    return bad
                }
            }
            return await group.reduce(0, +)
        }
        XCTAssertEqual(mismatches, 0)
    }

    func testClassifierIsDeterministicUnderContention() async {
        var config = BotKitConfiguration()
        config.detection.customAgents = [AIAgent(token: "StressBot", purpose: .agent)]
        let classifier = BotRequestClassifier(configuration: config)
        let inputs: [(String, String?, String?)] = [
            ("/", cfgAdvGPTBot, nil), ("/a.png", cfgAdvGPTBot, nil), ("/admin/ai-bots/x", cfgAdvGPTBot, nil),
            ("/p", "Safari", "https://chatgpt.com/"), ("/p", "Safari", nil), ("/p", "StressBot/1", nil),
            ("/robots.txt", "ClaudeBot/1.0", nil), ("/p", nil, "https://evil.test/"),
        ]
        let expected = inputs.map { classifier.isWorthRecording(path: $0.0, userAgent: $0.1, referer: $0.2) }
        let mismatches = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    var bad = 0
                    for _ in 0..<250 {
                        for (index, input) in inputs.enumerated()
                        where classifier.isWorthRecording(path: input.0, userAgent: input.1, referer: input.2) != expected[index] {
                            bad += 1
                        }
                    }
                    return bad
                }
            }
            return await group.reduce(0, +)
        }
        XCTAssertEqual(mismatches, 0)
    }

    /// Concurrent first calls share one refresh.
    func testDirectoryDeduplicatesTheFirstRefresh() async throws {
        let app = try await Application.make(.testing)
        let requests = CfgAdvWriteCounter()
        let feed = #"{"prefixes":[{"ipv4Prefix":"20.171.0.0/16"}]}"#
        let client = CfgAdvFeedClient(eventLoop: app.eventLoopGroup.next(), status: .ok, body: feed, requests: requests)
        let feeds = [CrawlerRangeFeed(url: "https://feed.test/a.json", agentTokens: ["GPTBot"])]
        let directory = CrawlerIPDirectory(feeds: feeds, client: client, logger: app.logger)
        let results = await withTaskGroup(of: BotVerification.self, returning: [BotVerification].self) { group in
            for _ in 0..<100 { group.addTask { await directory.verify(agentToken: "GPTBot", clientIP: "20.171.1.1") } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(results), [.verified])
        XCTAssertEqual(requests.count, 1, "100 concurrent first calls must share one fetch.")
        try await app.asyncShutdown()
    }

    /// When every feed fails, nothing is cached and `lastRefresh` stays nil,
    /// so each verification starts a fresh round of fetches, back to back
    /// with no backoff, and every recorder task awaits it.
    func testDirectoryBacksOffWhenEveryFeedFails() async throws {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        let requests = CfgAdvWriteCounter()
        let client = CfgAdvFeedClient(eventLoop: app.eventLoopGroup.next(), status: .internalServerError, body: "", requests: requests)
        let directory = CrawlerIPDirectory(feeds: CrawlerRangeFeed.defaults, client: client, logger: app.logger)
        for _ in 0..<50 { _ = await directory.verify(agentToken: "GPTBot", clientIP: "20.171.1.1") }
        XCTAssertLessThanOrEqual(requests.count, CrawlerRangeFeed.defaults.count * 2,
            "BUG: 50 bot visits during a vendor outage made \(requests.count) feed requests (no backoff after a failed refresh).")
        try await app.asyncShutdown()
    }

    /// End to end: many concurrent bot requests through the middleware, each
    /// written exactly once.
    func testMiddlewareRecordsEveryConcurrentRequestOnce() async throws {
        let app = try await Application.make(.testing)
        let writes = CfgAdvWriteCounter()
        app.databases.use(CfgAdvDatabaseConfiguration(counter: writes), as: DatabaseID(string: "fake"), isDefault: true)
        app.get("page") { _ in "page" }
        var config = BotKitConfiguration(signingSecret: "stress")
        config.verification.isEnabled = false
        config.dashboard.isEnabled = false
        // Above the burst size: this test is about exactly-once, not the cap.
        config.recording.maximumPendingWrites = 1_000
        try BotKit.configureRoutes(for: app, config: config)
        try await app.asyncBoot()
        let responder = app.responder.current
        let total = 300
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<total {
                group.addTask {
                    let req = Request(application: app, method: .GET, url: "/page",
                                      headers: ["User-Agent": cfgAdvGPTBot, "X-Forwarded-For": "198.51.100.\(index % 250)"],
                                      on: app.eventLoopGroup.next())
                    _ = try await responder.respond(to: req).get()
                }
            }
            try await group.waitForAll()
        }
        let done = await cfgAdvEventually(timeout: 10) { writes.count >= total }
        XCTAssertTrue(done)
        XCTAssertEqual(writes.count, total)
        try await app.asyncShutdown()
    }
}
