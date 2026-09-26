import Foundation
import Vapor
import Fluent
import SQLKit

/// AI-agent traffic tracking for a Vapor app, plus a password-protected
/// dashboard that reads it back.
///
/// Two halves that run independently:
///
/// - **Recording.** A middleware classifies every request against
///   ``AIAgentCatalog``, verifies the big operators against their published IP
///   ranges, and writes a row per AI agent visit and per AI-assistant referral.
///   Ordinary human traffic is never recorded there, and no response is ever
///   delayed.
/// - **Page views**, when turned on (``BotKitConfiguration/pageViews``): an
///   anonymous count of how often people read each page, kept as one counter
///   per page and quarter-hour, with no cookie and nothing about the visitor.
/// - **The dashboard**, by default at `/admin/ai-bots/`: charts, tiles, a date
///   filter and, for multi-site apps, a site switcher, plus a "Page views"
///   tab when page views are counted. Mounted only when a
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

    /// Registers the database migrations. Call before `app.autoMigrate()`.
    ///
    /// The migration creates the `ai_bot_visits` table, two PostgreSQL enum
    /// types (`ai_agent_purpose`, `bot_verification`) and three indexes, in
    /// `database` (default: the app's default database). Pass the same
    /// database as ``BotKitConfiguration/database``.
    ///
    /// With `pageViews` set, it also registers the `page_view_counts` table
    /// that ``BotKitConfiguration/PageViews`` writes to. Pass `true` exactly
    /// when `config.pageViews.isEnabled` is; ``configureRoutes(for:config:)``
    /// throws when counting is on and its table was not registered here.
    ///
    /// Registers the migrations once per application: a second call logs an
    /// error and does nothing, since a duplicate would fail `autoMigrate` on
    /// its `CREATE TYPE`.
    public static func configure(for app: Application, database: DatabaseID? = nil, pageViews: Bool = false) {
        let registered = app.storage[InstallationKey.self]?.migrationRegistered ?? false
        guard !registered else {
            app.logger.error("BotKit.configure(for:) was called again; the migration is already registered, so this call does nothing.")
            return
        }
        app.migrations.add(CreateAIBotVisit(), to: database)
        if pageViews {
            app.migrations.add(CreatePageViewCounts(), to: database)
        }
        markInstalled(app) {
            $0.migrationRegistered = true
            $0.pageViewsMigrationRegistered = pageViews
        }
    }

    /// Installs the tracking middleware and, when credentials resolve, the
    /// dashboard routes.
    ///
    /// Call after adding `FileMiddleware`, so that the recorded status code is
    /// the one the client actually received. Logs a warning when the
    /// dashboard is enabled but has no credentials (a value that is empty or
    /// only whitespace counts as none), when no signing secret is configured,
    /// when the signing secret is shorter than 32 bytes, and when a site key
    /// is listed twice.
    ///
    /// - Throws: ``BotKitConfigurationError`` for a dashboard path or cookie
    ///   name that cannot work, a site keyed `all`, or a second call on the
    ///   same application.
    public static func configureRoutes(
        for app: Application,
        config: BotKitConfiguration = BotKitConfiguration()
    ) throws {
        if app.storage[InstallationKey.self]?.routesConfigured == true {
            throw BotKitConfigurationError.alreadyInstalled(
                "configureRoutes(for:config:) or install(on:config:) was already called. Call it once, or every bot hit would be recorded twice."
            )
        }
        try config.validate()
        if config.pageViews.isEnabled,
           let installation = app.storage[InstallationKey.self], installation.migrationRegistered,
           !installation.pageViewsMigrationRegistered {
            throw BotKitConfigurationError.pageViewsNotMigrated
        }
        var config = config
        let duplicates = config.duplicateSiteKeys
        if !duplicates.isEmpty {
            app.logger.warning(
                "BotKit sites list the key(s) \(duplicates.joined(separator: ", ")) more than once; only the first entry for each is offered in the dashboard."
            )
            config.sites = BotKitConfiguration.uniqueSites(config.sites)
        }
        markInstalled(app) { $0.routesConfigured = true }

        // The HTTP client is resolved on the first feed fetch, never here:
        // reading `app.client` creates Vapor's shared HTTP client and freezes
        // `app.http.client.configuration` for the whole app.
        let runtime = BotKitRuntime(
            configuration: config,
            clientProvider: { [weak app] in app?.client },
            logger: app.logger
        )

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
                clientIP: config.clientIP,
                pendingWrites: PendingWriteLimiter(maximum: config.recording.maximumPendingWrites),
                logger: app.logger
            ))
        }

        if config.pageViews.isEnabled {
            let databaseID = config.database
            let counter = PageViewCounter(
                database: { [weak app] in
                    // `app.db` traps for an unregistered ID; check first.
                    guard let app else { return nil }
                    let registered = app.databases.ids()
                    guard databaseID.map({ registered.contains($0) }) ?? !registered.isEmpty else { return nil }
                    return app.db(databaseID) as? SQLDatabase
                },
                configuration: config.pageViews,
                logger: app.logger
            )
            app.middleware.use(PageViewCountingMiddleware(
                filter: PageViewFilter(classifier: runtime.classifier),
                counter: counter,
                siteKey: config.siteKey
            ))
            app.lifecycle.use(PageViewLifecycle(counter: counter))
            app.storage[PageViewCounterKey.self] = counter
        }

        guard config.dashboard.isEnabled else { return }
        if !config.dashboard.timeZone.isAvailable {
            app.logger.warning(
                "This host's time zone database does not know \(config.dashboard.timeZone.identifier), so the AI bot dashboard draws its buckets in UTC. Update the host's tzdata to use it."
            )
        }
        // `resolve()` trims, so whitespace-only counts as unset: a stray space
        // in a config var must not mount the dashboard behind a blank password.
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

    /// ``configure(for:database:pageViews:)`` and ``configureRoutes(for:config:)`` in one call.
    ///
    /// Call after adding `FileMiddleware` and before `app.autoMigrate()`. Do
    /// not also call ``configure(for:database:pageViews:)``.
    ///
    /// - Throws: ``BotKitConfigurationError/alreadyInstalled(_:)`` when
    ///   ``configure(for:database:pageViews:)``, ``configureRoutes(for:config:)`` or
    ///   `install` already ran on this application, and any other
    ///   ``BotKitConfigurationError`` ``configureRoutes(for:config:)`` throws.
    ///   Nothing is registered when it throws.
    public static func install(
        on app: Application,
        config: BotKitConfiguration = BotKitConfiguration()
    ) throws {
        if app.storage[InstallationKey.self]?.migrationRegistered == true {
            throw BotKitConfigurationError.alreadyInstalled(
                "the migration is already registered, by configure(for:database:pageViews:) or an earlier install(on:config:). install(on:config:) already calls configure(for:database:pageViews:); call one or the other."
            )
        }
        if app.storage[InstallationKey.self]?.routesConfigured == true {
            throw BotKitConfigurationError.alreadyInstalled(
                "configureRoutes(for:config:) or install(on:config:) was already called."
            )
        }
        // Validate before registering anything, so a bad configuration
        // leaves the application untouched.
        try config.validate()
        configure(for: app, database: config.database, pageViews: config.pageViews.isEnabled)
        try configureRoutes(for: app, config: config)
    }

    /// What has been installed on one application.
    struct Installation: Sendable {
        var migrationRegistered = false
        var pageViewsMigrationRegistered = false
        var routesConfigured = false
    }

    struct InstallationKey: StorageKey {
        typealias Value = Installation
    }

    /// The application's page view counter, when page views are on.
    struct PageViewCounterKey: StorageKey {
        typealias Value = PageViewCounter
    }

    private static func markInstalled(_ app: Application, _ update: (inout Installation) -> Void) {
        var installation = app.storage[InstallationKey.self] ?? Installation()
        update(&installation)
        app.storage[InstallationKey.self] = installation
    }
}

