import Foundation
import XCTest
import XCTVapor
import NIOCore
import Fluent
@testable import SwiftlyBotKit

// Adversarial tests for the dashboard, its sign-in and its session cookie.
//
// Every test asserts the SECURE behaviour. A failing test is a finding: the
// attack in its doc comment works against the current code.
//
// No PostgreSQL is needed. A signed-in dashboard request reaches
// `req.db(...)`, so a stub database that is deliberately not an SQLDatabase is
// registered: the controller then answers 503. That gives a clean oracle:
// 503 means "the session was accepted and the data path was reached", 200
// with the sign-in form means "the session was rejected".

// MARK: - Fixtures

private let dashboardPath = "/internal/bots"
private let cookieName = "test_session"
private let signingSecret = "adversarial-test-secret-0123456789abcdef"
private let ownerUser = "owner"
private let ownerPassword = "correct horse battery staple"

private func adversarialConfiguration(
    password: String = ownerPassword,
    secret: String = signingSecret,
    maximumFailures: Int = 2,
    clientIP: ClientIPStrategy = .lastForwardedFor
) -> BotKitConfiguration {
    var config = BotKitConfiguration(signingSecret: .value(secret))
    config.recording = .init(recordsAgents: false, recordsReferrals: false)
    config.verification.isEnabled = false
    config.clientIP = clientIP
    config.dashboard.path = dashboardPath
    config.dashboard.username = .value(ownerUser)
    config.dashboard.password = .value(password)
    config.dashboard.sessionCookieName = cookieName
    config.dashboard.loginLimit = .init(maximumFailures: maximumFailures, window: 60)
    return config
}

private func formBody(username: String, password: String) -> ByteBuffer {
    func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    return ByteBuffer(string: "username=\(enc(username))&password=\(enc(password))")
}

private func formHeaders(forwardedFor: String? = nil, extra: [(String, String)] = []) -> HTTPHeaders {
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/x-www-form-urlencoded")
    if let forwardedFor { headers.add(name: .xForwardedFor, value: forwardedFor) }
    for (name, value) in extra { headers.add(name: name, value: value) }
    return headers
}

/// A session token as the dashboard issues it for the fixture credentials.
private func validToken(password: String = ownerPassword, lifetime: TimeInterval = 600) -> String {
    let signer = BotSigner(secret: signingSecret)
    return signer.sessionToken(
        expiresAt: Date().addingTimeInterval(lifetime),
        binding: signer.credentialBinding(username: ownerUser, password: password)
    )
}

private func cookieHeaders(_ token: String, extra: [(String, String)] = []) -> HTTPHeaders {
    var headers = HTTPHeaders()
    headers.add(name: .cookie, value: "\(cookieName)=\(token)")
    for (name, value) in extra { headers.add(name: name, value: value) }
    return headers
}

/// A Fluent database that is registered and reachable but is not SQL, so the
/// dashboard's `as? SQLDatabase` check fails and it answers 503 rather than
/// Fluent crashing on "no database configured".
private struct NonSQLDatabaseConfiguration: DatabaseConfiguration {
    var middleware: [any AnyModelMiddleware] = []
    func makeDriver(for databases: Databases) -> any DatabaseDriver { NonSQLDriver() }
}

private struct NonSQLDriver: DatabaseDriver {
    func makeDatabase(with context: DatabaseContext) -> any Database { NonSQLDatabase(context: context) }
    func shutdown() {}
}

private struct NonSQLUnsupported: Error {}

private struct NonSQLDatabase: Database {
    let context: DatabaseContext
    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> ()) -> EventLoopFuture<Void> {
        context.eventLoop.makeFailedFuture(NonSQLUnsupported())
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        context.eventLoop.makeFailedFuture(NonSQLUnsupported())
    }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> {
        context.eventLoop.makeFailedFuture(NonSQLUnsupported())
    }
    var inTransaction: Bool { false }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }
}

/// Collects every log line so tests can assert what is, and is not, logged.
private final class AuthLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) {
        lock.lock(); storage.append(line); lock.unlock()
    }
    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    var joined: String { lines.joined(separator: "\n") }
}

private struct AuthCapturingLogHandler: LogHandler {
    let capture: AuthLogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicit: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let merged = metadata.merging(explicit ?? [:]) { _, new in new }
        capture.append("[\(level)] \(message) \(merged)")
    }
}

// MARK: - Session token integrity (signer level)

final class AuthSecurityAdversarialTests_SessionTokenAdversarialTests: XCTestCase {

    private let signer = BotSigner(secret: signingSecret)

    /// Attack: extend a captured session by editing the expiry in the cookie.
    func testEditedExpiryIsRejected() {
        let expiry = Date().addingTimeInterval(3600)
        let token = signer.sessionToken(expiresAt: expiry)
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        let extended = "\(Int(parts[0])! + 86_400 * 365).\(parts[1])"
        XCTAssertTrue(signer.isValidSessionToken(token))
        XCTAssertFalse(signer.isValidSessionToken(extended))
    }

    /// Attack: replay a cookie after its expiry.
    func testExpiredTokenIsRejected() {
        let token = signer.sessionToken(expiresAt: Date().addingTimeInterval(-1))
        XCTAssertFalse(signer.isValidSessionToken(token))
        let future = signer.sessionToken(expiresAt: Date().addingTimeInterval(60))
        XCTAssertFalse(signer.isValidSessionToken(future, now: Date().addingTimeInterval(61)))
    }

    /// Attack: mint a token with a guessed or default secret.
    func testTokenFromAnotherSecretIsRejected() {
        for guess in ["", "secret", "test-secret", "changeme", "BOT_DASHBOARD_SECRET"] {
            let forged = BotSigner(secret: guess).sessionToken(expiresAt: Date().addingTimeInterval(3600))
            XCTAssertFalse(signer.isValidSessionToken(forged), "secret guess \"\(guess)\" minted a valid session")
        }
    }

