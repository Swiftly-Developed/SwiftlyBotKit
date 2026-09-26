<p align="center">
  <img src=".github/assets/logo.svg" width="128" height="128" alt="SwiftlyBotKit logo: a bot above a rising bar chart">
</p>

# SwiftlyBotKit

AI agent traffic tracking for [Vapor](https://vapor.codes) apps, with a
password-protected dashboard that reads it back.

Add it to a Vapor app and every request is checked against a catalog of 167
known AI agents. Matches are recorded in PostgreSQL along with what the agent
was doing (training a model, indexing for AI search, or fetching a page because
someone asked an assistant a question) and whether its IP address really
belongs to the operator it claims. Visitors who arrive from ChatGPT, Claude,
Perplexity and other assistants are recorded too.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/dashboard-dark.png">
  <img alt="The SwiftlyBotKit dashboard: headline tiles for AI agent visits, user-triggered visits, verified share, spoofed requests and AI referrals, above a daily chart of visits stacked by purpose." src=".github/assets/dashboard-light.png">
</picture>

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

- Classifies every request against a built-in catalog of 167 AI agents,
  generated from the community [ai.robots.txt](https://github.com/ai-robots-txt/ai.robots.txt) list.
- Records what each agent was doing: `training`, `aiSearch`, `userTriggered`,
  `agent` or `scraper`.
- Verifies OpenAI, Anthropic and Perplexity agents against the IP ranges those
  operators publish, and stores each visit as `verified`, `unverified` or
  `spoofed`.
- Records human visitors referred by AI assistants (ChatGPT, Claude,
  Perplexity, Gemini, Copilot, Grok, Le Chat and others), on the web and from
  their Android apps.
- Never delays a response: classification is one in-memory lookup, and the
  database write happens in a detached task.
- Never records ordinary human traffic or static assets. `robots.txt` and
  `sitemap.xml` are recorded on purpose.
- Optional anonymous page views: how often people read each page, stored as
  plain counters per page and quarter-hour, with no cookie, no IP address and
  no user agent, on a second dashboard tab beside the AI agent numbers.
- Stores a keyed hash of the client IP, never the address itself.
- Multi-site aware: one app serving several domains gets one dashboard with a
  site switcher.
- Server-rendered dashboard with no JavaScript and no CDN: summary tiles, a
  stacked time series, top agents, top pages and AI referrals, filtered by
  24 hours, 7, 30 or 90 days.
- CSV export from the dashboard: any date range, per day, ISO week or month,
  totals, or raw rows, for AI agents, AI referrals, people or all of them,
  broken down by site, page, agent, purpose, verification or assistant.
- Custom agents and referrer hosts can be added, and built-in ones
  reclassified, through configuration.

## The dashboard

Server-rendered HTML and inline SVG: no JavaScript, no CDN, and it follows the
system light or dark setting. Below the headline tiles and the chart, it
breaks traffic down by agent (with how much of it was verified), by page (with
the user-triggered share), and by AI assistant for human referrals. With
[page views](#page-views-optional) on, a second tab shows how often people read
each page, with the AI agent requests for the same page beside it.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/breakdowns-dark.png">
  <img alt="Dashboard breakdowns: top agents with operator, verified count and a robots.txt flag; most-read pages split into user-triggered and crawled; visitors from AI assistants." src=".github/assets/breakdowns-light.png">
</picture>

On a phone the tiles pair up and the chart scrolls sideways rather than
shrinking its labels:

<img alt="The dashboard at phone width." src=".github/assets/mobile-light.png" width="320">

Screenshots are from [`Examples/QuickStart`](Examples/QuickStart) with sample
data.

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

`BotKit.install(on:config:)` is shorthand for `BotKit.configure(for:database:pageViews:)` (the
migration) followed by `BotKit.configureRoutes(for:config:)` (the middleware
and dashboard). Call the two separately if your app registers migrations and
routes in different places. Calling `install` as well throws
`BotKitConfigurationError.alreadyInstalled` at boot, so a double setup cannot
record every hit twice.

Recording writes to `app.db`, the app's default database.

## What gets recorded

Each recorded row is classified on three axes.

**1. Which agent.** The user agent is matched against the catalog. A token
counts only as a whole word (`Spider` does not match `Baiduspider`), and the
longest matching token wins, because `Applebot-Extended` contains `Applebot`
and the two mean different things. Between equally long tokens, a custom agent
beats a built-in one, then the token earliest in the header wins.

**2. What it was doing.** `AIAgentPurpose`:

| Purpose | Meaning | Examples |
|---|---|---|
| `training` | Collecting content to train a model. No attribution. | GPTBot, ClaudeBot, CCBot, Google-Extended |
| `aiSearch` | Indexing the page so it can be cited in AI answers. | OAI-SearchBot, Claude-SearchBot, PerplexityBot |
| `userTriggered` | A person asked an assistant something, and it fetched the page to answer. | ChatGPT-User, Claude-User, Perplexity-User |
| `agent` | An autonomous or coding agent working on a task. | Devin |
| `scraper` | Harvesting for datasets, resale or image corpora. | Brightbot, FirecrawlAgent |

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
`LLMReferrer.builtInPlatforms`), or an assistant's Android app
(`android-app://com.openai.chatgpt/`), is stored in the same table with the
platform name set and no agent. These are people who clicked a link in an AI
answer. Consent-gated analytics often miss them. Developer and company sites
(`platform.openai.com`, `docs.claude.com`, `x.ai`) are deliberately not on the
list: a link followed from API docs is not an assistant referral.

## Page views (optional)

Off by default. Turned on, every successful HTML page served to a browser adds
one to a counter for its site, path and quarter-hour, and the dashboard gains a
**Page views** tab at `/admin/ai-bots/pages/`: total reads, pages read, a chart,
and the most-read pages. A filter switches between **People**, **AI agents**
(successful page requests only; robots.txt, sitemaps and errors stay on the AI
agents tab) and **Combined**, which stacks the two.

```swift
var config = BotKitConfiguration()
config.pageViews.isEnabled = true
try BotKit.install(on: app, config: config)
```

If you call `BotKit.configure(for:)` and `configureRoutes(for:config:)`
separately, pass `pageViews: true` to `configure` too, so the table is created;
`configureRoutes` throws `BotKitConfigurationError.pageViewsNotMigrated` if you
forget.

The table, `page_view_counts`, has four columns: `site_key`, `path`,
`bucket_start` and `views`. Nothing about the visitor is stored anywhere: no
cookie, no IP address or hash, no user agent, no referrer, no per-visit
timestamp. Views are summed in memory and only the sums are written, every ten
seconds and at shutdown. So these are **views, not visitors**. Quarter-hours,
not hours, because every time zone's offset is a whole number of quarter-hours,
so a view always lands on the right local day.

A view counts when the request is a `GET` answered `2xx` with an HTML body,
from a user agent that starts `Mozilla/`, is not in the AI agent catalog and
does not call itself a bot, crawler, headless browser, monitor, link preview or
HTTP library. HTMX swaps, prefetches and prerenders, subresource fetches
(`Sec-Fetch-Dest` other than `document`), recording's excluded paths and the
dashboard are skipped.

| Option | Default | Purpose |
|---|---|---|
| `isEnabled` | `false` | Count page views and show the tab. |
| `flushInterval` | 10 seconds | How often the in-memory counts are written, in one statement. A killed process loses at most this much. |
| `maximumPendingCounters` | `10_000` | Distinct site, path and quarter-hour counters held between writes. Beyond it new ones are dropped with a sampled warning. |

## Exporting to CSV

The dashboard's **Export** tab, at `/admin/ai-bots/export/`, downloads a CSV.
No configuration: it is there whenever the dashboard is. You choose:

- **Period**: 24 hours, 7, 30 or 90 days, or custom dates (whole local days,
  both included).
- **Level of detail**: raw rows, per day, per ISO week, per month, or totals.
- **Include**: AI agents, AI referrals and people (with page views on), in any
  combination. Optionally AI agents' page reads only, to compare like for like
  with people.
- **Break down by**: site, page, agent and operator, purpose, verification,
  referring assistant.

Every line carries an `audience` column (`ai_agent`, `ai_referral`, `people`),
so a combined file pivots cleanly. Grouped exports have `period`,
`period_start` and `period_end` (local time with its offset), the chosen
breakdown columns and `count`. Raw AI lines are one request each; raw people
lines are the quarter-hour counters, the finest that is stored. IP hashes and
user agents are never exported, and values a spreadsheet would run as a
formula are escaped. Raw exports are streamed, so memory stays flat however
long the period.

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
| `sites` | `[]` | `BotDashboardSite` entries for the dashboard's site switcher. Shown only with two or more. The key `all` is reserved for the all-sites view and throws; a repeated key is logged and only its first entry is offered. |
| `signingSecret` | `.environment("BOT_DASHBOARD_SECRET")` | HMAC key for session cookies and IP hashes. |
| `clientIP` | `.lastForwardedFor` | How the client IP is read. See [Security](#security). |
| `database` | `nil` | Which registered database holds the table. `nil` is the app's default database, so no separate database is needed. |

### `recording`

| Option | Default | Purpose |
|---|---|---|
| `recordsAgents` | `true` | Record requests from known AI agents. |
| `recordsReferrals` | `true` | Record humans arriving from AI assistants. |
| `ignoredFileExtensions` | `Recording.defaultIgnoredFileExtensions` | Extensions never recorded: images, fonts, CSS, JS, video, `pdf`, `zip`. `txt` and `xml` are not in the list. |
| `excludedPathPrefixes` | `[]` | Path prefixes never recorded. Plain string prefixes: `/health` also excludes `/health-insurance/`, so end a prefix with `/` to exclude only a directory. The dashboard's own path, and everything below it, is always excluded. |
| `maximumPendingWrites` | `256` | Recording writes allowed in flight at once. Beyond it, visits are dropped with a sampled warning, so a slow database under a crawler burst cannot grow memory without bound. |

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
| `timeZone` | `.utc` | Zone every hourly and daily bucket is drawn in. A `BotKitTimeZone` case per canonical IANA zone, such as `.americaNewYork`. |
| `dateRanges` | all `BotDateRange` cases | Range pills offered: `.day` (24h), `.week` (7d), `.month` (30d), `.quarter` (90d). |
| `defaultDateRange` | `.week` | Range shown when the URL names none. |
| `sessionCookieName` | `botkit_dashboard` | Session cookie name. |
| `sessionLifetime` | 12 hours | How long a sign-in lasts. |
| `secureCookies` | `.automatic` | When the cookie is `Secure`: `.automatic`, `.always` or `.never`. |
| `signInPage` | SwiftlyBotKit logo, dashboard colours | `SignInPage(logo:colors:darkColors:)`. `logo`: `.swiftlyBotKit` (embedded), `.image(url:altText:)` for your own, or `.none`. `colors`/`darkColors`: `SignInColors` (background, card, text, secondaryText, border, button, buttonText), each optional; without `darkColors`, `colors` applies in both modes. Invalid values throw at install. |
| `loginLimit` | 5 failures per 15 minutes | `LoginLimit(maximumFailures:window:)`, per client (IPv6 per /64), in memory. A process-wide ceiling of 50 failures per window applies on top. |

The dashboard is mounted only when both `username` and `password` resolve to
values that are not empty or only whitespace. For a zone the `BotKitTimeZone` list lacks, use
`.custom(TimeZone(identifier: "...")!)`; a fixed offset such as
`.custom(TimeZone(secondsFromGMT: 3600)!)` works too, without daylight saving
time. Buckets are local wall-clock hours and days computed in Swift, and
PostgreSQL is only sent their boundaries, never the zone name. A repeated hour
when clocks go back is one bucket. Legacy names such as `.asiaCalcutta` are
deprecated aliases of the canonical case (`.asiaKolkata`), and a zone newer
than the host's tz database (`America/Coyhaique` on Swift 6.0 or 6.1 for Linux)
is drawn in UTC.

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

In one line: **one proxy, the default; `n` proxies, `.forwardedFor(trustedProxies: n)`;
no proxy, `.remoteAddress`; a proxy with its own header, `.custom`.**

> **Exposed directly? Use `.remoteAddress`.** The default reads
> `X-Forwarded-For` whoever sent it, because it assumes a proxy that appends
> the address it saw. An app that clients can reach without passing through
> that proxy (no proxy at all, or a platform hostname that bypasses your CDN)
> lets a client write the last entry itself: it can then claim an operator's
> address and be counted as `verified`, and reset the login limiter on every
> attempt. Use `.remoteAddress` there, or lock the origin to the proxy.

If the strategy does not match your proxies, `verified` and `spoofed` counts
cannot be trusted, and neither can the login limiter, which is keyed on the
same address. Entries such as `1.2.3.4:5678` or `[2600::5]:443`, which some
proxies write, are read as the bare address.

**Dashboard credentials.** Use a long random password. Failed sign-ins are
limited per client IP (five per fifteen minutes by default, IPv6 grouped by
/64), in memory and per process, so several instances each keep their own
count. A process-wide ceiling (`loginLimit.globalMaximumFailures`, 50 failures per window by default) sits on top, so forged
client addresses cannot buy unlimited guesses; when it trips, every sign-in,
the owner's included, is refused until the window passes, and a `critical`
line is logged. Username and password are always both compared. Keep
`dashboard.path` under a path your `robots.txt` disallows.

**Sessions.** The session cookie is signed, stateless, bound to the dashboard
username and password, and scoped to the dashboard path (`HttpOnly`,
`SameSite=Lax`). Earlier versions set it with `Path=/`: sign-in and sign-out
also expire that one, and a valid token is accepted whichever of the
same-named cookies carries it. Changing the password signs every session out. Signing out
only clears the browser's cookie: a copy taken earlier stays valid until it
expires, so change the password if a cookie may have leaked. Sign-in and
sign-out refuse cross-site requests (by `Sec-Fetch-Site`, else `Origin`), and
every dashboard response sends `no-store`, `X-Frame-Options: DENY`,
`nosniff`, `Referrer-Policy: same-origin`, `noindex` and a
`Content-Security-Policy` that allows no script.

**Signing secret.** Set `BOT_DASHBOARD_SECRET` in production to a long random
value, and keep it stable. It signs the stateless session cookie, so anyone who
has it can mint a session; a secret shorter than 32 bytes is logged as a
warning. It also keys the IP hash, so changing it means new
rows no longer match old ones when counting distinct clients. The session
cookie is `Secure` over HTTPS by default, including behind a proxy that sets
`X-Forwarded-Proto: https`.

**Stored data.** Rows hold the path, user agent, referring assistant
platform and a keyed hash of the client IP. That hash is pseudonymous personal
data, and nothing is deleted automatically; see the data protection section of
[SECURITY.md](SECURITY.md) for a retention query.

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
