# Configuring SwiftlyBotKit

Every option SwiftlyBotKit accepts, what it defaults to, and how to set it.

## Overview

All behaviour is set through one ``BotKitConfiguration`` value passed to ``BotKit/install(on:config:)`` or ``BotKit/configureRoutes(for:config:)``. Every property has a default, so the smallest setup is no configuration at all:

```swift
try BotKit.install(on: app)
```

That gives you one site, agent and referral recording, IP verification against the built-in feeds, the last `X-Forwarded-For` entry as the client IP, and a dashboard at `/admin/ai-bots/` that is mounted once `BOT_DASHBOARD_USER` and `BOT_DASHBOARD_PASSWORD` are set.

The options are grouped into nested structs, each with a `default` you can start from and adjust:

| Property | Type | Controls |
|---|---|---|
| ``BotKitConfiguration/siteKey`` | closure | Which site a request belongs to |
| ``BotKitConfiguration/sites`` | ``BotDashboardSite`` array | The dashboard's site switcher |
| ``BotKitConfiguration/signingSecret`` | ``BotKitConfigValue`` | Session cookies and IP hashes |
| ``BotKitConfiguration/recording`` | ``BotKitConfiguration/Recording`` | What gets recorded |
| ``BotKitConfiguration/detection`` | ``BotKitConfiguration/Detection`` | Which agents and assistants are recognised |
| ``BotKitConfiguration/verification`` | ``BotKitConfiguration/Verification`` | IP range checks |
| ``BotKitConfiguration/clientIP`` | ``ClientIPStrategy`` | Where the client IP comes from |
| ``BotKitConfiguration/dashboard`` | ``BotKitConfiguration/Dashboard`` | The dashboard |
| ``BotKitConfiguration/database`` | `DatabaseID?` | Which registered database holds the table (default: the app's default database) |

``BotKitConfiguration`` is a plain `Sendable` value. Build it however you like: with the memberwise initializer, or by starting from `BotKitConfiguration()` and assigning properties.

```swift
var config = BotKitConfiguration()
config.dashboard.path = "/internal/bots"
config.dashboard.timeZone = .americaNewYork
config.clientIP = .forwardedFor(trustedProxies: 2)
try BotKit.install(on: app, config: config)
```

#### Values from the environment

Credentials and the signing secret are ``BotKitConfigValue`` values. Each is either ``BotKitConfigValue/environment(_:)``, read from an environment variable, or ``BotKitConfigValue/value(_:)``, a literal. A string literal is a direct value, so `config.dashboard.username = "owner"` works.

Values are resolved when ``BotKit/configureRoutes(for:config:)`` runs, not when the struct is built. Surrounding whitespace and newlines are trimmed, so a secret pasted with a trailing newline works, and an empty or whitespace-only value counts the same as an unset variable.

```swift
// Defaults: read from BOT_DASHBOARD_USER, BOT_DASHBOARD_PASSWORD, BOT_DASHBOARD_SECRET.
var config = BotKitConfiguration()

// Your own variable names.
config.dashboard.username = .environment("ADMIN_USER")
config.dashboard.password = .environment("ADMIN_PASSWORD")
config.signingSecret = .environment("ADMIN_SESSION_SECRET")

// Explicit values, for a test or a secret you load from elsewhere.
config.dashboard.username = "owner"
config.dashboard.password = .value(try loadPasswordFromVault())
```

Avoid literal credentials in source that is committed anywhere.

### Sites

#### Single site

A single-site app sets nothing. Every row is filed under ``BotKitConfiguration/defaultSiteKey`` (`"default"`) and the switcher is hidden.

#### Multiple sites

``BotKitConfiguration/siteKey`` is a `@Sendable (Request) -> String` closure that returns the site a request belongs to. It is stored on every row as `site_key`. Return the same key your own host-based routing uses, so the dashboard splits traffic the way your router does.

``BotKitConfiguration/sites`` lists what the switcher offers. Each ``BotDashboardSite`` has a ``BotDashboardSite/key`` that must match what `siteKey` returns, a display ``BotDashboardSite/name``, and an optional ``BotDashboardSite/logoPath``. The switcher appears only with two or more sites.

```swift
let config = BotKitConfiguration(
    siteKey: { req in
        switch req.headers.first(name: .host)?.lowercased() {
        case "docs.example.com": return "docs"
        case "blog.example.com": return "blog"
        default: return "shop"
        }
    },
    sites: [
        BotDashboardSite(key: "shop", name: "Shop", logoPath: "/images/shop.svg"),
        BotDashboardSite(key: "docs", name: "Documentation", logoPath: "/images/docs.svg"),
        BotDashboardSite(key: "blog", name: "Blog", logoPath: "/images/blog.svg"),
    ]
)
```

A logo must resolve on every host the dashboard is opened on, so a root-relative path served by `FileMiddleware` from each domain works well.

### Signing secret

``BotKitConfiguration/signingSecret`` is the HMAC key behind the dashboard's session cookie and the keyed hash stored in place of each client IP. It defaults to `.environment("BOT_DASHBOARD_SECRET")`.

When it resolves to nothing, a random key is generated per process and a warning is logged. Sessions then end at every restart and are not shared between instances, and IP hashes written by one process do not match those written by the next, which breaks distinct-visitor counts across restarts. Set it in every deployed environment, and keep it stable. Changing it has the same effect once.

### Recording

``BotKitConfiguration/Recording`` decides which requests are written.

| Option | Default | Effect |
|---|---|---|
| ``BotKitConfiguration/Recording/recordsAgents`` | `true` | Record requests whose user agent matches a known AI agent |
| ``BotKitConfiguration/Recording/recordsReferrals`` | `true` | Record humans arriving with a `Referer` from a known AI assistant |
| ``BotKitConfiguration/Recording/ignoredFileExtensions`` | ``BotKitConfiguration/Recording/defaultIgnoredFileExtensions`` | Lowercased extensions, without the dot, that are never recorded |
| ``BotKitConfiguration/Recording/excludedPathPrefixes`` | empty | Path prefixes that are never recorded, compared as plain strings |
| ``BotKitConfiguration/Recording/maximumPendingWrites`` | `256` | Recording writes allowed in flight; beyond it, visits are dropped with a sampled warning |

Excluded prefixes are plain string prefixes, not path segments: `/health` also excludes `/health-insurance/`. End a prefix with `/` (`/health/`) to exclude only what sits below it.

The default ignored extensions are images, fonts, stylesheets, scripts, video, PDF and ZIP. `.txt` and `.xml` are deliberately absent, because a crawler fetching `robots.txt` or `sitemap.xml` is a real signal. The dashboard's own path is always excluded, whether or not the dashboard is mounted.

When both `recordsAgents` and `recordsReferrals` are `false`, ``BotKitConfiguration/Recording/isEnabled`` is `false` and the middleware is not installed at all. The dashboard can still be mounted to read existing rows.

```swift
config.recording.excludedPathPrefixes = ["/healthz", "/api/internal"]
config.recording.ignoredFileExtensions.insert("webmanifest")
config.recording.recordsReferrals = false
```

### Detection

``BotKitConfiguration/Detection`` decides what counts as an AI agent or an AI assistant referral.

| Option | Default | Effect |
|---|---|---|
| ``BotKitConfiguration/Detection/includesBuiltInAgents`` | `true` | Match against ``AIAgentCatalog`` |
| ``BotKitConfiguration/Detection/customAgents`` | empty | Extra ``AIAgent`` entries; one with a built-in token replaces it |
| ``BotKitConfiguration/Detection/includesBuiltInReferrers`` | `true` | Match against ``LLMReferrer/builtInPlatforms`` |
| ``BotKitConfiguration/Detection/customReferrers`` | empty | Extra ``LLMReferrer/Platform`` entries; one with a built-in host suffix replaces it |

```swift
config.detection.customAgents = [
    AIAgent(token: "AcmeResearchBot", purpose: .agent, operatorName: "Acme", respectsRobotsTxt: true),
]
config.detection.customReferrers = [
    LLMReferrer.Platform(hostSuffix: "chat.deepseek.com", name: "DeepSeek"),
]
```

See <doc:CustomAgents> and <doc:AIReferrals>.

### Verification

``BotKitConfiguration/Verification`` controls the IP range checks described in <doc:IPVerification>.

| Option | Default | Effect |
|---|---|---|
| ``BotKitConfiguration/Verification/isEnabled`` | `true` | When `false`, no feed is fetched and every agent is ``BotVerification/unverified`` |
| ``BotKitConfiguration/Verification/feeds`` | ``CrawlerRangeFeed/defaults`` | The published range feeds and the agents each covers |
| ``BotKitConfiguration/Verification/refreshInterval`` | 12 hours | How long fetched ranges are trusted before a background refresh |

#### Disabling verification

```swift
config.verification.isEnabled = false
```

Do this in tests, in development without network access, or when outbound requests to the vendor feeds are not allowed. The dashboard's verified share then reads as a dash, and nothing is ever marked spoofed.

#### Adding a feed

```swift
config.verification.feeds = CrawlerRangeFeed.defaults + [
    CrawlerRangeFeed(url: "https://acme.example/crawler-ranges.json", agentTokens: ["AcmeResearchBot"]),
]
```

### Client IP

``BotKitConfiguration/clientIP`` is a ``ClientIPStrategy``: ``ClientIPStrategy/lastForwardedFor`` by default, or ``ClientIPStrategy/forwardedFor(trustedProxies:)``, ``ClientIPStrategy/remoteAddress`` or ``ClientIPStrategy/custom(_:)``. The client IP feeds IP verification, the stored IP hash, and the key of the sign-in throttle, so getting it wrong has security consequences. Read <doc:ClientIPAndProxies> before changing it.

```swift
config.clientIP = .forwardedFor(trustedProxies: 2)
```

### Dashboard

``BotKitConfiguration/Dashboard`` controls the password-protected pages.

| Option | Default | Effect |
|---|---|---|
| ``BotKitConfiguration/Dashboard/isEnabled`` | `true` | `false` never mounts it, even with credentials |
| ``BotKitConfiguration/Dashboard/path`` | `/admin/ai-bots` | Mount point; `login` and `logout` sit below it |
| ``BotKitConfiguration/Dashboard/username`` | `.environment("BOT_DASHBOARD_USER")` | Sign-in username |
| ``BotKitConfiguration/Dashboard/password`` | `.environment("BOT_DASHBOARD_PASSWORD")` | Sign-in password |
| ``BotKitConfiguration/Dashboard/title`` | `AI bot traffic` | Heading and page title |
| ``BotKitConfiguration/Dashboard/timeZone`` | ``BotKitTimeZone/utc`` | Where hourly and daily bucket boundaries fall |
| ``BotKitConfiguration/Dashboard/dateRanges`` | every ``BotDateRange`` | Filter pills, in order |
| ``BotKitConfiguration/Dashboard/defaultDateRange`` | ``BotDateRange/week`` | Range shown when the URL names none |
| ``BotKitConfiguration/Dashboard/sessionCookieName`` | `botkit_dashboard` | Session cookie name |
| ``BotKitConfiguration/Dashboard/sessionLifetime`` | 12 hours | How long a sign-in lasts |
| ``BotKitConfiguration/Dashboard/secureCookies`` | ``BotKitConfiguration/SecureCookiePolicy/automatic`` | When the cookie is `Secure` |
| ``BotKitConfiguration/Dashboard/loginLimit`` | 5 failures per client, 50 in total, per 15 minutes | Failed sign-in throttle |

The dashboard is mounted only when both ``BotKitConfiguration/Dashboard/username`` and ``BotKitConfiguration/Dashboard/password`` resolve to non-empty values. ``BotKitConfiguration/Dashboard/normalizedPath`` gives the path with one leading slash and no trailing slash, whatever form you wrote it in.

#### Custom path and time zone

```swift
config.dashboard.path = "/internal/ai-traffic"
config.dashboard.title = "Crawler traffic"
config.dashboard.timeZone = .europeParis
config.dashboard.dateRanges = [.week, .month, .quarter]
config.dashboard.defaultDateRange = .month
```

Keep the path under something your `robots.txt` disallows. Both dashboard pages also send `X-Robots-Tag: noindex, nofollow`.

Each path segment is taken literally and may use only letters, digits, `-`, `.`, `_` and `~`. The root path `/` is refused (the dashboard would take over the app's own `/`, `/login` and `/logout`), and so are `.` and `..` segments, a segment starting with `:` or `*`, spaces, `?`, `%` and non-ASCII characters. ``BotKit/configureRoutes(for:config:)`` throws ``BotKitConfigurationError/invalidDashboardPath(_:reason:)`` with the reason, rather than mounting a dashboard that cannot be reached.

``BotKitTimeZone`` has a case for every canonical IANA zone, named after its identifier (`America/New_York` is `.americaNewYork`), so the zone comes from autocomplete rather than a string. Legacy spellings such as `.asiaCalcutta` are deprecated aliases of the canonical case (`.asiaKolkata`), and ``BotKitTimeZone/init(identifier:)`` maps legacy names the same way. ``BotKitTimeZone/custom(_:)`` takes any Foundation `TimeZone`, including a fixed offset such as `TimeZone(secondsFromGMT: 3600)`: bucketing happens in Swift and PostgreSQL never sees the zone. A zone the host's tz database lacks falls back to UTC; see <doc:TheDashboard>.

#### Sessions and sign-in

```swift
config.dashboard.sessionCookieName = "ops_session"
config.dashboard.sessionLifetime = 8 * 60 * 60
config.dashboard.secureCookies = .always
config.dashboard.loginLimit = .init(maximumFailures: 3, window: 30 * 60)
```

``BotKitConfiguration/SecureCookiePolicy/automatic`` marks the cookie `Secure` when `X-Forwarded-Proto` is `https` or the request URL's scheme is https, which covers TLS terminated at a proxy. Use ``BotKitConfiguration/SecureCookiePolicy/never`` only for local development over plain HTTP.

The cookie name must be an RFC 6265 token: visible ASCII without spaces or any of `()<>@,;:\"/[]?={}`. Anything else throws ``BotKitConfigurationError/invalidSessionCookieName(_:)``, since the browser would not send the cookie back as set.

``BotKitConfiguration/LoginLimit`` counts failures in memory, per process, keyed on a hash of the client IP. With several instances, each keeps its own count. ``BotKitConfiguration/LoginLimit/globalMaximumFailures`` (default 50) caps failures from every client together; when it trips, every sign-in is refused until the window passes.

```swift
config.dashboard.loginLimit = .init(maximumFailures: 3, window: 30 * 60, globalMaximumFailures: 20)
```

#### Disabling the dashboard

```swift
config.dashboard.isEnabled = false
```

Recording continues and the dashboard's path is still excluded from recording. Leaving the credentials unset has the same effect, with a warning in the log at boot.

## See Also

- <doc:ClientIPAndProxies>
- <doc:Deployment>
