# SwiftlyBotKit

Vapor 4 package that records AI-agent traffic and AI-assistant referrals to
PostgreSQL and serves a password-protected dashboard. Module `SwiftlyBotKit`,
entry point `BotKit.install(on:config:)`, all options in `BotKitConfiguration`.

## Commands

```bash
swift build
swift test                                   # no database needed
BOTKIT_TEST_DATABASE_URL=postgres://... swift test   # adds the PostgreSQL integration tests
swift package generate-documentation --target SwiftlyBotKit --warnings-as-errors
python3 Scripts/generate-ai-agent-catalog.py  # refresh the agent catalog, then review the "unclassified fallback" count
swift Scripts/generate-time-zones.swift       # regenerate BotKitTimeZone from zone.tab and tzdata.zi (run on macOS)
```

## Layout

- `Sources/SwiftlyBotKit/Configuration/`: every public option. `BotKitTimeZone.swift` is generated.
- `Sources/SwiftlyBotKit/Catalog/AIAgentCatalogData.swift`: generated from ai-robots-txt/ai.robots.txt. Never hand-edit.
- `Sources/SwiftlyBotKit/Services/PageViewCounter.swift`: the optional page view filter, in-memory tally and batched flush; `PageViewQueries.swift` and `Pages/PageViewsPage.swift` are its dashboard tab.
- `Sources/SwiftlyBotKit/Models/BotExport.swift`, `Services/BotExportQueries.swift`, `Services/BotExportCSV.swift` and `Pages/ExportPage.swift`: the Export tab and its CSV.
- `Sources/SwiftlyBotKit/Documentation.docc/`: DocC articles and tutorials. The README and DocC are written against the public API, so update them when it changes.
- `Examples/QuickStart/`: runnable example app, built in CI.

## Rules that are easy to break

- **Client IP:** the default reads the *last* `X-Forwarded-For` entry. The first is attacker-controlled; reading it hands spoofers a `verified` badge. The default assumes one appending proxy; an app exposed directly must use `.remoteAddress`, and the docs must keep saying so. Whether to change the default is the owner's decision.
- **Verification feeds (fetching):** every fetch carries a deadline and a size cap, a failed feed backs off (1 to 15 minutes) and keeps its old ranges, feeds naming the same agent are unioned, and prefixes broader than IPv4 /8 or IPv6 /16 are dropped. `app.client` is resolved lazily, never at install time.
- **Address parsing:** `IPRange.parse` validates the string itself before `inet_pton` (no leading-zero octets, zone ids, NUL), so Darwin and Linux agree. Keep it that way.
- **Configuration is validated at install:** `BotKitConfiguration.validate()` throws `BotKitConfigurationError` (dashboard path, cookie name, the reserved site key `all`), and a second install throws. Route segments are `.constant`.
- **Verification feeds:** decode from raw bytes with `JSONDecoder`, never `response.content`. Some operators serve JSON as `application/octet-stream`.
- **Recording never delays or alters the response.** The middleware does one synchronous catalog lookup and writes in a detached task.
- **Time zones:** every bucket boundary is computed in Swift (`BotDateRange.window`) and sent to PostgreSQL as instants for `width_bucket`. Never hand PostgreSQL a zone name: its tz data can lack or disagree on a zone, and it reads `GMT+0100` with an inverted sign, in hours. `BotKitTimeZone` cases are the canonical `zone.tab` names; legacy names are deprecated aliases.
- **HTML:** every database- or request-sourced string goes through `BotCharts.escape`. Charts are server-rendered SVG, no JavaScript. Hover popovers are CSS only (`:hover`/`:focus` on an HTML layer over the SVG), since the CSP allows no script.
- **Page views store counters only.** `page_view_counts` is site, path, quarter-hour and a count. Never add a column, log line or in-memory field that holds anything about the visitor (IP, IP hash, user agent, referrer, cookie, per-visit time): the whole claim of the feature is that nothing identifying is kept. Request headers may be read to decide whether to count, then dropped. Buckets stay quarter-hours so every zone's day boundary falls between them.
- **CSV export:** never add `ip_hash` or `user_agent` to an export, and keep every text field going through `BotExportCSV.field`, which escapes values a spreadsheet would run as formulas. Raw exports stay streamed and keyset-paged on `(microseconds, key)`; an `OFFSET` or a `Date` cursor would skip or repeat rows sharing an instant.
- **Chart colours** follow a fixed palette slot order that is part of the colourblind-safety design. Do not reorder.
- **PostgreSQL only.** The migration creates enum types (in one transaction) and the queries use `FILTER` and `width_bucket`. The library depends on FluentSQL/SQLKit, not the driver.

## Conventions

- Swift 6 language mode; everything public is `Sendable`.
- Linux-compatible Foundation: `DateFormatter`, not `Date.formatted`; `Double`, not `CGFloat`.
- `///` doc comment on every public symbol.
- No em dashes in code, comments or docs.
