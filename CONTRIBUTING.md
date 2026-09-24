# Contributing to SwiftlyBotKit

Thanks for helping. Bug reports, missing agents and pull requests are all
welcome.

## Where the source lives

The canonical source of SwiftlyBotKit lives in a private monorepo at Swiftly
Developed, where it runs in production, and this repository is a mirror of
that directory. Pull requests here are still the right way to contribute: they
are reviewed here, applied upstream, and come back with the next mirror push.
Your authorship is kept. Because of this, a merged pull request may show as
closed rather than merged.

## Building and testing

```bash
swift build
swift test
```

The tests do not need a database. They cover classification, IP range
matching, configuration, client IP extraction and dashboard rendering, and the
end-to-end dashboard route tests run without writing any rows. You need
PostgreSQL only to run the example app or your own app against the package.

If the tests fail to load with an `_swift_initBorrow` error at `dlopen`, your
resolved swift-collections has drifted. Pin it and retry:

```bash
swift package resolve swift-collections --version 1.3.0
```

## Adding or reclassifying an agent

The built-in catalog in
`Sources/SwiftlyBotKit/Catalog/AIAgentCatalogData.swift` is generated. Do not
edit it by hand. Regenerate it from the package root:

```bash
python3 Scripts/generate-ai-agent-catalog.py
```

The script downloads the current
[ai.robots.txt](https://github.com/ai-robots-txt/ai.robots.txt) list and prints
how each agent was classified:

```
  hand-audited overrides : ...
  upstream taxonomy      : ...
  keyword guess          : ...
  unclassified fallback  : ...  <- review these
```

Look at the "unclassified fallback" count every time, and at the diff of the
generated file. An agent that fell through to the fallback has no reliable
purpose. If it matters, add it to the script's override table with its
operator and purpose, and say in the pull request where that classification
comes from (ideally the operator's own documentation).

A scheduled workflow (`.github/workflows/catalog-freshness.yml`) runs the same
script every quarter and opens a pull request when the catalog changes. Those
pull requests get the same review.

An agent missing from ai.robots.txt belongs upstream first. If you only want
to report one, use the "New AI agent" issue template.

Adding a case to `AIAgentPurpose` or `BotVerification` changes a PostgreSQL
enum type, so it needs a new migration before a catalog regeneration. Open an
issue to discuss it first.

## Code conventions

- **Linux-compatible Foundation.** The package runs on Linux. Use
  `DateFormatter`, never `Date.formatted` or other `FormatStyle` APIs, which
  are incomplete there. Use `Double`, never `CGFloat`: there is no
  CoreGraphics on Linux.
- **Escape database text.** Everything read from the database goes through
  `BotCharts.escape` before it reaches raw markup. Agent names, user agents
  and request paths are attacker-controlled.
- **Never delay a response.** The middleware does one synchronous lookup and
  hands anything worth recording to a detached task. Keep network and
  database work off the request path.
- **PostgreSQL SQL is fine.** The package requires PostgreSQL, so raw SQL in
  `BotDashboardQueries` may use PostgreSQL features. Bind values as
  parameters.
- **Doc comments on public API.** Every `public` symbol has a `///` comment.
  The README, DocC catalog and tutorials are written against the public API,
  so change it deliberately and update them in the same pull request.
- **No deployment-specific values in source.** Anything a user might want to
  change is a `BotKitConfiguration` option.
- **Prose style.** In docs, comments and log messages, write plainly and do
  not use em dashes.

## Pull requests

- Keep each pull request to one change.
- Add or update tests for behaviour changes.
- Run `swift build` and `swift test` before opening it.
- Add a line under `## [Unreleased]` in `CHANGELOG.md` for user-visible
  changes.

By contributing, you agree that your contributions are licensed under the MIT
License that covers this project.
