import Foundation
import Vapor
import Fluent

/// Everything `BotKit` can be told about the app it is installed in.
///
/// Every property has a default, so the smallest useful setup is
/// `BotKitConfiguration()`: one site, recording on, IP verification on, and a
/// dashboard at `/admin/ai-bots/` that is mounted once `BOT_DASHBOARD_USER` and
/// `BOT_DASHBOARD_PASSWORD` are set in the environment.
///
/// The options are grouped into small nested structs (`recording`,
/// `detection`, `verification`, `dashboard`, `pageViews`) plus the client IP strategy, each
/// with a `default` value you can copy and adjust:
///
/// ```swift
/// var config = BotKitConfiguration()
/// config.dashboard.path = "/internal/bots"
/// config.dashboard.timeZone = .americaNewYork
/// config.clientIP = .forwardedFor(trustedProxies: 2)
/// try BotKit.configureRoutes(for: app, config: config)
/// ```
public struct BotKitConfiguration: Sendable {

    /// The site key used when the app does not supply its own `siteKey`.
    public static let defaultSiteKey = "default"

    /// The `?site=` value of the dashboard's all-sites view, and therefore not
    /// usable as a site key in ``sites``.
    ///
    /// When ``siteKey`` returns it at runtime, the row is stored under `all`
    /// as returned and a warning is logged once per process. Such rows count
    /// towards the all-sites view but can never be filtered to on their own.
    public static let reservedAllSitesKey = "all"

    /// Which site a request belongs to, stored on every recorded row as
    /// `site_key`.
    ///
    /// A multi-site app should return the same key its own host-based routing
    /// uses, so the dashboard's site filter splits traffic the way the router
    /// does. A single-site app can leave the default, which files everything
    /// under ``defaultSiteKey``. Never return ``reservedAllSitesKey``.
    public var siteKey: @Sendable (Request) -> String

    /// The sites the dashboard's switcher offers. Keys must match what
    /// ``siteKey`` returns.
    ///
    /// Leave empty for a single-site app: the switcher is only shown when there
    /// are at least two sites to choose between. The key `all` is reserved for
    /// the all-sites view (``reservedAllSitesKey``): a site keyed `all` makes
    /// `BotKit.configureRoutes(for:config:)` throw. A key listed twice is
    /// logged as a warning and only its first entry is offered.
    public var sites: [BotDashboardSite]

    /// The HMAC key behind dashboard session cookies and the keyed hash that
    /// stands in for client IP addresses.
    ///
    /// Defaults to the `BOT_DASHBOARD_SECRET` environment variable. When it
    /// resolves to nothing, a random per-process key is used and a warning is
    /// logged: sessions then end at every restart, and IP hashes stop matching
    /// rows written by earlier processes.
    public var signingSecret: BotKitConfigValue?

    /// What gets recorded.
    public var recording: Recording

    /// How requests are recognised as AI agents or AI-assistant referrals.
    public var detection: Detection

    /// Whether and how claimed agents are checked against their operators'
    /// published IP ranges.
    public var verification: Verification

    /// How the client's IP address is read from a request. Used for IP
    /// verification, for the stored IP hash, and to key the login limiter.
    public var clientIP: ClientIPStrategy

    /// The password-protected dashboard.
    public var dashboard: Dashboard

    /// Anonymous page view counting for human visitors. Off by default.
    public var pageViews: PageViews

    /// Which of the app's databases the table lives in, recording writes to
    /// and the dashboard reads from. Default `nil`: the app's default
    /// database, so the table sits beside the app's own tables and no
    /// separate database is needed. Set it when the app registers several
    /// databases and BotKit should use a non-default one; it must be
    /// PostgreSQL either way.
    public var database: DatabaseID?

