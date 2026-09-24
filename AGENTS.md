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
swift Scripts/generate-time-zones.swift       # regenerate BotKitTimeZone (run on macOS)
```

## Layout

- `Sources/SwiftlyBotKit/Configuration/`: every public option. `BotKitTimeZone.swift` is generated.
- `Sources/SwiftlyBotKit/Catalog/AIAgentCatalogData.swift`: generated from ai-robots-txt/ai.robots.txt. Never hand-edit.
- `Sources/SwiftlyBotKit/Documentation.docc/`: DocC articles and tutorials. The README and DocC are written against the public API, so update them when it changes.
- `Examples/QuickStart/`: runnable example app, built in CI.

## Rules that are easy to break

- **Client IP:** the default reads the *last* `X-Forwarded-For` entry. The first is attacker-controlled; reading it hands spoofers a `verified` badge.
- **Verification feeds:** decode from raw bytes with `JSONDecoder`, never `response.content`. Some operators serve JSON as `application/octet-stream`.
- **Recording never delays or alters the response.** The middleware does one synchronous catalog lookup and writes in a detached task.
- **Time zones:** buckets are computed in Swift and PostgreSQL with the same IANA identifier. Never pass a fixed-offset zone; PostgreSQL inverts the `GMT+0100` sign.
- **HTML:** every database- or request-sourced string goes through `BotCharts.escape`. Charts are server-rendered SVG, no JavaScript.
- **Chart colours** follow a fixed palette slot order that is part of the colourblind-safety design. Do not reorder.
- **PostgreSQL only.** The migration creates enum types and the queries use `FILTER`, `date_trunc` and `AT TIME ZONE`. The library depends on FluentSQL/SQLKit, not the driver.

## Conventions

- Swift 6 language mode; everything public is `Sendable`.
- Linux-compatible Foundation: `DateFormatter`, not `Date.formatted`; `Double`, not `CGFloat`.
- `///` doc comment on every public symbol.
- No em dashes in code, comments or docs.
