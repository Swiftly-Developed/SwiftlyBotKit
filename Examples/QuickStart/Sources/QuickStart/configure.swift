import Fluent
import FluentPostgresDriver
import SwiftlyBotKit
import Vapor

/// A two-page site with AI-agent tracking and the dashboard at `/admin/ai-bots/`.
func configure(_ app: Application) async throws {
    // 1. PostgreSQL is required: the migration creates enum types and the
    //    dashboard runs PostgreSQL-specific aggregate queries. The fallback
    //    matches the docker-compose.yml in this folder.
    let databaseURL = Environment.get("DATABASE_URL")
        ?? "postgres://botkit:botkit@localhost:5432/botkit?sslmode=disable"
    try app.databases.use(.postgres(url: databaseURL), as: .psql)

    // 2. Static files first, so a recorded status code is the one the client
    //    actually received.
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // 3. BotKit. Every option has a default; these show the common ones.
    var config = BotKitConfiguration()

    // Never record health checks.
    config.recording.excludedPathPrefixes = ["/healthz"]

    // Recognise an in-house crawler as well as the built-in catalog.
    config.detection.customAgents = [
        AIAgent(token: "ExampleResearchBot", purpose: .agent, operatorName: "Example Inc."),
    ]

    // Local development talks to the app directly, with no proxy in front.
    // Behind one reverse proxy or a PaaS router, keep `.lastForwardedFor`.
    config.clientIP = .remoteAddress

    // Dashboard: credentials come from BOT_DASHBOARD_USER and
    // BOT_DASHBOARD_PASSWORD (the defaults); the session key from
    // BOT_DASHBOARD_SECRET.
    config.dashboard.title = "QuickStart AI traffic"
    config.dashboard.timeZone = .europeParis

    try BotKit.install(on: app, config: config)

    // 4. Create the `ai_bot_visits` table.
    try await app.autoMigrate()

    // 5. The site itself.
    try routes(app)
}

func routes(_ app: Application) throws {
    app.get { _ in
        html("""
        <h1>QuickStart</h1>
        <p>Every AI agent that reads this page is recorded.</p>
        <p><a href="/about/">About</a></p>
        """)
    }

    app.get("about") { _ in
        html("""
        <h1>About</h1>
        <p>A minimal Vapor app with SwiftlyBotKit installed.</p>
        <p><a href="/">Home</a></p>
        """)
    }

    app.get("healthz") { _ in "ok" }
}

private func html(_ body: String) -> Response {
    let page = """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>QuickStart</title></head>
    <body>\(body)</body>
    </html>
    """
    var headers = HTTPHeaders()
    headers.contentType = .html
    return Response(status: .ok, headers: headers, body: .init(string: page))
}
