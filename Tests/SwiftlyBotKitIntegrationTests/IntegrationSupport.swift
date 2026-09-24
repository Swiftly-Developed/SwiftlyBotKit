import Foundation
import XCTest
import XCTVapor
import Fluent
import FluentPostgresDriver
import SQLKit
@testable import SwiftlyBotKit

/// Shared scaffolding for the PostgreSQL integration tests.
///
/// These tests only run when `BOTKIT_TEST_DATABASE_URL` points at a PostgreSQL
/// server, for example:
///
///     BOTKIT_TEST_DATABASE_URL=postgres://botkit:botkit@localhost:55432/botkit?sslmode=disable \
///         swift test --filter SwiftlyBotKitIntegrationTests
///
/// Without it every test is skipped, so a plain `swift test` needs no database.
///
/// Each test gets its own PostgreSQL schema (`search_path` is pinned to it), so
/// tests never see each other's tables or enum types and nothing leaks into
/// `public`. The schema is dropped with `CASCADE` in `tearDown`.
class PostgresIntegrationTestCase: XCTestCase {

    static let databaseURLVariable = "BOTKIT_TEST_DATABASE_URL"

    private(set) var app: Application!
    /// Every schema created for this test, dropped in `tearDown`.
    private var schemas: [String] = []

    /// The schema the default `.psql` database is pinned to.
    var schema: String { schemas[0] }

    /// Credentials for the dashboard in every test that signs in.
    let username = "owner"
    let password = "correct horse battery staple"

    static func databaseURL() throws -> String {
        guard let url = ProcessInfo.processInfo.environment[databaseURLVariable], !url.isEmpty else {
            throw XCTSkip("Set \(databaseURLVariable) to run the PostgreSQL integration tests.")
        }
        return url
    }

    override func setUp() async throws {
        try await super.setUp()
        let url = try Self.databaseURL()
        app = try await Application.make(.testing)
        app.logger.logLevel = .error
        let schema = Self.newSchemaName()
        try await registerDatabase(url: url, schema: schema, as: .psql, isDefault: true)
        try await sql().raw("CREATE SCHEMA \(ident: schema)").run()
        schemas.append(schema)
    }

    override func tearDown() async throws {
        if let app {
            // Give any detached recorder write a moment to land before the
            // pool goes away, so shutdown does not log spurious failures.
            try? await Task.sleep(nanoseconds: 50_000_000)
            for schema in schemas {
                try? await (app.db(.psql) as! any SQLDatabase)
                    .raw("DROP SCHEMA IF EXISTS \(ident: schema) CASCADE").run()
            }
            try await app.asyncShutdown()
        }
        app = nil
        schemas = []
        try await super.tearDown()
    }

    static func newSchemaName() -> String {
        "botkit_it_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    /// Registers a PostgreSQL database whose connections only see `schema`.
    func registerDatabase(url: String, schema: String, as id: DatabaseID, isDefault: Bool) async throws {
        var configuration = try SQLPostgresConfiguration(url: url)
        configuration.searchPath = [schema]
        app.databases.use(
            .postgres(configuration: configuration, maxConnectionsPerEventLoop: 2, sqlLogLevel: .trace),
            as: id,
            isDefault: isDefault
        )
    }

    /// Registers a second database on another fresh schema, created here.
    func registerSecondDatabase(as id: DatabaseID) async throws -> String {
        let schema = Self.newSchemaName()
        try await sql().raw("CREATE SCHEMA \(ident: schema)").run()
        schemas.append(schema)
        try await registerDatabase(url: try Self.databaseURL(), schema: schema, as: id, isDefault: false)
        return schema
    }

    func sql(_ id: DatabaseID? = nil) -> any SQLDatabase {
        app.db(id) as! any SQLDatabase
    }

    // MARK: - Configuration

    /// A configuration that never touches the network: IP verification off,
    /// fixed signing secret, dashboard credentials set.
    func baseConfiguration() -> BotKitConfiguration {
        var config = BotKitConfiguration(signingSecret: "integration-test-secret")
        config.verification.isEnabled = false
        config.dashboard.username = .value(username)
        config.dashboard.password = .value(password)
        config.dashboard.secureCookies = .never
        return config
    }

    // MARK: - Rows

    func count(_ whereClause: String = "TRUE", on id: DatabaseID? = nil) async throws -> Int {
        let row = try await sql(id).raw("SELECT COUNT(*) AS n FROM ai_bot_visits WHERE \(unsafeRaw: whereClause)").first()
        return try row?.decode(column: "n", as: Int.self) ?? 0
    }

    /// Waits for the recorder's detached write.
    @discardableResult
    func waitForRows(
        _ expected: Int,
        where whereClause: String = "TRUE",
        on id: DatabaseID? = nil,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = 0
        while Date() < deadline {
            seen = try await count(whereClause, on: id)
            if seen >= expected { return seen }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Expected \(expected) row(s) where \(whereClause), saw \(seen) after \(timeout)s", file: file, line: line)
        return seen
    }

    /// Inserts one bot row per instant, bypassing Fluent so `created_at` is
    /// exactly what the test says (the model's `@Timestamp` would overwrite it).
    func insertBotRows(
        at instants: [Date],
        siteKey: String = "default",
        path: String = "/",
        agent: String = "GPTBot",
        operatorName: String? = "OpenAI",
        purpose: AIAgentPurpose? = .training,
        verification: BotVerification = .verified,
        on id: DatabaseID? = nil
    ) async throws {
        let db = sql(id)
        var start = 0
        while start < instants.count {
            let chunk = Array(instants[start..<min(start + 5_000, instants.count)])
            try await db.raw("""
                INSERT INTO ai_bot_visits
                    (id, site_key, path, method, status_code, agent_name, agent_operator,
                     purpose, verification, respects_robots_txt, ip_hash, user_agent, created_at)
                SELECT gen_random_uuid(), \(bind: siteKey), \(bind: path), 'GET', 200, \(bind: agent),
                       \(bind: operatorName), \(bind: purpose?.rawValue)::ai_agent_purpose,
                       \(bind: verification.rawValue)::bot_verification, TRUE, 'hash', 'test', t
                FROM unnest(\(bind: chunk)::timestamptz[]) AS t
                """).run()
            start += 5_000
        }
    }

    // MARK: - Dashboard

    /// Signs in and returns the `Cookie` header value.
    func signIn(path: String = "/admin/ai-bots") async throws -> String {
        var cookie: String?
        try await app.test(.POST, "\(path)/login", beforeRequest: { req in
            try req.content.encode(["username": username, "password": password], as: .urlEncodedForm)
        }) { res async in
            XCTAssertEqual(res.status, .seeOther)
            if let value = res.headers.setCookie?["botkit_dashboard"]?.string {
                cookie = "botkit_dashboard=\(value)"
            }
        }
        return try XCTUnwrap(cookie, "Sign-in did not set a session cookie")
    }

    func dashboard(_ query: String = "", cookie: String, path: String = "/admin/ai-bots") async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.test(.GET, "\(path)/\(query)", headers: ["Cookie": cookie]) { res async in
            result = (res.status, res.body.string)
        }
        return result
    }
}

let gptbotUA = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)"
let claudeUserUA = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-User/1.0; +Claude-User@anthropic.com)"