    /// Creates a configuration. Every parameter has a default; see each
    /// property for what it controls.
    public init(
        siteKey: @escaping @Sendable (Request) -> String = { _ in BotKitConfiguration.defaultSiteKey },
        sites: [BotDashboardSite] = [],
        signingSecret: BotKitConfigValue? = .environment("BOT_DASHBOARD_SECRET"),
        recording: Recording = .default,
        detection: Detection = .default,
        verification: Verification = .default,
        clientIP: ClientIPStrategy = .lastForwardedFor,
        dashboard: Dashboard = .default,
        pageViews: PageViews = .default,
        database: DatabaseID? = nil
    ) {
        self.siteKey = siteKey
        self.sites = sites
        self.signingSecret = signingSecret
        self.recording = recording
        self.detection = detection
        self.verification = verification
        self.clientIP = clientIP
        self.dashboard = dashboard
        self.pageViews = pageViews
        self.database = database
    }

    /// The site for a `?site=` value, or `nil` for the all-sites view.
    ///
    /// With no `?site=` at all, the dashboard opens on the site whose domain it
    /// was opened on. "All sites" is an explicit `?site=all`, which every
    /// switcher link and range pill carries, so choosing it sticks.
    func site(forKey key: String?, hostSiteKey: String) -> BotDashboardSite? {
        let key = key ?? hostSiteKey
        guard key != Self.reservedAllSitesKey else { return nil }
        return sites.first { $0.key == key }
    }

    /// `sites` with every repeated key after its first entry removed.
    static func uniqueSites(_ sites: [BotDashboardSite]) -> [BotDashboardSite] {
        var seen = Set<String>()
        return sites.filter { seen.insert($0.key).inserted }
    }
}

// MARK: - Recording

extension BotKitConfiguration {

    /// Which requests are recorded.
    public struct Recording: Sendable, Equatable {

        /// Static assets a crawler pulls alongside a page. `.txt` and `.xml`
        /// are deliberately absent: a crawler fetching `robots.txt` or
        /// `sitemap.xml` is a real signal.
        public static let defaultIgnoredFileExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "ico",
            "css", "js", "mjs", "map", "woff", "woff2", "ttf", "otf",
            "mp4", "mov", "webm", "pdf", "zip",
        ]

        /// Records AI agents, records AI-assistant referrals, skips static
        /// assets and the dashboard's own paths.
        public static let `default` = Recording()

        /// Record requests whose user agent matches a known AI agent.
        /// Default `true`.
        public var recordsAgents: Bool

        /// Record humans arriving from an AI assistant (a `Referer` on a known
        /// assistant host). Default `true`.
        public var recordsReferrals: Bool

        /// Lowercased file extensions (without the dot) that are never
        /// recorded. Recording assets would multiply every page view by its
        /// image count and say nothing new. Default
        /// ``defaultIgnoredFileExtensions``.
        public var ignoredFileExtensions: Set<String>

        /// Path prefixes that are never recorded, such as `/healthz` or an
        /// internal API. The dashboard's own path is always excluded on top of
        /// these. Default empty.
        ///
        /// These are plain string prefixes, not path segments: `/health`
        /// also excludes `/health-insurance/`. End an entry with `/`
        /// (`/health/`) to exclude only what sits below it.
        public var excludedPathPrefixes: [String]

        /// The most recording writes allowed in flight at once. Each recorded
        /// request hands its write to a detached task; with a slow database and
        /// a crawler burst those tasks would otherwise pile up in memory
        /// without bound. Beyond this many, further rows are dropped and a
        /// warning is logged (the first drop, then every thousandth). Values
        /// below 1 count as 1. Default `256`.
        public var maximumPendingWrites: Int

        /// `true` when at least one kind of traffic is recorded. When `false`,
        /// the tracking middleware is not installed at all.
        public var isEnabled: Bool { recordsAgents || recordsReferrals }

        /// Creates a recording configuration.
        public init(
            recordsAgents: Bool = true,
            recordsReferrals: Bool = true,
            ignoredFileExtensions: Set<String> = Recording.defaultIgnoredFileExtensions,
            excludedPathPrefixes: [String] = [],
            maximumPendingWrites: Int = 256
        ) {
            self.recordsAgents = recordsAgents
            self.recordsReferrals = recordsReferrals
            self.ignoredFileExtensions = ignoredFileExtensions
            self.excludedPathPrefixes = excludedPathPrefixes
            self.maximumPendingWrites = maximumPendingWrites
        }
    }
}

