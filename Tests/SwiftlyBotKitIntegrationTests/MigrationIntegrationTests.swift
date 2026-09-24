import Foundation
import XCTest
import XCTVapor
import Fluent
import SQLKit
@testable import SwiftlyBotKit

/// `CreateAIBotVisit` against a real PostgreSQL, in databases that are not
/// empty and not pristine.
final class MigrationIntegrationTests: PostgresIntegrationTestCase {

    private func tableExists(_ name: String, in schema: String) async throws -> Bool {
        let row = try await sql().raw("""
            SELECT COUNT(*) AS n FROM information_schema.tables
            WHERE table_schema = \(bind: schema) AND table_name = \(bind: name)
            """).first()
        return try (row?.decode(column: "n", as: Int.self) ?? 0) > 0
    }

    private func enumLabels(_ type: String, in schema: String) async throws -> [String] {
        try await sql().raw("""
            SELECT e.enumlabel AS label
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            JOIN pg_enum e ON e.enumtypid = t.oid
            WHERE n.nspname = \(bind: schema) AND t.typname = \(bind: type)
            ORDER BY e.enumsortorder
            """).all().map { try $0.decode(column: "label", as: String.self) }
    }

    private func indexNames(in schema: String) async throws -> Set<String> {
        Set(try await sql().raw("""
            SELECT indexname FROM pg_indexes
            WHERE schemaname = \(bind: schema) AND tablename = 'ai_bot_visits'
            """).all().map { try $0.decode(column: "indexname", as: String.self) })
    }

    func testCreatesTableEnumsAndIndexes() async throws {
        BotKit.configure(for: app)
        try await app.autoMigrate()

        let awaited1 = try await tableExists("ai_bot_visits", in: schema)
        XCTAssertTrue(awaited1)
        let awaited2 = try await enumLabels("ai_agent_purpose", in: schema)
        XCTAssertEqual(awaited2,
                       ["training", "aiSearch", "userTriggered", "agent", "scraper"])
        let awaited3 = try await enumLabels("ai_agent_purpose", in: schema)
        XCTAssertEqual(Set(awaited3),
                       Set(AIAgentPurpose.allCases.map(\.rawValue)),
                       "Swift enum and PostgreSQL enum have drifted")
        let awaited4 = try await enumLabels("bot_verification", in: schema)
        XCTAssertEqual(Set(awaited4),
                       Set(BotVerification.allCases.map(\.rawValue)))
        let indexes = try await indexNames(in: schema)
        for expected in ["idx_ai_bot_visits_site_time", "idx_ai_bot_visits_time", "idx_ai_bot_visits_agent"] {
            XCTAssertTrue(indexes.contains(expected), "missing \(expected), have \(indexes)")
        }

        // created_at must be timestamptz, or AT TIME ZONE means the opposite
        // conversion and every bucket shifts by the offset.
        let type = try await sql().raw("""
            SELECT data_type FROM information_schema.columns
            WHERE table_schema = \(bind: schema) AND table_name = 'ai_bot_visits' AND column_name = 'created_at'
            """).first()?.decode(column: "data_type", as: String.self)
        XCTAssertEqual(type, "timestamp with time zone")
    }

    /// The package's docs promise the table can sit beside the app's own.
    func testMigratesIntoADatabaseWithUnrelatedTablesAndTypes() async throws {
        let db = sql()
        try await db.raw("CREATE TABLE users (id serial PRIMARY KEY, email text NOT NULL)").run()
        try await db.raw("INSERT INTO users (email) VALUES ('a@example.com')").run()
        try await db.raw("CREATE TYPE purpose AS ENUM ('x', 'y')").run()
        try await db.raw("CREATE TYPE verification AS ENUM ('ok')").run()
        try await db.raw("CREATE TABLE visits (id serial PRIMARY KEY, created_at timestamptz)").run()
        // Same index name pattern, different table: CREATE INDEX IF NOT EXISTS
        // is keyed on the index name alone, so a clash would be silently skipped.
        try await db.raw("CREATE INDEX idx_visits_time ON visits (created_at)").run()

        BotKit.configure(for: app)
        try await app.autoMigrate()

        let awaited5 = try await tableExists("ai_bot_visits", in: schema)
        XCTAssertTrue(awaited5)
        let awaited6 = try await db.raw("SELECT COUNT(*) AS n FROM users").first()?.decode(column: "n", as: Int.self)
        XCTAssertEqual(awaited6, 1)
        let awaited7 = try await enumLabels("purpose", in: schema)
        XCTAssertEqual(awaited7, ["x", "y"])
    }

