import Fluent
import FluentPostgresDriver
import SwiftlyBotKit
import Vapor

public func configure(_ app: Application) async throws {
    // Database setup as in the first tutorial.

    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    try BotKit.install(on: app, config: botKitConfiguration())
    try await app.autoMigrate()

    try routes(app)
}

func botKitConfiguration() -> BotKitConfiguration {
    var config = BotKitConfiguration()

    // Credentials and the session secret, read from your own variable names.
    config.dashboard.username = .environment("ADMIN_USER")
    config.dashboard.password = .environment("ADMIN_PASSWORD")
    config.signingSecret = .environment("ADMIN_SESSION_SECRET")

    // Where it lives, what it is called, and whose midnight a "day" starts at.
    config.dashboard.path = "/internal/ai-traffic"
    config.dashboard.title = "Crawler traffic"
    config.dashboard.timeZone = .americaNewYork

    // Three filter pills instead of four, opening on the last 30 days.
    config.dashboard.dateRanges = [.week, .month, .quarter]
    config.dashboard.defaultDateRange = .month

    // Shorter sessions and a stricter sign-in throttle.
    config.dashboard.sessionLifetime = 8 * 60 * 60
    config.dashboard.loginLimit = .init(maximumFailures: 3, window: 30 * 60)

    // One app, two domains: file each request under the site it was served for.
    config.siteKey = { req in
        let host = req.headers.first(name: .host)?.lowercased() ?? ""
        return host.hasSuffix("docs.example.com") ? "docs" : "shop"
    }

    return config
}