// MARK: - Detection

extension BotKitConfiguration {

    /// The agent catalog and AI-assistant referrer list requests are matched
    /// against.
    public struct Detection: Sendable, Equatable {

        /// The built-in catalog and referrer list, with nothing added.
        public static let `default` = Detection()

        /// Match against the generated ``AIAgentCatalog``. Default `true`.
        public var includesBuiltInAgents: Bool

        /// Agents to recognise in addition to the built-in catalog. An entry
        /// whose token equals a built-in token (case-insensitively) replaces
        /// the built-in entry, which is how to reclassify an agent. Default
        /// empty.
        public var customAgents: [AIAgent]

        /// Match referrers against ``LLMReferrer/builtInPlatforms``. Default
        /// `true`.
        public var includesBuiltInReferrers: Bool

        /// Assistant hosts to recognise in addition to the built-in list. An
        /// entry with the same host suffix as a built-in one replaces it.
        /// Default empty.
        public var customReferrers: [LLMReferrer.Platform]

        /// Creates a detection configuration.
        public init(
            includesBuiltInAgents: Bool = true,
            customAgents: [AIAgent] = [],
            includesBuiltInReferrers: Bool = true,
            customReferrers: [LLMReferrer.Platform] = []
        ) {
            self.includesBuiltInAgents = includesBuiltInAgents
            self.customAgents = customAgents
            self.includesBuiltInReferrers = includesBuiltInReferrers
            self.customReferrers = customReferrers
        }
    }
}

// MARK: - Verification

extension BotKitConfiguration {

    /// Checking claimed agents against the IP ranges their operators publish.
    public struct Verification: Sendable, Equatable {

        /// Verification on, against ``CrawlerRangeFeed/defaults``, refreshed
        /// every twelve hours.
        public static let `default` = Verification()

        /// When `false`, no feed is ever fetched and every agent visit is
        /// stored as ``BotVerification/unverified``. Default `true`.
        public var isEnabled: Bool

        /// The published range feeds and the agents each one covers. Default
        /// ``CrawlerRangeFeed/defaults``.
        public var feeds: [CrawlerRangeFeed]

        /// How long fetched ranges are trusted before a background refresh.
        /// Requests never wait on a refresh once ranges are cached. Default
        /// twelve hours.
        public var refreshInterval: TimeInterval

        /// Creates a verification configuration.
        public init(
            isEnabled: Bool = true,
            feeds: [CrawlerRangeFeed] = CrawlerRangeFeed.defaults,
            refreshInterval: TimeInterval = 12 * 60 * 60
        ) {
            self.isEnabled = isEnabled
            self.feeds = feeds
            self.refreshInterval = refreshInterval
        }
    }
}

// MARK: - Page views

extension BotKitConfiguration {

    /// Anonymous page view counts for human visitors, shown on the dashboard's
    /// "Page views" tab.
    ///
    /// Nothing about a visitor is stored. There is no cookie, no IP address or
    /// IP hash, no user agent and no referrer, and no timestamp per visit. Each
    /// counted view adds one to a counter for its site, path and quarter-hour,
    /// and that counter is all that reaches the database. It answers "how often
    /// was this page read", not "who read it" or "how many people".
    ///
    /// A view is counted when the request is a `GET` answered `2xx` or `304`
    /// with an HTML body, from a browser: no AI agent from the catalog, nothing
    /// that names itself a bot, crawler or HTTP library, no HTMX swap, no
    /// prefetch, and when the browser says what it is fetching
    /// (`Sec-Fetch-Dest`), a top-level document. The dashboard path and
    /// ``BotKitConfiguration/Recording/excludedPathPrefixes`` are skipped.
    ///
    /// Off by default, and it needs its own table: pass `pageViews: true` to
    /// `BotKit.configure(for:database:pageViews:)`, or use
    /// `BotKit.install(on:config:)`, which reads this setting.
    public struct PageViews: Sendable, Equatable {

        /// Counting off.
        public static let `default` = PageViews()

        /// Count page views and offer the "Page views" tab. Default `false`.
        public var isEnabled: Bool

