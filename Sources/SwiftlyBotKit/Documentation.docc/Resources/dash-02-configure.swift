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

    return config
}
