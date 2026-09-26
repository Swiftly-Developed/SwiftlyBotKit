# ``SwiftlyBotKit``

See which AI agents read your Vapor app, what they were doing, and whether they were who they claimed to be.

## Overview

Anything can count "AI bot hits". SwiftlyBotKit records the breakdown behind that number, on three axes:

- **Which agent.** Every request is matched against ``AIAgentCatalog``, 167 known AI agents generated from the community ai.robots.txt list, plus any you add.
- **What it was doing.** Each agent has an ``AIAgentPurpose``: collecting training data, indexing for AI search, fetching a page live because a person asked an assistant a question, acting as an autonomous agent, or scraping. The operators split these into separate user agents themselves, so the split is theirs, not a guess.
- **Real or forged.** Claimed agents are checked against the IP ranges their operators publish, so ``BotVerification/verified``, ``BotVerification/unverified`` and ``BotVerification/spoofed`` are separate numbers.

It also records people who arrive from an AI assistant's answer, such as a click through from `chatgpt.com` or `claude.ai`, in the same table.

Everything is shown on a password-protected dashboard, by default at `/admin/ai-bots/`, with a date filter and a site switcher for apps that serve several domains. The charts are server-rendered SVG and CSS, with no JavaScript.

Ordinary human traffic is never recorded, and no response is ever delayed: the middleware does one catalog lookup per request and writes in a detached task only when it matches. For scale, you can turn on anonymous page view counts, which add a "Page views" tab: how often people read each page, kept as plain counters with no cookie and nothing about the visitor. See <doc:PageViews>.

```swift
import SwiftlyBotKit

app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
try BotKit.install(on: app)
try await app.autoMigrate()
```

SwiftlyBotKit needs PostgreSQL at runtime. The package depends on Fluent and SQLKit, not on a driver, so your app brings the PostgreSQL driver it already uses.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:AddSwiftlyBotKitToAVaporApp>
- ``BotKit``
- <doc:Deployment>

### Configuration

- <doc:ConfiguringSwiftlyBotKit>
- ``BotKitConfiguration``
- ``BotKitConfiguration/Recording``
- ``BotKitConfiguration/Detection``
- ``BotKitConfiguration/Verification``
- ``BotKitConfiguration/Dashboard``
- ``BotKitConfiguration/LoginLimit``
- ``BotKitConfiguration/SecureCookiePolicy``
- ``BotKitConfigValue``
- ``BotKitTimeZone``

### Recording

- <doc:ClientIPAndProxies>
- <doc:AIReferrals>
- ``ClientIPStrategy``
- ``LLMReferrer``
- ``LLMReferrer/Platform``

### Detection and catalog

- <doc:UnderstandingAgentPurposes>
- <doc:CustomAgents>
- <doc:KeepingTheCatalogFresh>
- ``AIAgent``
- ``AIAgentCatalog``
- ``AIAgentPurpose``

### Verification

- <doc:IPVerification>
- ``BotVerification``
- ``CrawlerRangeFeed``
- ``IPRange``

### Page views

- <doc:PageViews>
- ``BotKitConfiguration/PageViews``

### Dashboard

- <doc:TheDashboard>
- ``BotKitConfiguration/SignInPage``
- ``SignInLogo``
- ``SignInColors``
- ``BotDashboardSite``
- ``BotDateRange``