        /// How often the counts gathered in memory are written, in one
        /// statement. They are also written when the app shuts down; a process
        /// that is killed loses at most this much. Values below one second
        /// count as one second. Default ten seconds.
        public var flushInterval: TimeInterval

        /// The most distinct site, path and quarter-hour counters held in
        /// memory between writes. Beyond it further views are dropped and a
        /// warning is logged, so an app that answers `200` for any path cannot
        /// be made to grow memory without bound. Values below 1 count as 1.
        /// Default `10_000`.
        public var maximumPendingCounters: Int

        /// Creates a page view configuration.
        public init(
            isEnabled: Bool = false,
            flushInterval: TimeInterval = 10,
            maximumPendingCounters: Int = 10_000
        ) {
            self.isEnabled = isEnabled
            self.flushInterval = flushInterval
            self.maximumPendingCounters = maximumPendingCounters
        }
    }
}

/// One published IP range feed and the agents it vouches for.
///
/// Feeds use the JSON shape the major operators share:
/// `{"prefixes": [{"ipv4Prefix": "…"}, {"ipv6Prefix": "…"}]}`. The body is
/// decoded whatever `Content-Type` it is served with, an entry that does not
/// fit the shape is skipped rather than failing the feed, and prefixes broader
/// than an IPv4 `/8` or an IPv6 `/16` are ignored. Each fetch has a
/// ten-second deadline and a 2 MiB body limit. When several feeds name the
/// same agent, their ranges are combined.
public struct CrawlerRangeFeed: Sendable, Equatable {

    /// The feeds of OpenAI, Anthropic and Perplexity.
    ///
    /// OpenAI publishes a separate list per agent. Anthropic publishes one list
    /// for all three Claude agents, so a verified Claude hit proves "genuinely
    /// Anthropic" and the user agent says which of the three it was.
    public static let defaults: [CrawlerRangeFeed] = [
        .init(url: "https://openai.com/gptbot.json", agentTokens: ["GPTBot"]),
        .init(url: "https://openai.com/searchbot.json", agentTokens: ["OAI-SearchBot"]),
        .init(url: "https://openai.com/chatgpt-user.json", agentTokens: ["ChatGPT-User"]),
        .init(url: "https://claude.com/crawling/bots.json",
              agentTokens: ["ClaudeBot", "Claude-User", "Claude-SearchBot"]),
        .init(url: "https://www.perplexity.ai/perplexitybot.json", agentTokens: ["PerplexityBot"]),
        .init(url: "https://www.perplexity.ai/perplexity-user.json", agentTokens: ["Perplexity-User"]),
    ]

    /// The feed's absolute URL.
    public var url: String

    /// The agent tokens (as in ``AIAgent/token``) whose claims this feed can
    /// confirm. Compared case-insensitively.
    public var agentTokens: [String]

    /// Creates a feed entry.
    public init(url: String, agentTokens: [String]) {
        self.url = url
        self.agentTokens = agentTokens
    }
}

// MARK: - Client IP

/// Where the client's IP address comes from.
///
/// This matters for security, not just accuracy: IP verification is only as
/// honest as the address it checks. `X-Forwarded-For` is a list that each proxy
/// appends to, so its leftmost entry is whatever the client chose to send.
/// Trusting it would let any spoofer claim an operator's address and earn a
/// `verified` badge.
///
/// Choosing one:
/// - behind exactly one proxy that appends to `X-Forwarded-For`:
///   ``lastForwardedFor`` (the default);
/// - behind a chain of `n` appending proxies: ``forwardedFor(trustedProxies:)``;
/// - reachable directly from the internet, with no proxy: ``remoteAddress``;
/// - behind a proxy that sets its own header: ``custom(_:)``.
///
/// The default trusts the header whoever sent it. An app that clients can reach
/// without passing through the proxy (exposed directly, or on a platform
/// hostname that bypasses a CDN) **must** use ``remoteAddress`` or lock the
/// origin to the proxy, or a client can write the last entry itself.
///
/// Forwarded entries are read leniently: `1.2.3.4:5678`, `[2600::5]:443` and
/// `[2600::5]` yield the bare address. A port is only stripped from a
/// bracketed entry or one with exactly one colon, so a plain IPv6 address is
/// never cut short.
public enum ClientIPStrategy: Sendable {