    /// Attack: malformed cookies that might crash a parser or slip past a
    /// sloppy comparison.
    func testMalformedTokensAreRejected() {
        let valid = signer.sessionToken(expiresAt: Date().addingTimeInterval(3600))
        let sig = String(valid.split(separator: ".")[1])
        let hostile = [
            "", ".", "..", "123.", ".\(sig)", "abc.def", "1.2.3",
            "99999999999999999999999.\(sig)",
            "-1.\(sig)",
            "\(valid.split(separator: ".")[0]).\(sig.uppercased())",
            "\(valid.split(separator: ".")[0]).\(sig.dropLast())",
            "\(valid.split(separator: ".")[0]).\(sig)00",
            "\(valid.split(separator: ".")[0]).\(String(repeating: "0", count: 64))",
            String(repeating: "A", count: 100_000),
        ]
        for token in hostile {
            XCTAssertFalse(signer.isValidSessionToken(token), "accepted hostile token: \(token.prefix(80))")
        }
    }

    /// Attack (malleability): the expiry is parsed with `Int(_:)`, which also
    /// accepts `+123` and `0123`, so one signature validates several distinct
    /// cookie strings. Not a forgery, but it defeats any denylist or log
    /// correlation keyed on the exact cookie value. Secure behaviour: only the
    /// canonical encoding is accepted.
    func testOnlyTheCanonicalEncodingIsAccepted() {
        let token = signer.sessionToken(expiresAt: Date().addingTimeInterval(3600))
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        XCTAssertFalse(signer.isValidSessionToken("+\(parts[0]).\(parts[1])"), "a '+' prefixed expiry was accepted")
        XCTAssertFalse(signer.isValidSessionToken("0\(parts[0]).\(parts[1])"), "a zero-padded expiry was accepted")
    }

    /// The HMAC key is shared between session tokens, credential comparison
    /// and IP hashing. Domain separation must stop an IP hash, which an
    /// attacker influences through `X-Forwarded-For`, from ever being a valid
    /// session signature.
    func testIPHashCannotBeReusedAsASessionSignature() {
        let seconds = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let crafted = signer.hashIP("bot-dashboard:\(seconds)")
        XCTAssertFalse(signer.isValidSessionToken("\(seconds).\(crafted)"))
        XCTAssertFalse(signer.isValidSessionToken("\(seconds).\(crafted)\(crafted)"))
    }

    /// The stored IP hash must be keyed (not reversible by hashing the IPv4
    /// space without the secret) and must never contain the address.
    func testIPHashIsKeyedAndDoesNotContainTheAddress() {
        let ip = "203.0.113.7"
        let hash = signer.hashIP(ip)
        XCTAssertFalse(hash.contains(ip))
        XCTAssertFalse(hash.contains("203"))
        XCTAssertEqual(hash.count, 32)
        XCTAssertEqual(hash, signer.hashIP(ip), "must be stable within one secret to count distinct clients")
        XCTAssertNotEqual(hash, BotSigner(secret: "other").hashIP(ip), "must depend on the secret")
    }

    /// Both halves of the credential check compare HMACs of equal length, so a
    /// short or long guess cannot be told apart by an early length mismatch.
    func testCredentialComparisonIsLengthIndependent() {
        XCTAssertTrue(signer.matches("owner", expected: "owner"))
        XCTAssertFalse(signer.matches("", expected: "owner"))
        XCTAssertFalse(signer.matches("owner\u{0}", expected: "owner"))
        XCTAssertFalse(signer.matches("owne", expected: "owner"))
        XCTAssertFalse(signer.matches(String(repeating: "x", count: 10_000), expected: "owner"))
    }
}

// MARK: - Route-level sessions

