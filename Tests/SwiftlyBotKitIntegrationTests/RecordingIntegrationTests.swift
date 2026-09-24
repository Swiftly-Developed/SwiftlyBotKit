import Foundation
import XCTest
import XCTVapor
import Fluent
import SQLKit
@testable import SwiftlyBotKit

/// Request -> middleware -> detached write -> row, against a real PostgreSQL.
final class RecordingIntegrationTests: PostgresIntegrationTestCase {

    /// Installs BotKit, migrates, and adds a catch-all page route.
    private func install(_ config: BotKitConfiguration? = nil) async throws {
        try BotKit.install(on: app, config: config ?? baseConfiguration())
        app.get("**") { _ in "page" }
        try await app.autoMigrate()
    }

    private func get(_ path: String, headers: HTTPHeaders) async throws -> HTTPStatus {
        var status = HTTPStatus.internalServerError
        try await app.test(.GET, path, headers: headers) { res async in status = res.status }
        return status
    }

    private struct Row {
        let siteKey: String
        let path: String
        let method: String
        let statusCode: Int
        let agentName: String?
        let agentOperator: String?
        let purpose: String?
        let verification: String
        let respectsRobotsTxt: Bool?
        let referrerPlatform: String?
        let ipHash: String
        let userAgent: String?
        let createdAt: Date?
    }

    private func rows(on id: DatabaseID? = nil) async throws -> [Row] {
        try await sql(id).raw("""
            SELECT site_key, path, method, status_code, agent_name, agent_operator,
                   purpose::text AS purpose, verification::text AS verification,
                   respects_robots_txt, referrer_platform, ip_hash, user_agent, created_at
            FROM ai_bot_visits ORDER BY created_at
            """).all().map { r in
            Row(
                siteKey: try r.decode(column: "site_key", as: String.self),
                path: try r.decode(column: "path", as: String.self),
                method: try r.decode(column: "method", as: String.self),
                statusCode: try r.decode(column: "status_code", as: Int.self),
                agentName: try r.decode(column: "agent_name", as: String?.self),
                agentOperator: try r.decode(column: "agent_operator", as: String?.self),
                purpose: try r.decode(column: "purpose", as: String?.self),
                verification: try r.decode(column: "verification", as: String.self),
                respectsRobotsTxt: try r.decode(column: "respects_robots_txt", as: Bool?.self),
                referrerPlatform: try r.decode(column: "referrer_platform", as: String?.self),
                ipHash: try r.decode(column: "ip_hash", as: String.self),
                userAgent: try r.decode(column: "user_agent", as: String?.self),
                createdAt: try r.decode(column: "created_at", as: Date?.self)
            )
        }
    }

    // MARK: - The happy path, end to end

    func testAgentRequestBecomesARow() async throws {
        try await install()
        let before = Date()
        let status = try await get("/insights/article/?utm_source=x&q=1", headers: [
            "User-Agent": gptbotUA,
            "X-Forwarded-For": "203.0.113.9",
        ])
        XCTAssertEqual(status, .ok)
        try await waitForRows(1)

        let first = try await rows().first
        let row = try XCTUnwrap(first)
        XCTAssertEqual(row.siteKey, "default")
        XCTAssertEqual(row.path, "/insights/article/", "query string must be dropped")
        XCTAssertEqual(row.method, "GET")
        XCTAssertEqual(row.statusCode, 200)
        XCTAssertEqual(row.agentName, "GPTBot")
        XCTAssertEqual(row.agentOperator, "OpenAI")
        XCTAssertEqual(row.purpose, "training")
        XCTAssertEqual(row.verification, "unverified", "verification is off in these tests")
        XCTAssertEqual(row.respectsRobotsTxt, true)
        XCTAssertNil(row.referrerPlatform)
        XCTAssertNotEqual(row.ipHash, "unknown")
        XCTAssertFalse(row.ipHash.contains("203.0.113.9"), "raw IP stored")
        XCTAssertEqual(row.userAgent, gptbotUA)
        let createdAt = try XCTUnwrap(row.createdAt)
        XCTAssertGreaterThanOrEqual(createdAt.timeIntervalSince(before), -1)
        XCTAssertLessThan(Date().timeIntervalSince(createdAt), 30)
    }

