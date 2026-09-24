# SwiftlyBotKit

AI agent traffic tracking for [Vapor](https://vapor.codes) apps, with a
password-protected dashboard that reads it back.

Add it to a Vapor app and every request is checked against a catalog of 175
known AI agents. Matches are recorded in PostgreSQL along with what the agent
was doing (training a model, indexing for AI search, or fetching a page because
someone asked an assistant a question) and whether its IP address really
belongs to the operator it claims. Visitors who arrive from ChatGPT, Claude,
Perplexity and other assistants are recorded too.

## Why

AI bot trackers exist for WordPress, Next.js and Cloudflare. There was nothing
for server-side Swift. The hosted alternatives either charge per domain or
require moving your DNS to a specific provider. A Vapor app already knows
which site a request belongs to and already has a database, so the tracking
can live in the app itself.

A raw count of "AI bot hits" says little. What matters is the breakdown:
a model training crawl and a person asking ChatGPT about your product are very
different events, and a forged `ChatGPT-User` header is different again. That
breakdown is what this package records and shows.

## Features

- Classifies every request against a built-in catalog of 175 AI agents,
  generated from the community [ai.robots.txt](https://github.com/ai-robots-txt/ai.robots.txt) list.
- Records what each agent was doing: `training`, `aiSearch`, `userTriggered`,
  `agent` or `scraper`.
- Verifies OpenAI, Anthropic and Perplexity agents against the IP ranges those
  operators publish, and stores each visit as `verified`, `unverified` or
  `spoofed`.
- Records human visitors referred by 16 AI assistant hosts (ChatGPT, Claude,
  Perplexity, Gemini, Copilot, Grok, Le Chat and others).
- Never delays a response: classification is one in-memory lookup, and the
  database write happens in a detached task.
- Never records ordinary human traffic or static assets. `robots.txt` and
  `sitemap.xml` are recorded on purpose.
- Stores a keyed hash of the client IP, never the address itself.
- Multi-site aware: one app serving several domains gets one dashboard with a
  site switcher.
- Server-rendered dashboard with no JavaScript and no CDN: summary tiles, a
  stacked time series, top agents, top pages and AI referrals, filtered by
  24 hours, 7, 30 or 90 days.
- Custom agents and referrer hosts can be added, and built-in ones
  reclassified, through configuration.

## Requirements

- Swift 6.0 or later
- macOS 14 or later, or Linux
- Vapor 4 and Fluent
- PostgreSQL at runtime. The migration creates PostgreSQL enum types and the
  dashboard uses PostgreSQL-specific SQL, so SQLite and MySQL are not
  supported. The package does not depend on the Postgres driver; your app
  brings its own (`fluent-postgres-driver`).

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Swiftly-Developed/SwiftlyBotKit.git", from: "0.1.0"),
],
```

and the product to your app target:

```swift
.product(name: "SwiftlyBotKit", package: "SwiftlyBotKit"),
```

## Quick start

In `configure.swift`, with a PostgreSQL database configured as the default:

```swift
import Fluent
import FluentPostgresDriver
import SwiftlyBotKit
import Vapor

public func configure(_ app: Application) async throws {
    app.databases.use(
        .postgres(configuration: try SQLPostgresConfiguration(
            url: Environment.get("DATABASE_URL") ?? "postgres://vapor:vapor@localhost:5432/vapor"
        )),
        as: .psql
    )

    // Add FileMiddleware first, so the recorded status code is the one the
    // client actually received.
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Registers the migration, installs the tracking middleware and mounts
    // the dashboard when credentials are set.
    try BotKit.install(on: app)

    try await app.autoMigrate()

    // your routes
}
```

Then set the dashboard credentials and a signing secret:

```bash
export BOT_DASHBOARD_USER=owner
export BOT_DASHBOARD_PASSWORD='a long random password'
export BOT_DASHBOARD_SECRET="$(openssl rand -hex 32)"
```

Open `/admin/ai-bots/` and sign in. Without the two credential variables the
dashboard is not mounted (the path answers 404) and recording continues.

`BotKit.install(on:config:)` is shorthand for `BotKit.configure(for:database:)` (the
migration) followed by `BotKit.configureRoutes(for:config:)` (the middleware
and dashboard). Call the two separately if your app registers migrations and
routes in different places, and do not call `install` as well, or the
migration is registered twice.

Recording writes to `app.db`, the app's default database.

## What gets recorded

Each recorded row is classified on three axes.

**1. Which agent.** The user agent is matched against the catalog, longest
token first, because `Applebot-Extended` contains `Applebot` and the two mean
different things.

**2. What it was doing.** `AIAgentPurpose`:

| Purpose | Meaning | Examples |
|---|---|---|
| `training` | Collecting content to train a model. No attribution. | GPTBot, ClaudeBot, CCBot, Google-Extended |
| `aiSearch` | Indexing the page so it can be cited in AI answers. | OAI-SearchBot, Claude-SearchBot, PerplexityBot |
| `userTriggered` | A person asked an assistant something, and it fetched the page to answer. | ChatGPT-User, Claude-User, Perplexity-User |
| `agent` | An autonomous or coding agent working on a task. | Devin |
| `scraper` | Harvesting for datasets, resale or image corpora. | Diffbot, ImageSift |

The operators draw these lines themselves by using separate user agents for
each job, so the split is theirs rather than a guess. The upstream list
describes purposes in free text, so the mapping onto these five cases is this
package's own, maintained by the catalog generator.

**3. Real or forged.** `BotVerification`:

| Value | Meaning |
|---|---|
| `verified` | The source IP is inside the ranges the operator publishes for that agent. |
| `unverified` | The operator publishes no list to check against, so the user agent is taken at its word. Most of the long tail. |
| `spoofed` | The operator does publish ranges and the source IP is not in them. Kept, because it is a security signal. |
| `notApplicable` | An AI referral row (a human visitor), where there is nothing to verify. |

A meaningful share of requests claiming a well-known AI crawler are forged,
and `ChatGPT-User` is among the most impersonated, so verification matters most
for the bucket you care about most.

The default feeds reflect how each operator publishes. OpenAI publishes one
list per agent, so a `ChatGPT-User` hit is checked against the ChatGPT-User
ranges specifically. Anthropic publishes a single list for `ClaudeBot`,
`Claude-User` and `Claude-SearchBot`, so a verified Claude hit proves the
request came from Anthropic, and the user agent says which of the three it
was. Google and Common Crawl expect forward-confirmed reverse DNS instead of a
range list, which would cost a DNS round trip per request, so their agents are
stored as `unverified`.

**AI referrals.** A request whose `Referer` is a known assistant host
(`chatgpt.com`, `claude.ai`, `perplexity.ai` and others in
`LLMReferrer.builtInPlatforms`) is stored in the same table with the platform
name set and no agent. These are people who clicked a link in an AI answer.
Consent-gated analytics often miss them.

## Configuration

Everything is set through `BotKitConfiguration`. Every option has a default,
so `BotKitConfiguration()` is a working single-site setup. The options are
grouped into nested structs, each with a `.default` you can copy and adjust:

```swift
var config = BotKitConfiguration()
config.dashboard.path = "/internal/bots"
config.dashboard.timeZone = .americaNewYork
config.clientIP = .forwardedFor(trustedProxies: 2)
config.recording.excludedPathPrefixes = ["/healthz"]
try BotKit.install(on: app, config: config)
```

### Top level

| Option | Default | Purpose |
|---|---|---|
| `siteKey` | every request is `"default"` | `(Request) -> String` naming the site a request belongs to. Stored on every row. |
| `sites` | `[]` | `BotDashboardSite` entries for the dashboard's site switcher. Shown only with two or more. |
| `signingSecret` | `.environment("BOT_DASHBOARD_SECRET")` | HMAC key for session cookies and IP hashes. |
| `clientIP` | `.lastForwardedFor` | How the client IP is read. See [Security](#security). |
| `database` | `nil` | Which registered database holds the table. `nil` is the app's default database, so no separate database is needed. |

### `recording`

| Option | Default | Purpose |
|---|---|---|
| `recordsAgents` | `true` | Record requests from known AI agents. |
| `recordsReferrals` | `true` | Record humans arriving from AI assistants. |
| `ignoredFileExtensions` | `Recording.defaultIgnoredFileExtensions` | Extensions never recorded: images, fonts, CSS, JS, video, `pdf`, `zip`. `txt` and `xml` are not in the list. |
| `excludedPathPrefixes` | `[]` | Path prefixes never recorded. The dashboard's own path is always excluded. |

When both `recordsAgents` and `recordsReferrals` are `false`, the middleware
is not installed.

### `detection`

| Option | Default | Purpose |
|---|---|---|
| `includesBuiltInAgents` | `true` | Match against the built-in `AIAgentCatalog`. |
| `customAgents` | `[]` | Extra `AIAgent` entries. One whose token equals a built-in token (case-insensitively) replaces it. |
| `includesBuiltInReferrers` | `true` | Match referrers against `LLMReferrer.builtInPlatforms`. |
| `customReferrers` | `[]` | Extra `LLMReferrer.Platform` entries. One with the same host suffix as a built-in entry replaces it. |

### `verification`

| Option | Default | Purpose |
|---|---|---|
| `isEnabled` | `true` | When `false`, no feed is fetched and every agent visit is stored as `unverified`. |
| `feeds` | `CrawlerRangeFeed.defaults` | The range feeds and the agent tokens each one vouches for. Six feeds from OpenAI, Anthropic and Perplexity. |
| `refreshInterval` | 12 hours | How long fetched ranges are trusted before a background refresh. Requests never wait on a refresh once ranges are cached. |

### `dashboard`

| Option | Default | Purpose |
|---|---|---|
| `isEnabled` | `true` | Set to `false` to never mount the dashboard. Recording is unaffected. |
| `path` | `/admin/ai-bots` | Mount point. Sign-in and sign-out sit below it. |
| `username` | `.environment("BOT_DASHBOARD_USER")` | Sign-in username. |
| `password` | `.environment("BOT_DASHBOARD_PASSWORD")` | Sign-in password. |
| `title` | `AI bot traffic` | Heading and page title. |
| `timeZone` | `.utc` | Zone every hourly and daily bucket is drawn in. A `BotKitTimeZone` case per IANA zone, such as `.americaNewYork`. |
| `dateRanges` | all `BotDateRange` cases | Range pills offered: `.day` (24h), `.week` (7d), `.month` (30d), `.quarter` (90d). |
| `defaultDateRange` | `.week` | Range shown when the URL names none. |
| `sessionCookieName` | `botkit_dashboard` | Session cookie name. |
| `sessionLifetime` | 12 hours | How long a sign-in lasts. |
| `secureCookies` | `.automatic` | When the cookie is `Secure`: `.automatic`, `.always` or `.never`. |
| `loginLimit` | 5 failures per 15 minutes | `LoginLimit(maximumFailures:window:)`, per client, in memory. |

The dashboard is mounted only when both `username` and `password` resolve to
non-empty values. For a zone the `BotKitTimeZone` list lacks, use
`.custom(TimeZone(identifier: "...")!)` with an IANA identifier; avoid
fixed-offset `TimeZone(secondsFromGMT:)` zones, whose `GMT+0100` style names
PostgreSQL reads with the opposite sign.

### Values from the environment or code

`username`, `password` and `signingSecret` are `BotKitConfigValue`: either
`.environment("NAME")` or `.value("...")`. A string literal is a direct value.
They are resolved when `configureRoutes` runs, and an empty value or unset
variable counts as not configured.

```swift
config.dashboard.username = "owner"
config.dashboard.password = .environment("MY_APP_BOTS_PASSWORD")
```

### Multiple sites

An app that serves several domains should return the same key its own
host-based routing uses:

```swift
let config = BotKitConfiguration(
    siteKey: { req in
        req.headers.first(name: .host)?.hasPrefix("blog.") == true ? "blog" : "main"
    },
    sites: [
        BotDashboardSite(key: "main", name: "Main site"),
        BotDashboardSite(key: "blog", name: "Blog", logoPath: "/images/blog-logo.svg"),
    ]
)
```

The dashboard is mounted on every host. With no `?site=` in the URL it opens on
the site of the domain it was opened on; `?site=all` shows every site.

### Custom agents and referrers

```swift
config.detection.customAgents = [
    AIAgent(token: "ExampleBot", purpose: .aiSearch, operatorName: "Example Inc."),
]
config.detection.customReferrers = [
    LLMReferrer.Platform(hostSuffix: "chat.example.com", name: "Example Chat"),
]
```

## Environment variables

These are the defaults. Each can be renamed or replaced with a value in code
through `BotKitConfigValue`.

| Variable | Used for | If unset |
|---|---|---|
| `BOT_DASHBOARD_USER` | Dashboard username | Dashboard not mounted. Recording continues. A warning is logged. |
| `BOT_DASHBOARD_PASSWORD` | Dashboard password | Dashboard not mounted. Recording continues. A warning is logged. |
| `BOT_DASHBOARD_SECRET` | Session cookie signing and IP hashing | A random key per process. Sign-ins end at every restart, and IP hashes stop matching earlier rows. A warning is logged. |

## Security

**Client IP.** Verification is only as honest as the IP address it checks.
`X-Forwarded-For` is a list each proxy appends to, so its first entry is
whatever the client chose to send. Trusting it would let anyone send a
`ChatGPT-User` user agent with an OpenAI address in the header and be counted
as `verified`. Pick the `ClientIPStrategy` that matches your deployment:

| Strategy | Use when |
|---|---|
| `.lastForwardedFor` (default) | Exactly one trusted proxy or load balancer appends the address it saw: Heroku, most PaaS routers, a single nginx. |
| `.forwardedFor(trustedProxies: n)` | A chain of `n` appending proxies, such as a CDN in front of a load balancer (`2`). |
| `.remoteAddress` | The app faces the internet directly. |
| `.custom { req in ... }` | Your proxy puts the client address in another header, such as `CF-Connecting-IP` or `Fly-Client-IP`. |

If the strategy does not match your proxies, `verified` and `spoofed` counts
cannot be trusted, and neither can the login limiter, which is keyed on the
same address.

**Dashboard credentials.** Use a long random password. Failed sign-ins are
limited per client IP (five per fifteen minutes by default), in memory and per
process, so several instances each keep their own count. Username and password
are always both compared. Keep `dashboard.path` under a path your `robots.txt`
disallows; both dashboard pages also send `X-Robots-Tag: noindex`.

**Signing secret.** Set `BOT_DASHBOARD_SECRET` in production to a long random
value, and keep it stable. It signs the stateless session cookie, so anyone who
has it can mint a session. It also keys the IP hash, so changing it means new
rows no longer match old ones when counting distinct clients. The session
cookie is `Secure` over HTTPS by default, including behind a proxy that sets
`X-Forwarded-Proto: https`.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Keeping the catalog fresh

New AI agents appear constantly, and an agent the catalog does not know is
not recorded at all, so the drift is easy to miss. Regenerate the catalog
roughly every quarter, from the package root:

```bash
python3 Scripts/generate-ai-agent-catalog.py
```

The script downloads the current [ai.robots.txt](https://github.com/ai-robots-txt/ai.robots.txt)
list and rewrites `Sources/SwiftlyBotKit/Catalog/AIAgentCatalogData.swift`.
It prints how many agents were classified by the hand-audited override table,
by upstream's taxonomy labels, by a keyword guess, and by the unclassified
fallback. Review the "unclassified fallback" count, and the diff of the
generated file, before committing.

This repository also runs the script on a quarterly schedule and opens a pull
request when the catalog changes, so updating the package picks up new agents.
Between releases, add or reclassify agents with
`detection.customAgents`.

## Documentation

- [API documentation](https://swiftpackageindex.com/Swiftly-Developed/SwiftlyBotKit/documentation/swiftlybotkit)
- [Tutorial: Meet SwiftlyBotKit](https://swiftpackageindex.com/Swiftly-Developed/SwiftlyBotKit/tutorials/meetswiftlybotkit)

## Examples

[`Examples/QuickStart`](Examples/QuickStart) is a minimal Vapor app with
SwiftlyBotKit installed against a local PostgreSQL database.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Missing an AI agent? Open a
[new agent issue](https://github.com/Swiftly-Developed/SwiftlyBotKit/issues/new?template=new_agent.md).

## License

MIT. See [LICENSE](LICENSE).

The built-in agent catalog is generated from
[ai-robots-txt/ai.robots.txt](https://github.com/ai-robots-txt/ai.robots.txt),
which is also MIT licensed. The purpose classification is this package's own.

---

Built and used in production by [Swiftly Developed](https://swiftly-developed.com).