/// The long-lived objects one configuration produces, shared by the recorder
/// and the dashboard.
struct BotKitRuntime: Sendable {
    let classifier: BotRequestClassifier
    let directory: CrawlerIPDirectory?
    let signer: BotSigner
    let loginAttempts: LoginAttemptLimiter

    /// `clientProvider` is only called when a feed is fetched, which never
    /// happens with verification off.
    init(configuration: BotKitConfiguration, clientProvider: @escaping @Sendable () -> (any Client)?, logger: Logger) {
        self.classifier = BotRequestClassifier(configuration: configuration)
        self.directory = configuration.verification.isEnabled
            ? CrawlerIPDirectory(
                feeds: configuration.verification.feeds,
                refreshInterval: configuration.verification.refreshInterval,
                clientProvider: clientProvider,
                logger: logger
            )
            : nil
        if let secret = configuration.signingSecret?.resolve() {
            if secret.utf8.count < BotSigner.recommendedSecretLength {
                logger.warning(
                    "The AI bot signing secret is shorter than \(BotSigner.recommendedSecretLength) bytes. A captured session cookie is enough to brute-force a short secret offline; use a long random value such as the output of `openssl rand -hex 32`."
                )
            }
            self.signer = BotSigner(secret: secret)
        } else {
            logger.warning(
                "No AI bot signing secret is configured, so a random per-process secret is used. Dashboard sign-ins end at every restart, and IP hashes will not match rows written before it."
            )
            self.signer = BotSigner(secret: UUID().uuidString + UUID().uuidString)
        }
        self.loginAttempts = LoginAttemptLimiter(limit: configuration.dashboard.loginLimit)
    }

    init(configuration: BotKitConfiguration, client: any Client, logger: Logger) {
        self.init(configuration: configuration, clientProvider: { client }, logger: logger)
    }
}
