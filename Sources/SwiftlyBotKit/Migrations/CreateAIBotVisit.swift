import Fluent
import FluentSQL

/// The table, its two enum types and its indexes.
///
/// Both directions run in one transaction. PostgreSQL's DDL is transactional,
/// so a failure halfway (say, an app already owns a `bot_verification` type)
/// rolls back the enum types created before it, and the migration can simply
/// be retried once the blocker is gone. Names and indexes are frozen: apps
/// have already run this migration, so a change needs a new migration.
struct CreateAIBotVisit: AsyncMigration {
    /// Pinned rather than Fluent's default, which is the type name *with its
    /// module*: the module was renamed once (`BotKit` to `SwiftlyBotKit`), and
    /// an app that migrated under the old name would otherwise see a new,
    /// unapplied migration after upgrading. Never change this string.
    var name: String { "SwiftlyBotKit.CreateAIBotVisit" }

    func prepare(on database: Database) async throws {
        // An app that ran this migration under an earlier name (the module's
        // old `BotKit.CreateAIBotVisit`) already has the table. Creating it
        // again would fail on the first enum type and stop the app at boot,
        // so an existing table means there is nothing to do.
        if let sql = database as? SQLDatabase,
           let exists = try await sql.raw("SELECT to_regclass('ai_bot_visits') IS NOT NULL AS present")
               .first()?.decode(column: "present", as: Bool.self),
           exists {
            database.logger.info("ai_bot_visits already exists; recording CreateAIBotVisit as applied without changes.")
            return
        }
        try await database.transaction { database in
            try await prepareSchema(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await database.transaction { database in
            try await database.schema("ai_bot_visits").delete()
            try await database.enum("bot_verification").delete()
            try await database.enum("ai_agent_purpose").delete()
        }
    }

    private func prepareSchema(on database: Database) async throws {
        let purpose = try await database.enum("ai_agent_purpose")
            .case("training")
            .case("aiSearch")
            .case("userTriggered")
            .case("agent")
            .case("scraper")
            .create()

        let verification = try await database.enum("bot_verification")
            .case("verified")
            .case("unverified")
            .case("spoofed")
            .case("notApplicable")
            .create()

        try await database.schema("ai_bot_visits")
            .id()
            .field("site_key", .string, .required)
            .field("path", .string, .required)
            .field("method", .string, .required)
            .field("status_code", .int, .required)
            .field("agent_name", .string)
            .field("agent_operator", .string)
            .field("purpose", purpose)
            .field("verification", verification, .required)
            .field("respects_robots_txt", .bool)
            .field("referrer_platform", .string)
            .field("ip_hash", .string, .required)
            .field("user_agent", .string)
            .field("created_at", .datetime)
            .create()

        guard let sql = database as? SQLDatabase else { return }
        // Every dashboard query is "this site, this date window", then groups.
        // `created_at` trails the site key so the range scan happens inside the
        // site partition; the all-sites view still uses it as a plain date index.
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_ai_bot_visits_site_time ON ai_bot_visits (site_key, created_at DESC)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_ai_bot_visits_time ON ai_bot_visits (created_at DESC)").run()
        // Top-agents and purpose breakdowns within a window.
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_ai_bot_visits_agent ON ai_bot_visits (agent_name, created_at DESC)").run()
    }
}
