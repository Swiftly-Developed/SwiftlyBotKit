# Changelog

All notable changes to this package are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Optional anonymous page views (`BotKitConfiguration.pageViews`, off by
  default). Each successful HTML page served to a browser adds one to a
  counter for its site, path and quarter-hour in a new `page_view_counts`
  table; no cookie, IP address, IP hash, user agent or referrer is stored.
  Counts are summed in memory and written every ten seconds and at shutdown.
  The dashboard gains a "Page views" tab at `<path>/pages/`, with the AI
  agent requests for each page beside its views.
- `BotKit.configure(for:database:pageViews:)` registers the page view table
  when `pageViews` is `true`; `install(on:config:)` does so from the
  configuration.
- `BotKitConfigurationError.pageViewsNotMigrated`, thrown when page views are
  enabled but their table was not registered.

### Fixed

- The tutorials page is now published at `tutorials/meetswiftlybotkit`, the
  address the README links to. DocC names the page after its file, which was
  `TableOfContents.tutorial`.

## [0.1.1] - 2026-09-24

### Fixed

- The migration's name is now pinned to `SwiftlyBotKit.CreateAIBotVisit`
  instead of Fluent's module-derived default, and it skips an existing
  `ai_bot_visits` table. An app that migrated under the package's earlier
  module name (`BotKit.CreateAIBotVisit`) would otherwise try to create the
  table again after upgrading and fail to boot.

## [0.1.0] - 2026-09-24

Initial public release.

### Added

- `BotKit.install(on:config:)`, plus `BotKit.configure(for:database:)` and
  `BotKit.configureRoutes(for:config:)` for apps that register migrations and
  routes separately.
- Tracking middleware that classifies every request without delaying the
  response and records AI agent visits and AI assistant referrals to
  PostgreSQL through Fluent.
- `BotKitTimeZone`, one case per canonical IANA time zone (`.americaNewYork`,
  `.europeBrussels`, ...), for `dashboard.timeZone`, generated from
  `zone.tab`. Legacy names (`.asiaCalcutta`, `.europeKiev`, ...) are
  deprecated aliases of the canonical case, `init(identifier:)` maps legacy
  names to it, and `isAvailable` tells whether the host's tz database has the
  zone (if not, it is drawn in UTC).
- `BotKitConfiguration.database`: the table lives in the app's own
  PostgreSQL database by default; another registered database can be chosen.
- Built-in catalog of 167 AI agents (`AIAgentCatalog`), generated from
  ai-robots-txt/ai.robots.txt. Tokens match as whole words, longest first,
  then custom before built-in, then earliest in the header, in one linear
  pass over the header (about 2 µs for an ordinary browser user agent).
- Purpose classification (`AIAgentPurpose`): `training`, `aiSearch`,
  `userTriggered`, `agent` and `scraper`.
- IP range verification (`BotVerification`) against the feeds published by
  OpenAI, Anthropic and Perplexity (`CrawlerRangeFeed.defaults`), with
  `verified`, `unverified` and `spoofed` stored separately and ranges
  refreshed in the background.
- AI assistant referral detection for 13 assistant hosts and 6 Android
  apps (`android-app://` referrers) in `LLMReferrer.builtInPlatforms`.
- `ClientIPStrategy` with `.lastForwardedFor` (default),
  `.forwardedFor(trustedProxies:)`, `.remoteAddress` and `.custom`.
- Keyed hashing of client IP addresses; raw addresses are never stored.
- Password-protected, server-rendered dashboard at `/admin/ai-bots` with
  summary tiles, a stacked time series, top agents, top pages, AI referrals,
  24h/7d/30d/90d filters and a multi-site switcher (`BotDashboardSite`).
- Signed, stateless session cookies and in-memory failed sign-in throttling.
- `BotKitConfigurationError`, thrown by `configureRoutes` and `install` for
  a configuration that cannot work: an invalid dashboard path, a session
  cookie name that is not an RFC 6265 token, a site keyed `all`, or a second
  installation on the same application.
- `recording.maximumPendingWrites` (default 256) caps recording writes in
  flight; beyond it, visits are dropped with a sampled warning.
- `LoginLimit.globalMaximumFailures` (default 50) makes the process-wide
  sign-in ceiling configurable.
- `BotKitConfiguration.reservedAllSitesKey`.

### Fixed

- Requests that end in a thrown error (an unrouted 404, an `Abort`) are
  recorded with the status the error becomes, instead of not at all.
- Agent matching no longer scans every token against the whole header: an
  80 KB user agent cost about a quarter of a second on the event loop.
- Ties between equally long tokens no longer depend on list order, so the
  real GPTBot header is `GPTBot` (not `OpenAI`), also when `GPTBot` is
  reclassified with a custom agent.
- Short tokens no longer match inside other words or ordinary software:
  `Baiduspider`, Sogou and Screaming Frog are not the `Spider` agent, and VS
  Code is not the `Code` agent.
- The catalog generator strips version suffixes (`MistralAI-User/1.0`),
  merges case-insensitive duplicates (`meta-externalagent`) and drops
  user-agent-generic tokens (`Spider`, `Code`); `--from-existing` re-applies
  this without fetching. `MistralAI-User` is now `userTriggered`.
- Stored strings are cut at 512 Unicode scalars on a character boundary
  (combining marks could make them unbounded) and have NUL removed, which
  PostgreSQL rejects.
- Referrers: a scheme-less `Referer` is read only up to its host, a trailing
  dot on the host is ignored, a leading dot on a custom suffix is ignored and
  an empty custom suffix matches nothing.