    /// The last `X-Forwarded-For` entry, falling back to the socket's remote
    /// address when the header is absent. Right for exactly one trusted
    /// reverse proxy or load balancer that appends the address it saw (Heroku,
    /// most PaaS routers, a single nginx). The default.
    ///
    /// Wrong for an app that faces the internet directly: there nothing
    /// appends to the header, so the client writes the last entry itself. Use
    /// ``remoteAddress`` there.
    case lastForwardedFor

    /// The entry `trustedProxies` positions from the right of
    /// `X-Forwarded-For`, for a chain of that many appending proxies (a CDN in
    /// front of a load balancer is two). `1` is the same as
    /// ``lastForwardedFor``. When the header has fewer entries, its first
    /// entry is used, since every proxy present wrote one; when it is absent,
    /// or `trustedProxies` is below 1, the socket's remote address is used.
    case forwardedFor(trustedProxies: Int)

    /// The socket's remote address only, ignoring `X-Forwarded-For`. Right when
    /// the app faces the internet directly.
    case remoteAddress

    /// Your own extraction, for a proxy that uses another header such as
    /// `CF-Connecting-IP` or `Fly-Client-IP`. Return `nil` when unknown.
    case custom(@Sendable (Request) -> String?)

    /// The client IP for `request` under this strategy.
    public func clientIP(for request: Request) -> String? {
        switch self {
        case .lastForwardedFor:
            return Self.forwardedEntry(in: request.headers, fromRight: 1)
                ?? request.remoteAddress?.ipAddress
        case .forwardedFor(let trustedProxies):
            guard trustedProxies >= 1 else { return request.remoteAddress?.ipAddress }
            return Self.forwardedEntry(in: request.headers, fromRight: trustedProxies)
                ?? request.remoteAddress?.ipAddress
        case .remoteAddress:
            return request.remoteAddress?.ipAddress
        case .custom(let extract):
            return extract(request)
        }
    }