    /// The docs promise "a crawler hammering URLs that 404 is worth seeing".
    /// An unmatched route is thrown as an error, not returned as a response,
    /// so the middleware never reaches its recording code.
    func testNotFoundIsRecordedWithItsStatus() async throws {
        try BotKit.install(on: app, config: baseConfiguration())
        try await app.autoMigrate()
        let awaited1 = try await get("/does-not-exist", headers: ["User-Agent": claudeUserUA])
        XCTAssertEqual(awaited1, .notFound)
        try await waitForRows(1, timeout: 3)
        let first = try await rows().first
        let row = try XCTUnwrap(first)
        XCTAssertEqual(row.statusCode, 404)
        XCTAssertEqual(row.purpose, "userTriggered")
    }

    /// A handler that throws. The error is turned into a response by
    /// `ErrorMiddleware`, which runs outside BotKit's middleware, so the
    /// tracking middleware sees a thrown error rather than a response.
    func testThrownErrorsAreRecordedWithTheirStatus() async throws {
        try BotKit.install(on: app, config: baseConfiguration())
        app.get("forbidden") { _ -> String in throw Abort(.forbidden) }
        app.get("broken") { _ -> String in throw Abort(.internalServerError) }
        try await app.autoMigrate()
        let forbidden = try await get("/forbidden", headers: ["User-Agent": gptbotUA])
        let broken = try await get("/broken", headers: ["User-Agent": gptbotUA])
        XCTAssertEqual(forbidden, .forbidden)
        XCTAssertEqual(broken, .internalServerError)
        try await waitForRows(2, timeout: 3)
        let codes = Set(try await rows().map(\.statusCode))
        XCTAssertEqual(codes, [403, 500])
    }

    func testReferralBecomesARow() async throws {
        try await install()
        _ = try await get("/pricing/", headers: [
            "User-Agent": "Mozilla/5.0 (Macintosh) Safari/605.1.15",
            "Referer": "https://chatgpt.com/c/abc",
        ])
        try await waitForRows(1)
        let first = try await rows().first
        let row = try XCTUnwrap(first)
        XCTAssertNil(row.agentName)
        XCTAssertNil(row.purpose)
        XCTAssertEqual(row.referrerPlatform, "ChatGPT")
        XCTAssertEqual(row.verification, "notApplicable")
    }

    func testOrdinaryTrafficWritesNothing() async throws {
        try await install()
        _ = try await get("/", headers: ["User-Agent": "Mozilla/5.0 Safari"])
        _ = try await get("/logo.png", headers: ["User-Agent": gptbotUA])
        _ = try await get("/admin/ai-bots/", headers: ["User-Agent": gptbotUA])
        try await Task.sleep(nanoseconds: 500_000_000)
        let awaited2 = try await count()
        XCTAssertEqual(awaited2, 0)
    }

    /// A burst of concurrent crawler requests: every one lands, none blocks.
    func testBurstOfRequestsAllLand() async throws {
        try await install()
        for index in 0..<200 {
            _ = try await get("/burst/\(index)", headers: ["User-Agent": gptbotUA])
        }
        try await waitForRows(200, timeout: 30)
    }

    // MARK: - Injection

    static let injections = [
        "'; DROP TABLE ai_bot_visits; --",
        "' OR '1'='1",
        "\\'; DROP TABLE ai_bot_visits; --",
        "$1 $2 $$ $tag$ ; SELECT pg_sleep(5); $tag$",
        "'); DELETE FROM ai_bot_visits; --",
        "<script>alert('xss')</script>",
        "%27%3B%20DROP%20TABLE%20ai_bot_visits%3B--",
        "\u{202E}gnp.exe",
    ]

