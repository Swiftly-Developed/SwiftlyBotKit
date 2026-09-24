import Fluent
import FluentPostgresDriver
import SwiftlyBotKit
import Vapor

public func configure(_ app: Application) async throws {
    // Database setup as in the first tutorial.

    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    try BotKit.install(on: app, config: botKitConfiguration(for: app.environment))
    try await app.autoMigrate()

    try routes(app)
}