final class AuthSecurityAdversarialTests_SessionRouteAdversarialTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        app.databases.use(NonSQLDatabaseConfiguration(), as: DatabaseID(string: "nonsql"), isDefault: true)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    private func signIn(on app: Application, extraHeaders: [(String, String)] = []) async throws -> (HTTPStatus, HTTPCookies.Value?) {
        let res = try await app.sendRequest(
            .POST, "\(dashboardPath)/login",
            headers: formHeaders(extra: extraHeaders),
            body: formBody(username: ownerUser, password: ownerPassword)
        )
        return (res.status, res.headers.setCookie?[cookieName])
    }

    /// Sanity check for the oracle: a genuine session reaches the data path.
    func testGenuineSessionReachesTheDataPath() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration())
        let (status, cookie) = try await signIn(on: app)
        XCTAssertEqual(status, .seeOther)
        let token = try XCTUnwrap(cookie?.string)
        let res = try await app.sendRequest(.GET, "\(dashboardPath)/", headers: cookieHeaders(token))
        XCTAssertEqual(res.status, .serviceUnavailable, "signed-in request should reach the (non-SQL) database check")
        XCTAssertFalse(res.body.string.contains("action=\"\(dashboardPath)/login\""))
    }

    /// Attack: no cookie, a forged cookie, an expired cookie, a cookie signed
    /// with another secret. None may reach the data path.
    func testForgedAndExpiredCookiesGetTheSignInPage() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration())
        let now = Date()
        let tokens: [String?] = [
            nil,
            "1.deadbeef",
            "\(Int(now.addingTimeInterval(3600).timeIntervalSince1970)).\(String(repeating: "a", count: 64))",
            BotSigner(secret: signingSecret).sessionToken(expiresAt: now.addingTimeInterval(-5)),
            BotSigner(secret: "not-the-secret").sessionToken(expiresAt: now.addingTimeInterval(3600)),
        ]
        for token in tokens {
            let headers = token.map { cookieHeaders($0) } ?? HTTPHeaders()
            let res = try await app.sendRequest(.GET, "\(dashboardPath)/", headers: headers)
            XCTAssertEqual(res.status, .ok, "token \(token ?? "nil") was not rejected")
            XCTAssertTrue(res.body.string.contains("action=\"\(dashboardPath)/login\""))
        }
    }

    /// Attack: the owner rotates the dashboard password after a laptop or a
    /// cookie leaks. The signature covers only `bot-dashboard:<expiry>`, not
    /// the credentials, so every session issued under the old password stays
    /// valid until it expires (12 hours by default). Secure behaviour: a
    /// password change revokes outstanding sessions.
    func testChangingThePasswordRevokesExistingSessions() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration(password: ownerPassword))
        let (_, cookie) = try await signIn(on: app)
        let stolen = try XCTUnwrap(cookie?.string)

        let rotated = try await Application.make(.testing)
        rotated.databases.use(NonSQLDatabaseConfiguration(), as: DatabaseID(string: "nonsql"), isDefault: true)
        try BotKit.configureRoutes(for: rotated, config: adversarialConfiguration(password: "a brand new password after the leak"))
        let res = try await rotated.sendRequest(.GET, "\(dashboardPath)/", headers: cookieHeaders(stolen))
        let status = res.status
        try await rotated.asyncShutdown()
        XCTAssertEqual(status, .ok, "a session minted under the old password still reaches the data path")
    }

    /// KNOWN, DOCUMENTED LIMITATION (SECURITY.md, TheDashboard.md): sessions
    /// are stateless, so sign-out only clears the browser's cookie and a copy
    /// taken before sign-out stays valid until it expires. The documented
    /// remedy is changing the password, which is pinned by
    /// `testChangingThePasswordRevokesExistingSessions`. This test pins the
    /// documented behaviour so that a change to it is deliberate: sign-out
    /// clears the cookie, and a replayed copy is still accepted.
    func testSignOutClearsTheCookieButDoesNotRevokeACopy_KnownLimitation() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration())
        let (_, cookie) = try await signIn(on: app)
        let token = try XCTUnwrap(cookie?.string)
        let out = try await app.sendRequest(.POST, "\(dashboardPath)/logout", headers: cookieHeaders(token))
        XCTAssertEqual(out.status, .seeOther)
        let cleared = try XCTUnwrap(out.headers.setCookie?[cookieName])
        XCTAssertEqual(cleared.string, "")
        XCTAssertEqual(cleared.path, dashboardPath)
        let replay = try await app.sendRequest(.GET, "\(dashboardPath)/", headers: cookieHeaders(token))
        XCTAssertEqual(replay.status, .serviceUnavailable, "documented limitation: a copied token stays valid until expiry")
    }

    /// A token minted without the credential binding (the pre-0.1.0 format)
    /// is refused, even with the right secret and a future expiry.
    func testUnboundTokenIsRejected() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration())
        let unbound = BotSigner(secret: signingSecret).sessionToken(expiresAt: Date().addingTimeInterval(600))
        let res = try await app.sendRequest(.GET, "\(dashboardPath)/", headers: cookieHeaders(unbound))
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("action=\"\(dashboardPath)/login\""))
    }

    /// With no database registered at all, `req.db` would be a Fluent fatal
    /// error. A signed-in request must answer 503 instead of crashing.
    func testNoRegisteredDatabaseAnswers503() async throws {
        let bare = try await Application.make(.testing)
        try BotKit.configureRoutes(for: bare, config: adversarialConfiguration())
        let res = try await bare.sendRequest(.GET, "\(dashboardPath)/", headers: cookieHeaders(validToken()))
        let status = res.status
        try await bare.asyncShutdown()
        XCTAssertEqual(status, .serviceUnavailable)
    }

    /// A configured but unregistered database ID must not crash either.
    func testUnregisteredDatabaseIDAnswers503() async throws {
        var config = adversarialConfiguration()
        config.database = DatabaseID(string: "missing")
        try BotKit.configureRoutes(for: app, config: config)
        let res = try await app.sendRequest(.GET, "\(dashboardPath)/", headers: cookieHeaders(validToken()))
        XCTAssertEqual(res.status, .serviceUnavailable)
    }

    /// Attack: `Path=/` sends the admin session cookie with every request to
    /// every page on the host, so any other route, app or log on the same
    /// origin sees it. Secure behaviour: scope it to the dashboard path.
    func testSessionCookieIsScopedToTheDashboardPath() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration())
        let (_, cookie) = try await signIn(on: app, extraHeaders: [("X-Forwarded-Proto", "https")])
        let c = try XCTUnwrap(cookie)
        XCTAssertTrue(c.isHTTPOnly)
        XCTAssertTrue(c.isSecure)
        XCTAssertNotNil(c.sameSite)
        XCTAssertEqual(c.path, dashboardPath, "session cookie is sent to every path on the host")
    }

    /// Attack: login without TLS signals. The default `.automatic` policy
    /// leaves the cookie non-Secure over plain HTTP, which is expected; this
    /// test pins that a spoofed `X-Forwarded-Proto: http` cannot strip
    /// `Secure` when the policy is `.always`.
    func testAlwaysSecureCannotBeDowngradedByAHeader() async throws {
        var config = adversarialConfiguration()
        config.dashboard.secureCookies = .always
        try BotKit.configureRoutes(for: app, config: config)
        let (_, cookie) = try await signIn(on: app, extraHeaders: [("X-Forwarded-Proto", "http")])
        XCTAssertEqual(cookie?.isSecure, true)
    }

    /// With a non-PostgreSQL database the dashboard must fail closed (503)
    /// without leaking internals, not crash or render partial data.
    func testNonPostgresDatabaseFailsClosed() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration())
        let res = try await app.sendRequest(.GET, "\(dashboardPath)/?site=all&range=day", headers: cookieHeaders(validToken()))
        XCTAssertEqual(res.status, .serviceUnavailable)
        XCTAssertFalse(res.body.string.contains(signingSecret))
        XCTAssertFalse(res.body.string.contains(ownerPassword))
    }
}

// MARK: - Sign-in throttling

