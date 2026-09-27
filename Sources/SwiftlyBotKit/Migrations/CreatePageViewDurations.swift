import Fluent
import FluentSQL

/// The time on page counters: one row per site, day, page and duration band.
///
/// Registered with the page view counters
/// (`BotKit.configure(for:database:pageViews:)`), and written only when
/// ``BotKitConfiguration/PageViews/TimeOnPage`` is on. `band` is a
/// `TimeOnPageBand` raw value, `readings` how many readings fell in it and
/// `seconds` their sum, capped at 30 minutes each, so the average is
/// `seconds / readings`. Like the other page view tables there is nowhere to
/// put anything about the reader. Names are frozen once released.
struct CreatePageViewDurations: AsyncMigration {
    /// Pinned. Never change this string.
    var name: String { "SwiftlyBotKit.CreatePageViewDurations" }

    func prepare(on database: Database) async throws {
        try await database.transaction { database in
            let sql = try PageViewMigrationSQL.sql(database)
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS page_view_durations (
                    site_key text NOT NULL,
                    day date NOT NULL,
                    path text NOT NULL,
                    band smallint NOT NULL,
                    readings bigint NOT NULL,
                    seconds bigint NOT NULL,
                    PRIMARY KEY (site_key, day, path, band)
                )
                """).run()
            // The all-sites view reads by day alone.
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_page_view_durations_day ON page_view_durations (day)").run()
        }
    }

    func revert(on database: Database) async throws {
        try await PageViewMigrationSQL.sql(database).raw("DROP TABLE IF EXISTS page_view_durations").run()
    }
}
