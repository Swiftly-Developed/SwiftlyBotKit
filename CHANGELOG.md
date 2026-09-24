# Changelog

All notable changes to this package are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-24

Initial public release.

### Added

- `BotKit.install(on:config:)`, plus `BotKit.configure(for:database:)` and
  `BotKit.configureRoutes(for:config:)` for apps that register migrations and
  routes separately.
- Tracking middleware that classifies every request without delaying the
  response and records AI agent visits and AI assistant referrals to
  PostgreSQL through Fluent.
- `BotKitTimeZone`, one case per IANA time zone (`.americaNewYork`,
  `.europeBrussels`, ...), for `dashboard.timeZone`.
- `BotKitConfiguration.database`: the table lives in the app's own
  PostgreSQL database by default; another registered database can be chosen.
- Built-in catalog of 175 AI agents (`AIAgentCatalog`), generated from
  ai-robots-txt/ai.robots.txt, with longest-token-first matching.
- Purpose classification (`AIAgentPurpose`): `training`, `aiSearch`,
  `userTriggered`, `agent` and `scraper`.
- IP range verification (`BotVerification`) against the feeds published by
  OpenAI, Anthropic and Perplexity (`CrawlerRangeFeed.defaults`), with
  `verified`, `unverified` and `spoofed` stored separately and ranges
  refreshed in the background.
- AI assistant referral detection for 16 built-in hosts
  (`LLMReferrer.builtInPlatforms`).
- `ClientIPStrategy` with `.lastForwardedFor` (default),
  `.forwardedFor(trustedProxies:)`, `.remoteAddress` and `.custom`.
- Keyed hashing of client IP addresses; raw addresses are never stored.
- Password-protected, server-rendered dashboard at `/admin/ai-bots` with
  summary tiles, a stacked time series, top agents, top pages, AI referrals,
  24h/7d/30d/90d filters and a multi-site switcher (`BotDashboardSite`).
- Signed, stateless session cookies and in-memory failed sign-in throttling.
- `BotKitConfiguration` with `recording`, `detection`, `verification` and
  `dashboard` groups, and `BotKitConfigValue` for values read from the
  environment or set in code.
- Custom agents and referrer hosts, including reclassification of built-in
  agents.
- `Scripts/generate-ai-agent-catalog.py` to regenerate the catalog.

[Unreleased]: https://github.com/Swiftly-Developed/SwiftlyBotKit/compare/0.1.0...HEAD
[0.1.0]: https://github.com/Swiftly-Developed/SwiftlyBotKit/releases/tag/0.1.0
