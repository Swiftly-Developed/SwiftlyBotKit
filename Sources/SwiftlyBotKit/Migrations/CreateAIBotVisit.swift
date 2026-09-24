import Fluent
import FluentSQL

struct CreateAIBotVisit: AsyncMigration {
    func prepare(on database: Database) async throws {
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

    func revert(on database: Database) async throws {
        try await database.schema("ai_bot_visits").delete()
        try await database.enum("bot_verification").delete()
        try await database.enum("ai_agent_purpose").delete()
    }
}