    func testInjectionThroughPathUserAgentRefererAndSiteKey() async throws {
        var config = baseConfiguration()
        // The site key comes from the Host header here, which is attacker
        // controlled on any app that routes by host.
        config.siteKey = { $0.headers.first(name: .host) ?? "none" }
        try await install(config)

        var sent = 0
        for payload in Self.injections {
            let encoded = payload.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "x"
            _ = try await get("/p/\(encoded)", headers: ["User-Agent": gptbotUA + " " + payload, "Host": payload])
            _ = try await get("/r", headers: ["User-Agent": "Safari", "Referer": "https://claude.ai/\(encoded)"])
            sent += 2
        }
        try await waitForRows(sent, timeout: 20)

        let stored = try await rows()
        XCTAssertEqual(stored.count, sent, "table altered or rows lost")
        for payload in Self.injections {
            XCTAssertTrue(stored.contains { $0.siteKey == payload }, "site key not stored verbatim: \(payload)")
            XCTAssertTrue(stored.contains { $0.userAgent == gptbotUA + " " + payload }, "UA not stored verbatim: \(payload)")
        }
        // Dashboard over the hostile rows, with hostile query parameters.
        let cookie = try await signIn()
        for payload in Self.injections + ["all", "", "24h", "7d%27"] {
            let q = payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let (status, body) = try await dashboard("?site=\(q)&range=\(q)", cookie: cookie)
            XCTAssertEqual(status, .ok, "?site=/?range= \(payload)")
            XCTAssertFalse(body.contains("<script>alert"), "unescaped markup in dashboard for \(payload)")
        }
        let awaited3 = try await count()
        XCTAssertEqual(awaited3, sent, "dashboard queries altered the table")
    }

    // MARK: - Awkward values

    /// Path, user agent and site key are all cut at 512 characters.
    func testMaximumLengthValues() async throws {
        var config = baseConfiguration()
        let longSite = String(repeating: "s", count: 10_000)
        config.siteKey = { _ in longSite }
        try await install(config)
        let longPath = "/" + String(repeating: "a", count: 4_000)
        // 600 emoji: 512 characters, 2048 bytes. The column is text, so fine.
        let longUA = gptbotUA + String(repeating: "\u{1F600}", count: 600)
        _ = try await get(longPath, headers: ["User-Agent": longUA])
        try await waitForRows(1)
        let first = try await rows().first
        let row = try XCTUnwrap(first)
        XCTAssertEqual(row.path.count, 512)
        XCTAssertEqual(row.userAgent?.count, 512)
        XCTAssertEqual(row.siteKey.count, 512)
    }

    /// PostgreSQL `text` cannot hold U+0000. A NUL in the user agent or site
    /// key makes the insert fail, and the recorder drops the row with only a
    /// warning. Desired: the visit is still recorded (NUL stripped).
    func testNULBytesDoNotLoseTheVisit() async throws {
        var config = baseConfiguration()
        config.siteKey = { $0.headers.first(name: "X-Site") ?? "default" }
        try await install(config)
        _ = try await get("/nul-ua", headers: ["User-Agent": gptbotUA + "\u{0}x"])
        _ = try await get("/nul-site", headers: ["User-Agent": gptbotUA, "X-Site": "a\u{0}b"])
        _ = try await get("/nul%00path", headers: ["User-Agent": gptbotUA])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let recorded = try await rows().map(\.path)
        print("BOTKIT-NUL recorded paths: \(recorded)")
        XCTAssertTrue(recorded.contains("/nul-ua"), "a NUL in the user agent lost the visit")
        XCTAssertTrue(recorded.contains("/nul-site"), "a NUL in the site key lost the visit")
        XCTAssertEqual(recorded.count, 3)
    }