    /// The `position`-th `X-Forwarded-For` entry counting from the right
    /// (1-based), or the first entry when there are fewer, without a port or
    /// brackets.
    static func forwardedEntry(in headers: HTTPHeaders, fromRight position: Int) -> String? {
        let entries = headers[.xForwardedFor]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return nil }
        let index = max(entries.count - position, 0)
        return hostOnly(entries[index])
    }

    /// `1.2.3.4:5678` to `1.2.3.4`, `[2600::5]:443` and `[2600::5]` to
    /// `2600::5`. Anything else, including a bare IPv6 address, is returned
    /// unchanged.
    static func hostOnly(_ entry: String) -> String {
        if entry.hasPrefix("[") {
            guard let close = entry.firstIndex(of: "]") else { return entry }
            let host = entry[entry.index(after: entry.startIndex)..<close]
            let rest = entry[entry.index(after: close)...]
            if rest.isEmpty { return String(host) }
            let port = rest.dropFirst()
            guard rest.first == ":", !port.isEmpty, port.allSatisfy(\.isASCIIDigit) else { return entry }
            return String(host)
        }
        guard entry.utf8.lazy.filter({ $0 == UInt8(ascii: ":") }).count == 1,
              let colon = entry.firstIndex(of: ":")
        else { return entry }
        let port = entry[entry.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy(\.isASCIIDigit) else { return entry }
        return String(entry[..<colon])
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Dashboard

extension BotKitConfiguration {

    /// The password-protected dashboard.
    public struct Dashboard: Sendable, Equatable {

        /// Mounted at `/admin/ai-bots`, credentials from `BOT_DASHBOARD_USER`
        /// and `BOT_DASHBOARD_PASSWORD`, buckets in UTC.
        public static let `default` = Dashboard()

        /// Set to `false` to never mount the dashboard, even with credentials
        /// configured. Recording is unaffected. Default `true`.
        public var isEnabled: Bool

        /// Where the dashboard is mounted, e.g. `/admin/ai-bots`. The sign-in
        /// and sign-out endpoints sit below it. Keep it under a path your
        /// `robots.txt` disallows. Default `/admin/ai-bots`.
        ///
        /// Every segment is taken literally and may use only letters, digits,
        /// `-`, `.`, `_` and `~`; `.` and `..` segments are not allowed. The
        /// root path `/` is refused, since the dashboard would take over the
        /// app's own `/`, `/login` and `/logout`. An invalid path makes
        /// `BotKit.configureRoutes(for:config:)` throw
        /// ``BotKitConfigurationError/invalidDashboardPath(_:reason:)``.
        public var path: String

        /// The sign-in username. Default `.environment("BOT_DASHBOARD_USER")`.
        /// The dashboard is only mounted when both this and ``password``
        /// resolve to non-empty values.
        public var username: BotKitConfigValue?

        /// The sign-in password. Default
        /// `.environment("BOT_DASHBOARD_PASSWORD")`.
        public var password: BotKitConfigValue?

        /// The heading and page title. Default `AI bot traffic`.
        public var title: String

        /// The time zone every hourly and daily bucket boundary is drawn in,
        /// on both the Swift and the SQL side of the query, for example
        /// `.americaNewYork` or `.europeParis`. Default ``BotKitTimeZone/utc``.
        public var timeZone: BotKitTimeZone

        /// The date ranges offered as filter pills, in display order. Default
        /// every ``BotDateRange`` case.
        public var dateRanges: [BotDateRange]

        /// The range shown when the URL names none (or an unoffered one).
        /// Default ``BotDateRange/week``.
        public var defaultDateRange: BotDateRange

        /// The session cookie's name, which must be an RFC 6265 token (visible
        /// ASCII, none of `()<>@,;:\"/[]?={}`, no spaces). An invalid name makes
        /// `BotKit.configureRoutes(for:config:)` throw
        /// ``BotKitConfigurationError/invalidSessionCookieName(_:)``. Default
        /// `botkit_dashboard`.
        public var sessionCookieName: String

        /// How long a sign-in lasts. Default twelve hours.
        public var sessionLifetime: TimeInterval

        /// When the session cookie is marked `Secure`. Default
        /// ``SecureCookiePolicy/automatic``.
        public var secureCookies: SecureCookiePolicy

        /// Failed sign-in throttling. Default five failures per client per
        /// fifteen minutes.
        public var loginLimit: LoginLimit

        /// Creates a dashboard configuration.
        public init(
            isEnabled: Bool = true,
            path: String = "/admin/ai-bots",
            username: BotKitConfigValue? = .environment("BOT_DASHBOARD_USER"),
            password: BotKitConfigValue? = .environment("BOT_DASHBOARD_PASSWORD"),
            title: String = "AI bot traffic",
            timeZone: BotKitTimeZone = .utc,
            dateRanges: [BotDateRange] = BotDateRange.allCases,
            defaultDateRange: BotDateRange = .week,
            sessionCookieName: String = "botkit_dashboard",
            sessionLifetime: TimeInterval = 12 * 60 * 60,
            secureCookies: SecureCookiePolicy = .automatic,
            loginLimit: LoginLimit = .default
        ) {
            self.isEnabled = isEnabled
            self.path = path
            self.username = username
            self.password = password
            self.title = title
            self.timeZone = timeZone
            self.dateRanges = dateRanges
            self.defaultDateRange = defaultDateRange
            self.sessionCookieName = sessionCookieName
            self.sessionLifetime = sessionLifetime
            self.secureCookies = secureCookies
            self.loginLimit = loginLimit
        }

        /// ``path`` with exactly one leading slash and no trailing slash.
        public var normalizedPath: String {
            "/" + pathComponents.joined(separator: "/")
        }

        /// The prefix links are built on: ``normalizedPath``, or empty when
        /// the dashboard is mounted at the root, so links never start `//`.
        var basePath: String {
            pathComponents.isEmpty ? "" : normalizedPath
        }

        /// ``path`` split into its non-empty components.
        var pathComponents: [String] {
            path.split(separator: "/").map(String.init)
        }

        /// ``dateRanges`` without repeats, or ``defaultDateRange`` alone when
        /// that is empty, so there is always exactly one pill per range.
        var offeredDateRanges: [BotDateRange] {
            guard !dateRanges.isEmpty else { return [defaultDateRange] }
            var seen = Set<BotDateRange>()
            return dateRanges.filter { seen.insert($0).inserted }
        }

        /// The range for a `?range=` value.
        func dateRange(forQuery raw: String?) -> BotDateRange {
            let offered = offeredDateRanges
            if let raw, let range = BotDateRange(rawValue: raw), offered.contains(range) {
                return range
            }
            return offered.contains(defaultDateRange) ? defaultDateRange : offered[0]
        }
    }

    /// Failed sign-in throttling, in memory and per process.
    public struct LoginLimit: Sendable, Equatable {

        /// Five failures per client and fifty in total per fifteen minutes.
        public static let `default` = LoginLimit()

        /// Failures allowed per client within ``window`` before that client's
        /// further attempts are refused. Values below 1 count as 1. Default
        /// `5`.
        public var maximumFailures: Int

        /// The sliding window failures are counted over. Default fifteen
        /// minutes.
        public var window: TimeInterval

        /// Failures allowed from every client together within ``window``.
        /// When reached, every sign-in is refused (the owner's included) until
        /// the window passes: a hard bound on guesses even when clients can
        /// rotate their apparent address. Never lower than
        /// ``maximumFailures``. Default `50`.
        public var globalMaximumFailures: Int

        /// Creates a login limit.
        public init(maximumFailures: Int = 5, window: TimeInterval = 15 * 60, globalMaximumFailures: Int = 50) {
            self.maximumFailures = maximumFailures
            self.window = window
            self.globalMaximumFailures = globalMaximumFailures
        }
    }

    /// When the dashboard's session cookie carries the `Secure` attribute.
    public enum SecureCookiePolicy: Sendable, Equatable {
        /// Secure when the request arrived over HTTPS, judged by
        /// `X-Forwarded-Proto: https` (for TLS terminated at a proxy) or by
        /// the request URL's scheme.
        case automatic
        /// Always secure.
        case always
        /// Never secure. Only for local development over plain HTTP.
        case never
    }
}

// MARK: - Values

/// A string setting that is either given directly or read from an environment
/// variable when the dashboard is configured.
///
/// A string literal is a direct value, so `username: "owner"` works. Surrounding
/// whitespace and newlines are trimmed (a secret pasted with a trailing newline
/// is the secret without it), and an empty or whitespace-only value, or an
/// unset variable, counts as not configured.
public enum BotKitConfigValue: Sendable, Equatable, ExpressibleByStringLiteral {
    /// Read from this environment variable when `BotKit.configureRoutes(for:config:)` runs, not when the configuration is built.
    case environment(String)
    /// This exact value.
    case value(String)

    /// Creates a direct value from a string literal.
    public init(stringLiteral value: String) {
        self = .value(value)
    }

    /// The configured value with surrounding whitespace and newlines
    /// trimmed, or `nil` when that leaves nothing or the variable is unset.
    public func resolve() -> String? {
        let raw: String?
        switch self {
        case .environment(let key): raw = Environment.get(key)
        case .value(let value): raw = value
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

// MARK: - Sites

/// One site the dashboard can filter to.
public struct BotDashboardSite: Sendable, Equatable {
    /// Matches what ``BotKitConfiguration/siteKey`` returns for this site's
    /// requests, and the stored `site_key` column.
    public let key: String
    /// Shown in the switcher, e.g. "Marketing site".
    public let name: String
    /// A small square logo shown beside the name in the switcher, as a URL or
    /// root-relative path. It must resolve on every host the dashboard is
    /// opened on, so a path served by `FileMiddleware` works well.
    public let logoPath: String?

    /// Creates a site entry.
    public init(key: String, name: String, logoPath: String? = nil) {
        self.key = key
        self.name = name
        self.logoPath = logoPath
    }
}