final class AuthSecurityAdversarialTests_LoginLimiterAdversarialTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    private func guess(forwardedFor: String?, password: String = "wrong") async throws -> HTTPStatus {
        try await app.sendRequest(
            .POST, "\(dashboardPath)/login",
            headers: formHeaders(forwardedFor: forwardedFor),
            body: formBody(username: ownerUser, password: password)
        ).status
    }

    /// Baseline: once blocked, even the right password is refused, so the
    /// block cannot be used as a success oracle.
    func testBlockedClientCannotUseTheRightPasswordAsAnOracle() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration())
        _ = try await guess(forwardedFor: "198.51.100.1")
        _ = try await guess(forwardedFor: "198.51.100.1")
        let status = try await guess(forwardedFor: "198.51.100.1", password: ownerPassword)
        XCTAssertEqual(status, .tooManyRequests)
    }

    /// Attack: rotate `X-Forwarded-For` on every guess. Under the default
    /// `.lastForwardedFor` strategy, an app reachable without an appending
    /// proxy (direct exposure, a misconfigured proxy, a second ingress) keys
    /// the limiter on an attacker-chosen string, so every guess gets a fresh
    /// allowance. The limiter has no global ceiling to fall back on. Secure
    /// behaviour: many failures across many "clients" eventually throttle.
    func testRotatingForwardedForHitsAGlobalCeiling() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration(maximumFailures: 2))
        var throttled = 0
        for i in 0..<60 {
            if try await guess(forwardedFor: "10.\(i / 250).\(i % 250).1") == .tooManyRequests { throttled += 1 }
        }
        XCTAssertGreaterThan(throttled, 0, "60 guesses from rotating X-Forwarded-For values were never throttled")
    }

    /// Attack: an IPv6 client owns at least a /64 (2^64 addresses) and can use
    /// a new source address per guess, even behind a correctly configured
    /// proxy. The limiter keys on the full address. Secure behaviour: IPv6
    /// clients are bucketed by their /64.
    func testIPv6AddressesInOneSlash64ShareABucket() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration(maximumFailures: 2))
        var statuses: [HTTPStatus] = []
        for i in 1...5 {
            statuses.append(try await guess(forwardedFor: "2001:db8:1234:5678::\(String(i, radix: 16))"))
        }
        XCTAssertTrue(statuses.contains(.tooManyRequests), "5 guesses from one /64 were never throttled: \(statuses.map(\.code))")
    }

    /// Attack: send the guesses concurrently. `isBlocked` and
    /// `recordFailure` are two separate actor calls with a suspension point
    /// between them, so every request in a burst passes the check before any
    /// failure is recorded. Secure behaviour: no more than `maximumFailures`
    /// guesses are ever evaluated per window.
    func testConcurrentBurstCannotExceedTheLimit() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration(maximumFailures: 2))
        let tester = try app.testable()
        let evaluated = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    try await tester.sendRequest(
                        .POST, "\(dashboardPath)/login",
                        headers: formHeaders(forwardedFor: "198.51.100.9"),
                        body: formBody(username: ownerUser, password: "wrong")
                    ).status
                }
            }
            var unauthorized = 0
            for try await status in group where status == .unauthorized { unauthorized += 1 }
            return unauthorized
        }
        XCTAssertLessThanOrEqual(evaluated, 2, "\(evaluated) concurrent guesses were evaluated against a limit of 2")
    }

    /// Attack (memory DoS): every distinct key gets a dictionary entry, and an
    /// entry is only pruned when that same key is seen again. Rotating keys
    /// (see the two tests above) grows the dictionary for the life of the
    /// process. Secure behaviour: expired entries are swept, so memory stays
    /// bounded by the live window.
    func testLimiterStateIsBoundedAfterTheWindow() async throws {
        let limiter = LoginAttemptLimiter(limit: .init(maximumFailures: 5, window: 60))
        let start = Date()
        for i in 0..<5_000 {
            await limiter.recordFailure("key-\(i)", now: start)
        }
        // Long after every one of those failures has expired, more traffic.
        let later = start.addingTimeInterval(3600)
        for i in 0..<10 {
            await limiter.recordFailure("fresh-\(i)", now: later)
            _ = await limiter.isBlocked("fresh-\(i)", now: later)
        }
        let failures = Mirror(reflecting: limiter).children.first { $0.label == "failures" }?.value
        let count = (failures as? [String: [Date]])?.count
        XCTAssertNotNil(count, "could not inspect limiter state")
        XCTAssertLessThanOrEqual(count ?? .max, 10, "expired limiter entries are never swept: \(count ?? -1) retained")
    }

    /// When the global ceiling trips, even the owner's correct password from a
    /// fresh address is refused, and the trip is logged once, loudly.
    func testGlobalCeilingLocksEveryoneOutAndLogsOnce() async throws {
        let capture = AuthLogCapture()
        app.logger = Logger(label: "limiter") { _ in AuthCapturingLogHandler(capture: capture) }
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration(maximumFailures: 2))
        for i in 0..<LoginAttemptLimiter.defaultGlobalMaximumFailures {
            let status = try await guess(forwardedFor: "10.1.\(i / 250).\(i % 250)")
            XCTAssertEqual(status, .unauthorized)
        }
        let owner1 = try await guess(forwardedFor: "192.0.2.200", password: ownerPassword)
        let owner2 = try await guess(forwardedFor: "192.0.2.201", password: ownerPassword)
        XCTAssertEqual(owner1, .tooManyRequests)
        XCTAssertEqual(owner2, .tooManyRequests)
        let critical = capture.lines.filter { $0.hasPrefix("[critical]") }
        XCTAssertEqual(critical.count, 1, "the global lockout should be logged exactly once per trip")
    }

    /// A successful sign-in releases its reservation and clears the client's
    /// failures.
    func testSuccessReleasesTheReservation() async {
        let limiter = LoginAttemptLimiter(limit: .init(maximumFailures: 2, window: 60), globalMaximumFailures: 3)
        let t0 = Date()
        guard case .allowed = await limiter.reserve("a", now: t0) else { return XCTFail("first attempt refused") }
        guard case .allowed(let at) = await limiter.reserve("a", now: t0) else { return XCTFail("second attempt refused") }
        await limiter.succeeded("a", reservation: at)
        let blocked = await limiter.isBlocked("a", now: t0)
        XCTAssertFalse(blocked)
        // One global failure remains from the first attempt, so two more fit.
        guard case .allowed = await limiter.reserve("b", now: t0) else { return XCTFail() }
        guard case .allowed = await limiter.reserve("c", now: t0) else { return XCTFail() }
        let tripped = await limiter.reserve("d", now: t0)
        XCTAssertEqual(tripped, .globallyBlocked)
        let later = await limiter.reserve("d", now: t0.addingTimeInterval(61))
        XCTAssertEqual(later, .allowed(t0.addingTimeInterval(61)))
    }

    /// The tracked-key cap holds even for direct `recordFailure` callers.
    func testTrackedKeysAreCapped() async {
        let limiter = LoginAttemptLimiter(limit: .init(maximumFailures: 5, window: 600), maximumTrackedKeys: 100)
        let t0 = Date()
        for i in 0..<1_000 { await limiter.recordFailure("k\(i)", now: t0) }
        let failures = Mirror(reflecting: limiter).children.first { $0.label == "failures" }?.value
        XCTAssertLessThanOrEqual((failures as? [String: [Date]])?.count ?? .max, 100)
    }

    /// Bucketing: IPv6 by /64 in any spelling, IPv4-mapped as IPv4.
    func testClientBuckets() {
        let bucket = LoginAttemptLimiter.bucket(for:)
        XCTAssertEqual(bucket("203.0.113.7"), "203.0.113.7")
        XCTAssertEqual(bucket("2001:db8:1:2::1"), bucket("2001:0db8:0001:0002:ffff:ffff:ffff:ffff"))
        XCTAssertEqual(bucket("[2001:db8:1:2::1]"), bucket("2001:db8:1:2::9%en0"))
        XCTAssertNotEqual(bucket("2001:db8:1:2::1"), bucket("2001:db8:1:3::1"))
        XCTAssertEqual(bucket("::ffff:198.51.100.4"), "198.51.100.4")
        XCTAssertEqual(bucket("not an address"), "not an address")
    }

    /// The window must slide: an attacker who waits it out gets a fresh
    /// allowance, and no more.
    func testWindowSlidesAndReblocks() async {
        let limiter = LoginAttemptLimiter(limit: .init(maximumFailures: 2, window: 60))
        let t0 = Date()
        await limiter.recordFailure("k", now: t0)
        await limiter.recordFailure("k", now: t0)
        let blockedEarly = await limiter.isBlocked("k", now: t0.addingTimeInterval(59))
        let blockedLate = await limiter.isBlocked("k", now: t0.addingTimeInterval(61))
        XCTAssertTrue(blockedEarly)
        XCTAssertFalse(blockedLate)
    }
}