    /// Rows with every nullable column NULL, as another writer or an older
    /// version might leave them.
    func testRowsWithNullsRenderAndCount() async throws {
        try await install()
        let db = sql()
        try await db.raw("""
            INSERT INTO ai_bot_visits (id, site_key, path, method, status_code, verification, ip_hash, created_at)
            VALUES (gen_random_uuid(), 'default', '/null-everything', 'GET', 200, 'notApplicable', 'h', now())
            """).run()
        // A bot row whose purpose, operator and robots flag are unknown.
        try await db.raw("""
            INSERT INTO ai_bot_visits (id, site_key, path, method, status_code, agent_name, verification, ip_hash, created_at)
            VALUES (gen_random_uuid(), 'default', '/no-purpose', 'GET', 200, 'MysteryBot', 'unverified', 'h', now())
            """).run()
        // created_at NULL: the model allows it (no NOT NULL on the column).
        try await db.raw("""
            INSERT INTO ai_bot_visits (id, site_key, path, method, status_code, agent_name, purpose, verification, ip_hash)
            VALUES (gen_random_uuid(), 'default', '/no-time', 'GET', 200, 'GPTBot', 'training', 'verified', 'h')
            """).run()

        let data = try await BotDashboardQueries(database: db, timeZone: TimeZone(identifier: "UTC")!)
            .load(range: .day, siteKey: nil)
        XCTAssertEqual(data.totals.botVisits, 1, "the NULL-created_at row must not count, the NULL-purpose one must")
        let mystery = try XCTUnwrap(data.topAgents.first { $0.name == "MysteryBot" })
        XCTAssertEqual(mystery.operatorName, "Unknown")
        XCTAssertNil(mystery.purpose)
        XCTAssertNil(mystery.respectsRobotsTxt)
        // The chart and the tiles should agree on how many bot visits there
        // were. A NULL purpose is dropped from the series by the decoder.
        let charted = data.series.reduce(0) { $0 + $1.total }
        XCTAssertEqual(charted, data.totals.botVisits, "tiles and chart disagree when purpose is NULL")

        let cookie = try await signIn()
        let (status, body) = try await dashboard("?range=24h&site=all", cookie: cookie)
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(body.contains("MysteryBot"))
    }

    // MARK: - Non-default database

    /// `BotKitConfiguration.database` must route the migration, the writes and
    /// the dashboard reads to that database, never the default one.
    func testNonDefaultDatabaseID() async throws {
        let botsID = DatabaseID(string: "bots")
        let botsSchema = try await registerSecondDatabase(as: botsID)

        // A decoy ai_bot_visits in the default database, with rows of its own.
        try await CreateAIBotVisit().prepare(on: app.db(.psql))
        try await insertBotRows(at: Array(repeating: Date(), count: 7), path: "/decoy", on: .psql)

        var config = baseConfiguration()
        config.database = botsID
        try BotKit.install(on: app, config: config)
        app.get("**") { _ in "page" }
        try await app.autoMigrate()

        let migrationsInBots = try await sql(botsID).raw("SELECT COUNT(*) AS n FROM _fluent_migrations").first()?
            .decode(column: "n", as: Int.self)
        XCTAssertEqual(migrationsInBots, 1)
        let tableInBots = try await sql().raw("""
            SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = \(bind: botsSchema) AND table_name = 'ai_bot_visits'
            """).first()?.decode(column: "n", as: Int.self)
        XCTAssertEqual(tableInBots, 1)

        _ = try await get("/real", headers: ["User-Agent": gptbotUA])
        try await waitForRows(1, on: botsID)
        let awaited4 = try await count(on: .psql)
        XCTAssertEqual(awaited4, 7, "a row landed in the default database")

        let cookie = try await signIn()
        let (status, body) = try await dashboard("?range=24h&site=all", cookie: cookie)
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(body.contains("/real"), "dashboard is not reading the configured database")
        XCTAssertFalse(body.contains("/decoy"), "dashboard read the default database")
    }
}
