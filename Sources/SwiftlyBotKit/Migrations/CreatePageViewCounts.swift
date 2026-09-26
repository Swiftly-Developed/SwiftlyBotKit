import Fluent
import FluentSQL

/// The page view counters: one row per site, path and quarter-hour.
///
/// Registered only when page views are enabled
/// (`BotKit.configure(for:database:pageViews:)`), so an app that never counts
/// page views never gets the table. The columns are the whole of what is
/// stored about a page view; there is deliberately nowhere to put anything
/// about the visitor.
///
/// Plain SQL rather than Fluent's schema builder, which cannot declare a
/// composite primary key. The key doubles as the index every dashboard query
/// uses ("this site, this window"), and it is what the flush's
/// `ON CONFLICT` upsert targets. Names are frozen once released.
struct CreatePageViewCounts: AsyncMigration {
    /// Pinned, like ``CreateAIBotVisit/name``, so a module rename can never
    /// make it run twice. Never change this string.
    var name: String { "SwiftlyBotKit.CreatePageViewCounts" }

    func prepare(on database: Database) async throws {
        try await database.transaction { database in
            let sql = try Self.sql(database)
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS page_view_counts (
                    site_key text NOT NULL,
                    bucket_start timestamptz NOT NULL,
                    path text NOT NULL,
                    views bigint NOT NULL,
                    PRIMARY KEY (site_key, bucket_start, path)
                )
                """).run()
            // The all-sites view scans by time alone.
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_page_view_counts_time ON page_view_counts (bucket_start)").run()
        }
    }

    func revert(on database: Database) async throws {
        try await Self.sql(database).raw("DROP TABLE IF EXISTS page_view_counts").run()
    }

    private static func sql(_ database: Database) throws -> any SQLDatabase {
        guard let sql = database as? SQLDatabase else { throw PageViewMigrationError.requiresSQL }
        return sql
    }
}

/// Thrown when the page view migration runs on a database without SQL.
enum PageViewMigrationError: Error, CustomStringConvertible {
    case requiresSQL

    var description: String {
        "SwiftlyBotKit's page view counters need a PostgreSQL database."
    }
}
