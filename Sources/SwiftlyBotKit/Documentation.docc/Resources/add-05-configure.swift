import Fluent
import FluentPostgresDriver
import SwiftlyBotKit
import Vapor

public func configure(_ app: Application) async throws {
    app.databases.use(.postgres(configuration: .init(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
        password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
        database: Environment.get("DATABASE_NAME") ?? "vapor_database",
        tls: .disable
    )), as: .psql)

    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // After FileMiddleware, so the recorded status code is the one the client got.
    try BotKit.install(on: app)

    // Creates the ai_bot_visits table and its two PostgreSQL enum types.
    try await app.autoMigrate()

    try routes(app)
}