    /// An app that already has its own `ai_agent_purpose` type (another
    /// analytics package, a previous hand-rolled version). Reported: the
    /// migration fails with "type already exists" and creates nothing.
    func testPreexistingTypeNamedAIAgentPurposeFailsCleanly() async throws {
        try await sql().raw("CREATE TYPE ai_agent_purpose AS ENUM ('mine')").run()
        BotKit.configure(for: app)

        do {
            try await app.autoMigrate()
            XCTFail("Migration succeeded over a foreign ai_agent_purpose type")
        } catch {
            let text = String(reflecting: error)
            XCTAssertTrue(text.contains("already exists") || text.contains("42710"), "unexpected error: \(text)")
        }
        let awaited8 = try await tableExists("ai_bot_visits", in: schema)
        XCTAssertFalse(awaited8)
        let awaited9 = try await enumLabels("ai_agent_purpose", in: schema)
        XCTAssertEqual(awaited9, ["mine"], "foreign type was modified")
        let awaited10 = try await enumLabels("bot_verification", in: schema)
        XCTAssertEqual(awaited10, [])
    }

    /// A failure after the first statement. The migration runs in one
    /// transaction, so the `ai_agent_purpose` type it created first is rolled
    /// back, and removing the blocker and retrying succeeds.
    func testMigrationFailingHalfwayCanBeRetried() async throws {
        // Blocks the second CREATE TYPE, after ai_agent_purpose was created.
        try await sql().raw("CREATE TYPE bot_verification AS ENUM ('mine')").run()
        BotKit.configure(for: app)
        do {
            try await app.autoMigrate()
            XCTFail("Migration succeeded over a foreign bot_verification type")
        } catch {}

        let leftover = try await enumLabels("ai_agent_purpose", in: schema)
        XCTAssertEqual(leftover, [], "the failed attempt left ai_agent_purpose behind")
        // Remove the blocker, as an operator would, and retry.
        try await sql().raw("DROP TYPE bot_verification").run()
        do {
            try await app.autoMigrate()
        } catch {
            XCTFail("""
                Retry after removing the blocker failed: \(String(reflecting: error)).
                ai_agent_purpose left behind by the failed attempt: \(leftover)
                """)
        }
        let awaited11 = try await tableExists("ai_bot_visits", in: schema)
        XCTAssertTrue(awaited11)
    }

    func testAutoMigrateTwiceIsANoOp() async throws {
        BotKit.configure(for: app)
        try await app.autoMigrate()
        try await insertBotRows(at: [Date()])
        try await app.autoMigrate()
        let awaited12 = try await count()
        XCTAssertEqual(awaited12, 1, "second autoMigrate touched the data")
        let logged = try await sql().raw("SELECT COUNT(*) AS n FROM _fluent_migrations WHERE name LIKE '%CreateAIBotVisit%'")
            .first()?.decode(column: "n", as: Int.self)
        XCTAssertEqual(logged, 1)
    }

    /// Registering the migration twice (calling both `configure` and
    /// `install`, or `configure` twice). The install guard makes the second
    /// registration a logged no-op, so `autoMigrate` runs the migration once.
    func testMigrationRegisteredTwiceRunsOnce() async throws {
        BotKit.configure(for: app)
        BotKit.configure(for: app)
        try await app.autoMigrate()
        let logged = try await sql().raw("SELECT COUNT(*) AS n FROM _fluent_migrations WHERE name LIKE '%CreateAIBotVisit%'")
            .first()?.decode(column: "n", as: Int.self)
        XCTAssertEqual(logged, 1)
    }

    func testRevertThenMigrateAgain() async throws {
        BotKit.configure(for: app)
        try await app.autoMigrate()
        try await insertBotRows(at: [Date(), Date()])
        let awaited13 = try await count()
        XCTAssertEqual(awaited13, 2)

        try await app.autoRevert()
        let awaited14 = try await tableExists("ai_bot_visits", in: schema)
        XCTAssertFalse(awaited14)
        let awaited15 = try await enumLabels("ai_agent_purpose", in: schema)
        XCTAssertEqual(awaited15, [])
        let awaited16 = try await enumLabels("bot_verification", in: schema)
        XCTAssertEqual(awaited16, [])

        try await app.autoMigrate()
        let awaited17 = try await tableExists("ai_bot_visits", in: schema)
        XCTAssertTrue(awaited17)
        let awaited18 = try await count()
        XCTAssertEqual(awaited18, 0)
        let awaited19 = try await indexNames(in: schema).count
        XCTAssertEqual(awaited19, 4, "primary key plus three indexes")

        // And it still works end to end.
        try await insertBotRows(at: [Date()])
        let data = try await BotDashboardQueries(database: sql(), timeZone: TimeZone(identifier: "UTC")!)
            .load(range: .day, siteKey: nil)
        XCTAssertEqual(data.totals.botVisits, 1)
    }

    /// An app table that uses BotKit's enum type (a view or report the owner
    /// built). Revert then fails on the dependency; reported.
    func testRevertWithADependentObject() async throws {
        BotKit.configure(for: app)
        try await app.autoMigrate()
        try await sql().raw("CREATE VIEW my_training_hits AS SELECT * FROM ai_bot_visits WHERE purpose = 'training'").run()
        do {
            try await app.autoRevert()
            XCTFail("Revert dropped the table under a dependent view")
        } catch {
            XCTAssertTrue(String(reflecting: error).contains("depend"), "\(String(reflecting: error))")
        }
    }
}
