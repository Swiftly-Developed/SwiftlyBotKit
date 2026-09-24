import Foundation
import Vapor
import Fluent

/// AI-agent traffic tracking for a Vapor app, plus a password-protected
/// dashboard that reads it back.
///
/// Two halves that run independently:
///
/// - **Recording.** A middleware classifies every request against
///   ``AIAgentCatalog``, verifies the big operators against their published IP
///   ranges, and writes a row per AI agent visit and per AI-assistant referral.
///   Ordinary human traffic is never recorded, and no response is ever delayed.
/// - **The dashboard**, by default at `/admin/ai-bots/`: charts, tiles, a date
///   filter and, for multi-site apps, a site switcher. Mounted only when a
///   username and password are configured, so an unconfigured deploy answers
///   404 rather than exposing an open page.
///
/// **PostgreSQL is required.** The migration creates PostgreSQL enum types and
/// the dashboard's aggregate queries use PostgreSQL-specific SQL. It does not
/// need a database of its own: by default the table is created in, written to
/// and read from the app's default database, beside the app's own tables. Set
/// ``BotKitConfiguration/database`` to use another registered database.
///
/// Minimal setup, in `configure.swift`:
///
/// ```swift
/// app.databases.use(.postgres(configuration: ...), as: .psql)
/// app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
/// try BotKit.install(on: app)
/// try await app.autoMigrate()
/// ```
///
/// All behaviour is set through ``BotKitConfiguration``.
public enum BotKit {

    /// Registers the database migration. Call before `app.autoMigrate()`.
    ///
    /// The migration creates the `ai_bot_visits` table, two PostgreSQL enum
    /// types (`ai_agent_purpose`, `bot_verification`) and three indexes, in
    /// `database` (default: the app's default database). Pass the same
    /// database as ``BotKitConfiguration/database``.
    public static func configure(for app: Application, database: DatabaseID? = nil) {
        app.migrations.add(CreateAIBotVisit(), to: database)
    }

    /// Installs the tracking middleware and, when credentials resolve, the
    /// dashboard routes.
    ///
    /// Call after adding `FileMiddleware`, so that the recorded status code is
    /// the one the client actually received. Logs a warning when the
    /// dashboard is enabled but has no credentials, and when no signing secret
    /// is configured.
    public static func configureRoutes(
        for app: Application,
        config: BotKitConfiguration = BotKitConfiguration()
    ) throws {
        let runtime = BotKitRuntime(configuration: config, client: app.client, logger: app.logger)

        if config.recording.isEnabled {
            let recorder = BotTrafficRecorder(
                database: app.db(config.database),
                classifier: runtime.classifier,
                directory: runtime.directory,
                signer: runtime.signer,
                logger: app.logger
            )
            app.middleware.use(AIBotTrackingMiddleware(
                recorder: recorder,
                siteKey: config.siteKey,
                clientIP: config.clientIP
            ))
        }

        guard config.dashboard.isEnabled else { return }
        guard let username = config.dashboard.username?.resolve(),
              let password = config.dashboard.password?.resolve()
        else {
            app.logger.warning(
                "AI bot dashboard credentials are not configured, so the dashboard at \(config.dashboard.basePath)/ is not mounted. Recording is unaffected."
            )
            return
        }
        try app.register(collection: BotDashboardController(
            config: config,
            runtime: runtime,
            username: username,
            password: password
        ))
    }

    /// ``configure(for:database:)`` and ``configureRoutes(for:config:)`` in one call.
    ///
    /// Call after adding `FileMiddleware` and before `app.autoMigrate()`. Do
    /// not also call ``configure(for:database:)``, or the migration is registered twice.
    public static func install(
        on app: Application,
        config: BotKitConfiguration = BotKitConfiguration()
    ) throws {
        configure(for: app, database: config.database)
        try configureRoutes(for: app, config: config)
    }
}

/// The long-lived objects one configuration produces, shared by the recorder
/// and the dashboard.
struct BotKitRuntime: Sendable {
    let classifier: BotRequestClassifier
    let directory: CrawlerIPDirectory?
    let signer: BotSigner
    let loginAttempts: LoginAttemptLimiter

    init(configuration: BotKitConfiguration, client: any Client, logger: Logger) {
        self.classifier = BotRequestClassifier(configuration: configuration)
        self.directory = configuration.verification.isEnabled
            ? CrawlerIPDirectory(
                feeds: configuration.verification.feeds,
                refreshInterval: configuration.verification.refreshInterval,
                client: client,
                logger: logger
            )
            : nil
        if let secret = configuration.signingSecret?.resolve() {
            self.signer = BotSigner(secret: secret)
        } else {
            logger.warning(
                "No AI bot signing secret is configured, so a random per-process secret is used. Dashboard sign-ins end at every restart, and IP hashes will not match rows written before it."
            )
            self.signer = BotSigner(secret: UUID().uuidString + UUID().uuidString)
        }
        self.loginAttempts = LoginAttemptLimiter(limit: configuration.dashboard.loginLimit)
    }
}