// MARK: - CSRF, redirects, headers

final class AuthSecurityAdversarialTests_RequestForgeryAndHeaderAdversarialTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        app.databases.use(NonSQLDatabaseConfiguration(), as: DatabaseID(string: "nonsql"), isDefault: true)
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration(maximumFailures: 50))
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    /// Attack: a hostile page auto-submits a form to `/logout`. SameSite=Lax
    /// keeps the cookie off the cross-site POST, but the 303 response still
    /// carries `Set-Cookie: ...; Expires=1970`, which the browser applies on a
    /// top-level navigation. Secure behaviour: cross-origin POSTs are refused.
    func testCrossSiteLogoutIsRefused() async throws {
        let token = BotSigner(secret: signingSecret).sessionToken(expiresAt: Date().addingTimeInterval(600))
        let res = try await app.sendRequest(
            .POST, "\(dashboardPath)/logout",
            headers: cookieHeaders(token, extra: [("Origin", "https://evil.example"), ("Sec-Fetch-Site", "cross-site")])
        )
        XCTAssertEqual(res.status, .forbidden, "cross-site logout was processed (status \(res.status.code))")
        XCTAssertNil(res.headers.setCookie?[cookieName])
    }

    /// Attack: a hostile page makes every visitor's browser POST a password
    /// guess. Each visitor has their own IP and so their own limiter budget,
    /// turning a popular page into a distributed brute-forcer. Secure
    /// behaviour: cross-origin sign-in POSTs are refused before evaluation.
    func testCrossSiteLoginIsRefused() async throws {
        for origin in ["https://evil.example", "null"] {
            let res = try await app.sendRequest(
                .POST, "\(dashboardPath)/login",
                headers: formHeaders(extra: [("Origin", origin)]),
                body: formBody(username: ownerUser, password: ownerPassword)
            )
            XCTAssertEqual(res.status, .forbidden, "cross-site sign-in from Origin \(origin) was evaluated (status \(res.status.code))")
            XCTAssertNil(res.headers.setCookie?[cookieName])
        }
    }

    /// Same-origin sign-in must keep working once an origin check exists.
    func testSameOriginLoginStillWorks() async throws {
        let res = try await app.sendRequest(
            .POST, "\(dashboardPath)/login",
            headers: formHeaders(extra: [("Host", "bots.example"), ("Origin", "https://bots.example")]),
            body: formBody(username: ownerUser, password: ownerPassword)
        )
        XCTAssertEqual(res.status, .seeOther)
    }

    /// A proxy that rewrites `Host` but passes `X-Forwarded-Host` still
    /// allows same-origin sign-in; a `Sec-Fetch-Site: same-origin` request
    /// without `Origin` is allowed; one with no header at all is allowed.
    func testSameOriginVariantsAreAllowed() async throws {
        let cases: [[(String, String)]] = [
            [("Host", "127.0.0.1:8080"), ("X-Forwarded-Host", "bots.example"), ("Origin", "https://bots.example")],
            [("Host", "bots.example:443"), ("Origin", "https://BOTS.example")],
            [("Sec-Fetch-Site", "same-origin")],
            [],
        ]
        for extra in cases {
            let res = try await app.sendRequest(
                .POST, "\(dashboardPath)/login",
                headers: formHeaders(extra: extra),
                body: formBody(username: ownerUser, password: ownerPassword)
            )
            XCTAssertEqual(res.status, .seeOther, "refused \(extra)")
        }
    }

    /// `Sec-Fetch-Site: cross-site` alone refuses, and a lookalike origin
    /// does not match.
    func testCrossSiteVariantsAreRefused() async throws {
        let cases: [[(String, String)]] = [
            [("Sec-Fetch-Site", "cross-site")],
            [("Host", "bots.example"), ("Origin", "https://bots.example.evil.example")],
            [("Host", "bots.example"), ("Origin", "https://bots.example:8443")],
            [("Host", "bots.example"), ("Origin", "file://bots.example")],
        ]
        for extra in cases {
            let res = try await app.sendRequest(
                .POST, "\(dashboardPath)/login",
                headers: formHeaders(extra: extra),
                body: formBody(username: ownerUser, password: ownerPassword)
            )
            XCTAssertEqual(res.status, .forbidden, "allowed \(extra)")
        }
    }

    /// Every hardening header is on the page, the sign-in redirect, the
    /// sign-out redirect and the 403.
    func testHardeningHeadersOnEveryResponse() async throws {
        let responses = [
            try await app.sendRequest(.GET, "\(dashboardPath)/"),
            try await app.sendRequest(.POST, "\(dashboardPath)/login", headers: formHeaders(),
                                      body: formBody(username: ownerUser, password: ownerPassword)),
            try await app.sendRequest(.POST, "\(dashboardPath)/logout"),
            try await app.sendRequest(.POST, "\(dashboardPath)/logout", headers: HTTPHeaders([("Origin", "https://evil.example")])),
        ]
        for res in responses {
            XCTAssertEqual(res.headers.first(name: "X-Frame-Options"), "DENY")
            XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
            XCTAssertEqual(res.headers.first(name: "Referrer-Policy"), "no-referrer")
            XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
            XCTAssertEqual(
                res.headers.first(name: "Content-Security-Policy"),
                "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
            )
        }
    }

    /// Absolute logo URLs are allowed as images, and nothing hostile in a
    /// logo URL reaches the policy.
    func testContentSecurityPolicyAllowsConfiguredLogoOrigins() {
        let csp = BotDashboardController.contentSecurityPolicy(logoPaths: [
            "/images/a.svg",
            "https://cdn.example.com/logo.png",
            "https://cdn.example.com/other.png",
            "http://x.example:8080/l.png",
            "https://evil.example; script-src *",
            "javascript:alert(1)",
        ])
        XCTAssertTrue(csp.contains("img-src 'self' data: https://cdn.example.com http://x.example:8080;"), csp)
        XCTAssertFalse(csp.contains("script-src"))
        XCTAssertFalse(csp.contains("javascript"))
    }

    /// Attack: open redirect through `next`, `redirect`, `returnTo` or a
    /// hostile `Host`. The redirect must always be the fixed dashboard path.
    func testRedirectsAreAlwaysLocal() async throws {
        let query = "?next=https://evil.example&redirect=//evil.example&returnTo=%2F%2Fevil.example"
        let login = try await app.sendRequest(
            .POST, "\(dashboardPath)/login\(query)",
            headers: formHeaders(extra: [("Host", "evil.example"), ("X-Forwarded-Host", "evil.example")]),
            body: formBody(username: ownerUser, password: ownerPassword)
        )
        XCTAssertEqual(login.headers.first(name: .location), "\(dashboardPath)/")
        let logout = try await app.sendRequest(
            .POST, "\(dashboardPath)/logout\(query)",
            headers: HTTPHeaders([("Host", "evil.example")])
        )
        XCTAssertEqual(logout.headers.first(name: .location), "\(dashboardPath)/")
    }

    /// Attack: frame the sign-in page or the dashboard on a hostile site and
    /// clickjack the owner (sign-out, or a credential form overlaid with
    /// decoys). Secure behaviour: framing is forbidden.
    func testDashboardPagesForbidFraming() async throws {
        let res = try await app.sendRequest(.GET, "\(dashboardPath)/")
        let xfo = res.headers.first(name: "X-Frame-Options")?.uppercased()
        let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
        XCTAssertTrue(
            xfo == "DENY" || xfo == "SAMEORIGIN" || csp.contains("frame-ancestors"),
            "the sign-in page can be framed by any origin"
        )
    }

    /// Defence in depth for a page that renders attacker-influenced text:
    /// `nosniff` and a restrictive CSP (the page needs no JavaScript at all).
    func testDashboardPagesSendHardeningHeaders() async throws {
        let res = try await app.sendRequest(.GET, "\(dashboardPath)/")
        XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options")?.lowercased(), "nosniff")
        let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
        XCTAssertTrue(csp.contains("script-src 'none'") || csp.contains("default-src 'none'"),
                      "no CSP forbidding script on a page that renders crawler-supplied paths")
    }

    /// Authenticated and auth-related responses must never be cached,
    /// including the 303 that carries the session `Set-Cookie`.
    func testAuthResponsesAreNotCacheable() async throws {
        let page = try await app.sendRequest(.GET, "\(dashboardPath)/")
        XCTAssertEqual(page.headers.first(name: .cacheControl), "no-store")
        let failed = try await app.sendRequest(
            .POST, "\(dashboardPath)/login",
            headers: formHeaders(), body: formBody(username: ownerUser, password: "nope")
        )
        XCTAssertEqual(failed.status, .unauthorized)
        XCTAssertEqual(failed.headers.first(name: .cacheControl), "no-store")
        let ok = try await app.sendRequest(
            .POST, "\(dashboardPath)/login",
            headers: formHeaders(), body: formBody(username: ownerUser, password: ownerPassword)
        )
        XCTAssertNotNil(ok.headers.setCookie?[cookieName])
        XCTAssertEqual(ok.headers.first(name: .cacheControl), "no-store",
                       "the response that sets the session cookie carries no Cache-Control")
    }

    /// Attack: query parameters reflected into the sign-in page.
    func testQueryParametersAreNotReflected() async throws {
        let payload = "%3Cscript%3Ealert(1)%3C%2Fscript%3E"
        let res = try await app.sendRequest(.GET, "\(dashboardPath)/?site=\(payload)&range=\(payload)&next=\(payload)")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("<script>"))
        XCTAssertFalse(res.body.string.contains("alert(1)"))
    }

    /// Attack: header injection through anything that reaches a header.
    /// Nothing request-derived is written into `Location` or `Set-Cookie`.
    func testNoRequestDataReachesResponseHeaders() async throws {
        let res = try await app.sendRequest(
            .POST, "\(dashboardPath)/login?x=%0d%0aSet-Cookie:%20pwn=1",
            headers: formHeaders(extra: [("Host", "a.example\r\nX-Injected: 1")]),
            body: formBody(username: ownerUser, password: ownerPassword)
        )
        XCTAssertNil(res.headers.first(name: "X-Injected"))
        XCTAssertNil(res.headers.setCookie?["pwn"])
        for (_, value) in res.headers {
            XCTAssertFalse(value.contains("\r") || value.contains("\n"))
        }
    }
}