- The dashboard path is excluded on a segment boundary (`/admin/ai-botsnet/`
  is recorded) and after collapsing repeated slashes (`//admin/ai-bots/` is
  not). A percent-encoded asset extension (`/logo%2Epng`) counts as an asset.

- Dashboard buckets are local wall-clock hours and days computed entirely in
  Swift; PostgreSQL only sorts rows between the boundaries (`width_bucket`)
  and is never sent the zone name. Before, the two sides could disagree at
  DST changes: in zones that change at midnight (Cairo, Santiago) the last
  bucket went missing and rows were dropped from the chart, and Lord Howe's
  30-minute change emptied the 24h view. A repeated hour when clocks go back
  is now one bucket.
- Legacy zone names that Debian-based PostgreSQL images reject
  (`Asia/Calcutta`, `Europe/Kiev` and ten more) made the dashboard answer 500.
- A fixed-offset `.custom(TimeZone(secondsFromGMT:))` zone emptied the chart:
  PostgreSQL read `GMT+0100` as 100 hours west of UTC. It now works.
- The migration runs in a transaction, so one that fails halfway can be
  retried instead of tripping over the enum type it had already created.
- IP verification: a feed that fails is retried with exponential back-off
  (1 minute doubling to 15), including one that failed at boot, instead of
  being refetched on every hit or waiting the full refresh interval. Feed
  fetches have a ten-second deadline and a 2 MiB size limit.
- Two feeds naming the same agent are combined instead of the second
  replacing the first.
- Feed entries decode one by one: a mistyped entry no longer discards the
  whole feed, and an entry with both `ipv4Prefix` and `ipv6Prefix` keeps
  both.
- `X-Forwarded-For` entries with a port or brackets (`1.2.3.4:5678`,
  `[2600::5]:443`, `[2600::5]`) are read as the bare address, so a genuine
  crawler behind such a proxy is no longer filed as spoofed.
- Address parsing is identical on Darwin and Linux: IPv4 octets with leading
  zeros, zone ids, NUL and other stray characters are rejected before
  `inet_pton`.
- `BotKitConfigValue.resolve()` trims surrounding whitespace and newlines;
  a whitespace-only value counts as unset.
- Duplicate `dateRanges` render one pill each; duplicate site keys are
  logged and offered once.
- `configureRoutes` no longer reads `app.client`, which froze the app's
  HTTP client configuration at install time; the client is resolved at the
  first feed fetch, and never with verification off.
- A bot row with a NULL purpose, written by something other than this
  package, was counted in the tiles but missing from the chart. It is now
  charted as `scraper`, the catalog's fallback.

### Changed

- The dashboard path is validated: the root `/`, route syntax (`:x`, `*`,
  `**`), `.` and `..` segments and anything but letters, digits, `-`, `.`,
  `_` and `~` throw. Segments are registered as literal route constants.
- Installing twice (`install` twice, `configureRoutes` twice, or `configure`
  followed by `install`) throws instead of registering the migration or the
  middleware a second time. A second `configure` logs an error and does
  nothing.
- `openai.com`, `claude.com` and `x.ai` are no longer built-in referrer
  hosts: they are company and developer-documentation sites, not assistants.

### Security

- Dashboard sessions are bound to a fingerprint of the dashboard username and
  password, so changing the password signs every session out. This changes the
  token format: sessions issued by pre-release builds are invalidated once and
  their owners must sign in again.
- Session tokens are accepted only in their canonical encoding (digits only,
  no sign or leading zeros).
- Sign-in throttling reserves the attempt before the password is checked, in
  one step with the limit check, so concurrent guesses cannot exceed the
  limit; groups IPv6 clients by /64; falls back to the socket peer address
  when the client IP strategy yields none; sweeps expired entries and caps
  the number of tracked clients.
- A process-wide ceiling of 50 failed sign-ins per window, on top of the
  per-client limit. When it trips, every sign-in is refused until the window
  passes, and a `critical` line is logged.
- Sign-in and sign-out refuse cross-site requests (`Sec-Fetch-Site:
  cross-site`, or an `Origin` that does not match `Host`) with 403.
- Every dashboard response, including the sign-in and sign-out redirects,
  sends `Cache-Control: no-store`, `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and a
  script-free `Content-Security-Policy`.
- The session cookie's `Path` is the dashboard path instead of `/`. Sign-in
  and sign-out also expire a same-named `Path=/` cookie left by earlier
  builds, and a valid token is accepted whichever same-named cookie carries
  it.
- Range feed prefixes broader than an IPv4 `/8` or an IPv6 `/16` are
  ignored and logged once per feed.
- The docs now state plainly that an app exposed directly must use
  `ClientIPStrategy.remoteAddress`; the default `.lastForwardedFor` assumes
  one appending proxy.
- A signing secret shorter than 32 bytes is logged as a warning.
- A username or password that is only whitespace no longer mounts the
  dashboard.
- Successful sign-ins are logged at `info`, with the keyed hash of the client
  address.
- A signed-in dashboard request with no database registered answers 503
  instead of crashing.
- `BotKitConfiguration` with `recording`, `detection`, `verification` and
  `dashboard` groups, and `BotKitConfigValue` for values read from the
  environment or set in code.
- Custom agents and referrer hosts, including reclassification of built-in
  agents.
- `Scripts/generate-ai-agent-catalog.py` to regenerate the catalog.

[Unreleased]: https://github.com/Swiftly-Developed/SwiftlyBotKit/compare/0.1.1...HEAD
[0.1.1]: https://github.com/Swiftly-Developed/SwiftlyBotKit/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/Swiftly-Developed/SwiftlyBotKit/releases/tag/0.1.0
