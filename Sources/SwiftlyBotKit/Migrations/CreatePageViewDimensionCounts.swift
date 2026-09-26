import Fluent
import FluentSQL

/// The dimension counters: one row per site, day, dimension, value and page.
///
/// Answers "which referrers sent people to this page", "which countries read
/// this article". Registered only when page view dimensions are enabled
/// (`BotKit.configure(for:database:pageViews:pageViewDimensions:)`).
///
/// `day` is the local date in the dashboard's time zone when the view was
/// counted, not a UTC instant: a day is the smallest unit these rows are ever
/// read at, and fixing it at write time keeps the rows coarse. `dimension` is
/// a ``PageViewDimension`` raw value and `value` the coarse value it produced.
/// There is deliberately nowhere to put anything about the visitor.
///
/// The composite key doubles as the index the dashboard reads through ("this
/// site, these days") and is what the flush's `ON CONFLICT` upsert targets.
/// Names are frozen once released.
struct CreatePageViewDimensionCounts: AsyncMigration {
    /// Pinned, like ``CreatePageViewCounts/name``. Never change this string.
    var name: String { "SwiftlyBotKit.CreatePageViewDimensionCounts" }

    func prepare(on database: Database) async throws {
        try await database.transaction { database in
            let sql = try PageViewMigrationSQL.sql(database)
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS page_view_dimension_counts (
                    site_key text NOT NULL,
                    day date NOT NULL,
                    dimension text NOT NULL,
                    value text NOT NULL,
                    path text NOT NULL,
                    views bigint NOT NULL,
                    PRIMARY KEY (site_key, day, dimension, value, path)
                )
                """).run()
            // The all-sites view reads a dimension across every site.
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_page_view_dimension_counts_day ON page_view_dimension_counts (day, dimension)").run()
        }
    }

    func revert(on database: Database) async throws {
        try await PageViewMigrationSQL.sql(database).raw("DROP TABLE IF EXISTS page_view_dimension_counts").run()
    }
}

/// The pair counters: one row per site, day and pair of dimension values,
/// with no page.
///
/// Answers "country by device", "campaign source by medium". A pair is
/// stored once, its first dimension being the one declared first in
/// ``PageViewDimension`` (see ``PageViewDimension/pairs``), so a reader
/// never has to look under both orders. No row holds more than two
/// dimensions: that, the missing page and the daily buckets are what keep
/// each count about many readers rather than one.
struct CreatePageViewPairCounts: AsyncMigration {
    /// Pinned. Never change this string.
    var name: String { "SwiftlyBotKit.CreatePageViewPairCounts" }

    func prepare(on database: Database) async throws {
        try await database.transaction { database in
            let sql = try PageViewMigrationSQL.sql(database)
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS page_view_pair_counts (
                    site_key text NOT NULL,
                    day date NOT NULL,
                    first_dimension text NOT NULL,
                    first_value text NOT NULL,
                    second_dimension text NOT NULL,
                    second_value text NOT NULL,
                    views bigint NOT NULL,
                    PRIMARY KEY (site_key, day, first_dimension, second_dimension, first_value, second_value)
                )
                """).run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_page_view_pair_counts_day ON page_view_pair_counts (day, first_dimension, second_dimension)").run()
        }
    }

    func revert(on database: Database) async throws {
        try await PageViewMigrationSQL.sql(database).raw("DROP TABLE IF EXISTS page_view_pair_counts").run()
    }
}

enum PageViewMigrationSQL {
    static func sql(_ database: Database) throws -> any SQLDatabase {
        guard let sql = database as? SQLDatabase else { throw PageViewMigrationError.requiresSQL }
        return sql
    }
}