// MARK: - Path and method edge cases

final class AuthSecurityAdversarialTests_DashboardPathAdversarialTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        app.databases.use(NonSQLDatabaseConfiguration(), as: DatabaseID(string: "nonsql"), isDefault: true)
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration())
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    /// Attack: reach the data path without a session through path tricks.
    /// Auth lives in the handler, so every variant that routes at all must
    /// land on the sign-in page, never on the data path (503 in this setup).
    func testPathVariantsNeverReachDataWithoutASession() async throws {
        let variants = [
            dashboardPath, "\(dashboardPath)/", "/\(dashboardPath)//", "//internal//bots/",
            "/INTERNAL/BOTS/", "/Internal/Bots", "/internal/%62ots/", "/internal/bots%2F",
            "/internal/bots/.", "/internal/bots/./", "/x/../internal/bots/", "/internal/./bots",
            "/internal/bots;jsessionid=1", "/internal/bots/?", "/internal/bots/#frag",
            "/internal/bots/login", "/internal/bots/logout",
        ]
        for path in variants {
            let res = try await app.sendRequest(.GET, path)
            XCTAssertNotEqual(res.status, .serviceUnavailable, "\(path) reached the data path without a session")
            XCTAssertFalse(res.body.string.contains("Sign out"), "\(path) rendered the dashboard")
        }
    }

    /// Attack: HEAD, OPTIONS and unusual methods must not skip the auth check.
    func testOtherMethodsDoNotBypassAuth() async throws {
        for method in [HTTPMethod.HEAD, .OPTIONS, .PUT, .PATCH, .DELETE, .RAW(value: "PROPFIND")] {
            let res = try await app.sendRequest(method, "\(dashboardPath)/")
            XCTAssertNotEqual(res.status, .serviceUnavailable, "\(method) reached the data path without a session")
            XCTAssertFalse(res.body.string.contains("Sign out"))
        }
    }

    /// The recording exclusion is a raw `hasPrefix`, so a real site page such
    /// as `/internal/bots-explained` is silently never recorded. Not a bypass,
    /// but a correctness bug in the same path handling: the exclusion should
    /// match the path or a path segment below it.
    func testRecordingExclusionRespectsPathBoundaries() {
        let classifier = BotRequestClassifier(configuration: {
            var config = BotKitConfiguration()
            config.dashboard.path = dashboardPath
            return config
        }())
        XCTAssertFalse(classifier.isWorthRecording(path: "\(dashboardPath)/", userAgent: "GPTBot/1.2", referer: nil))
        XCTAssertTrue(
            classifier.isWorthRecording(path: "\(dashboardPath)-explained", userAgent: "GPTBot/1.2", referer: nil),
            "a public page that merely shares the dashboard's prefix is excluded from recording"
        )
    }
}

// MARK: - XSS

final class AuthSecurityAdversarialTests_DashboardEscapingAdversarialTests: XCTestCase {

    private let payload = "\"><script>alert(1)</script><img src=x onerror=alert(2)><svg onload=alert(3)>'"

    /// Markup is live only outside a quoted attribute value. Every attribute
    /// on these pages is double-quoted, and a `"` in a value must be encoded
    /// as `&quot;`, so stripping `="..."` leaves exactly the markup a browser
    /// would parse as tags. A `<script>` that survives that strip, or a tag
    /// that gained an event-handler attribute, is an injection.
    private func assertInert(_ html: String, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let stripped = html.replacingOccurrences(of: "=\"[^\"]*\"", with: "=\"\"", options: .regularExpression)
        XCTAssertFalse(stripped.contains("<script>alert"), "\(context): live <script>", file: file, line: line)
        XCTAssertFalse(stripped.contains("<img src=x"), "\(context): live <img>", file: file, line: line)
        XCTAssertFalse(stripped.contains("<svg onload"), "\(context): live <svg onload>", file: file, line: line)
        XCTAssertNil(
            stripped.range(of: "<[a-zA-Z][^<>]*\\son[a-z]+=", options: .regularExpression),
            "\(context): a tag gained an event-handler attribute", file: file, line: line
        )
        // Attribute breakout: an unescaped quote would leave `"><` right
        // after a value; after stripping that shows as `=""><script`.
        XCTAssertFalse(stripped.contains("\"\"><script"), "\(context): attribute breakout", file: file, line: line)
    }

    /// Attack: a crawler requests a path full of markup; custom agents, operator
    /// names and referrer platforms carry markup; the owner's own config (title,
    /// site names, logo paths) carries markup. All of it must render inert.
    func testEveryRenderedStringIsEscaped() {
        var data = BotDashboardData()
        data.totals.botVisits = 9
        data.totals.referrals = 2
        data.totals.distinctAgents = 1
        data.topAgents = [
            .init(name: payload, operatorName: payload, purpose: .training, count: 7,
                  verified: 1, spoofed: 1, respectsRobotsTxt: false),
            .init(name: "Other\(payload)", operatorName: "Unknown", purpose: nil, count: 2,
                  verified: 0, spoofed: 0, respectsRobotsTxt: nil),
        ]
        data.topPages = [.init(path: "/\(payload)", count: 5, userTriggered: 2)]
        data.referrals = [.init(platform: payload, count: 2)]
        data.series = [.init(bucket: Date(), counts: [.training: 3, .userTriggered: 1])]

        var options = BotKitConfiguration.Dashboard.default
        options.title = payload
        let sites = [
            BotDashboardSite(key: "a\(payload)", name: payload, logoPath: "/logo.png\(payload)"),
            BotDashboardSite(key: "b", name: "B\(payload)", logoPath: nil),
        ]
        let html = DashboardPage.render(
            data: data, range: .week, sites: sites, selectedSite: sites[0],
            generatedAt: Date(), options: options
        )
        assertInert(html, "dashboard")

        let login = LoginPage.render(error: payload, options: options)
        assertInert(login, "sign-in page")
    }

    /// Attack: a `?site=` value that is not a configured key must never be
    /// echoed or selected.
    func testUnknownSiteKeyIsNeverSelected() {
        var config = BotKitConfiguration()
        config.sites = [BotDashboardSite(key: "marketing", name: "Marketing")]
        XCTAssertNil(config.site(forKey: "<script>", hostSiteKey: "marketing"))
        XCTAssertNil(config.site(forKey: "marketing' OR '1'='1", hostSiteKey: "marketing"))
        XCTAssertEqual(config.dashboard.dateRange(forQuery: "<script>"), config.dashboard.defaultDateRange)
    }
}

// MARK: - Configuration and logging

final class AuthSecurityAdversarialTests_ConfigurationAdversarialTests: XCTestCase {

    private var app: Application!
    private var capture: AuthLogCapture!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        let capture = AuthLogCapture()
        self.capture = capture
        app.logger = Logger(label: "adversarial") { _ in AuthCapturingLogHandler(capture: capture) }
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        capture = nil
    }

    /// Attack: offline brute force of a weak HMAC key from one captured
    /// cookie (whose message, `bot-dashboard:<expiry>`, is fully known). A
    /// one-character secret is accepted without a word. Secure behaviour:
    /// a secret shorter than 32 bytes is refused or at least warned about.
    func testShortSigningSecretIsFlagged() throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration(secret: "x"))
        let warned = capture.lines.contains { $0.hasPrefix("[warning]") && $0.lowercased().contains("secret") }
        XCTAssertTrue(warned, "a 1-character signing secret was accepted silently")
    }

    /// Without a secret, a random per-process key is used and a warning is
    /// logged. The fallback must not be a fixed or guessable value.
    func testMissingSecretFallsBackToARandomKeyAndWarns() throws {
        var config = adversarialConfiguration()
        config.signingSecret = .environment("BOTKIT_ADVERSARIAL_UNSET_\(UUID().uuidString)")
        try BotKit.configureRoutes(for: app, config: config)
        XCTAssertTrue(capture.lines.contains { $0.hasPrefix("[warning]") && $0.contains("signing secret") })

        let logger = Logger(label: "x") { _ in AuthCapturingLogHandler(capture: AuthLogCapture()) }
        let a = BotKitRuntime(configuration: config, client: app.client, logger: logger).signer
        let b = BotKitRuntime(configuration: config, client: app.client, logger: logger).signer
        let expiry = Date().addingTimeInterval(600)
        XCTAssertNotEqual(a.sessionToken(expiresAt: expiry), b.sessionToken(expiresAt: expiry))
        XCTAssertFalse(a.isValidSessionToken(BotSigner(secret: "").sessionToken(expiresAt: expiry)))
    }

    /// Attack: `BOT_DASHBOARD_PASSWORD=" "` (a stray space in a dashboard or
    /// `.env` file) resolves as a configured password, so the dashboard is
    /// mounted behind a one-space password. Secure behaviour: blank values
    /// count as unset.
    func testWhitespaceOnlyCredentialsDoNotMountTheDashboard() async throws {
        var config = adversarialConfiguration()
        config.dashboard.password = .value("   ")
        try BotKit.configureRoutes(for: app, config: config)
        let res = try await app.sendRequest(.GET, "\(dashboardPath)/")
        XCTAssertEqual(res.status, .notFound, "a whitespace-only password mounted the dashboard")
    }

    /// A whitespace-only username must not mount the dashboard either.
    func testWhitespaceOnlyUsernameDoesNotMountTheDashboard() async throws {
        var config = adversarialConfiguration()
        config.dashboard.username = .value(" \t\n")
        try BotKit.configureRoutes(for: app, config: config)
        let res = try await app.sendRequest(.GET, "\(dashboardPath)/")
        XCTAssertEqual(res.status, .notFound)
        XCTAssertTrue(capture.lines.contains { $0.hasPrefix("[warning]") && $0.contains("credentials are not configured") })
    }

    /// A 32-byte secret is not flagged.
    func testLongSigningSecretIsNotFlagged() throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration(secret: String(repeating: "k", count: 32)))
        XCTAssertFalse(capture.lines.contains { $0.contains("shorter than") })
    }

    /// Successful sign-ins leave an audit line at info level, carrying the
    /// hashed client address and not the address.
    func testSuccessfulSignInIsLoggedWithTheHashedAddress() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration())
        let ip = "198.51.100.78"
        _ = try await app.sendRequest(
            .POST, "\(dashboardPath)/login",
            headers: formHeaders(forwardedFor: ip),
            body: formBody(username: ownerUser, password: ownerPassword)
        )
        let line = try XCTUnwrap(capture.lines.first { $0.hasPrefix("[info]") && $0.contains("sign-in succeeded") })
        XCTAssertTrue(line.contains(BotSigner(secret: signingSecret).hashIP(ip)))
        XCTAssertFalse(line.contains(ip))
    }

    /// Nothing sensitive may reach the logs on a failed or successful sign-in:
    /// not the submitted password, not the configured one, not the secret, not
    /// the client IP.
    func testSignInLogsCarryNoSecretsOrAddresses() async throws {
        try BotKit.configureRoutes(for: app, config: adversarialConfiguration(maximumFailures: 50))
        let attempted = "attacker-guess-\(UUID().uuidString)"
        let ip = "198.51.100.77"
        _ = try await app.sendRequest(
            .POST, "\(dashboardPath)/login",
            headers: formHeaders(forwardedFor: ip),
            body: formBody(username: "someone-else", password: attempted)
        )
        _ = try await app.sendRequest(
            .POST, "\(dashboardPath)/login",
            headers: formHeaders(forwardedFor: ip),
            body: formBody(username: ownerUser, password: ownerPassword)
        )
        let logs = capture.joined
        XCTAssertTrue(logs.contains("Rejected AI bot dashboard sign-in"), "expected the rejection to be logged")
        for secret in [attempted, "someone-else", ownerPassword, signingSecret, ip] {
            XCTAssertFalse(logs.contains(secret), "log output contains \(secret)")
        }
    }
}
