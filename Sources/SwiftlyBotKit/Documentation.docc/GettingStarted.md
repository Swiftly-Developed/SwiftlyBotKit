# Getting started

Add SwiftlyBotKit to a Vapor app, record your first AI agent visit, and open the dashboard.

## Overview

SwiftlyBotKit is two halves that run independently. The recording half is a middleware that writes a row for every AI agent visit and every AI assistant referral. The dashboard half reads those rows back behind a password. Recording starts as soon as the package is installed; the dashboard appears once you give it credentials.

For a guided version of this page, follow the tutorial <doc:AddSwiftlyBotKitToAVaporApp>.

### Requirements

- Swift 6.0 or later, on macOS 14 or later, or on Linux.
- A Vapor 4 app using Fluent.
- PostgreSQL. The migration creates PostgreSQL enum types, and the dashboard's queries use `COUNT(*) FILTER`, `width_bucket` over `timestamptz` arrays and `BOOL_AND`. Other databases are not supported.

### Add the dependency

In `Package.swift`, add the package and its product:

```swift
dependencies: [
    .package(url: "https://github.com/Swiftly-Developed/SwiftlyBotKit.git", from: "0.6.0"),
],
targets: [
    .executableTarget(
        name: "App",
        dependencies: [
            .product(name: "SwiftlyBotKit", package: "SwiftlyBotKit"),
        ]
    ),
]
```

SwiftlyBotKit does not depend on a database driver. Keep `FluentPostgresDriver` in your own target.

### Install it

In `configure.swift`, after your database and `FileMiddleware` are set up:

```swift
import SwiftlyBotKit

app.databases.use(.postgres(configuration: postgresConfiguration), as: .psql)
app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

try BotKit.install(on: app)
try await app.autoMigrate()
```

``BotKit/install(on:config:)`` does two things, which you can also call separately:

- ``BotKit/configure(for:database:pageViews:)`` registers the migration. It must run before `app.autoMigrate()` or `swift run App migrate`.
- ``BotKit/configureRoutes(for:config:)`` installs the tracking middleware and, when credentials resolve, the dashboard routes. Call it after adding `FileMiddleware`, so the status code it records is the one the client received.

Call either `install` or the two separately, not both: a second setup throws ``BotKitConfigurationError/alreadyInstalled(_:)`` at boot.

BotKit does not need a database of its own. The migration adds one table, `ai_bot_visits`, and two enum types to the app's default database, next to the app's own tables, and recording and the dashboard use that same database. If the app registers several databases, set ``BotKitConfiguration/database`` to the one BotKit should use. It must be PostgreSQL.

### Check that it records

Run the app and pretend to be a crawler:

```bash
curl -A "GPTBot" http://127.0.0.1:8080/
```

Then look at the table:

```sql
SELECT agent_name, purpose, verification, path FROM ai_bot_visits;
```

The row says `GPTBot`, `training`, and most likely `spoofed`: OpenAI publishes the addresses its crawler uses, and your own machine is not one of them. See <doc:IPVerification>.

### Open the dashboard

Set three environment variables and restart:

```bash
export BOT_DASHBOARD_USER=owner
export BOT_DASHBOARD_PASSWORD='a long passphrase'
export BOT_DASHBOARD_SECRET="$(openssl rand -hex 32)"
```

Then open `/admin/ai-bots/` and sign in. Without the first two, the dashboard is not mounted and its path answers 404; recording is unaffected. Without the secret, sign-ins end at every restart. See <doc:TheDashboard> and <doc:Deployment>.

### Next steps

- <doc:ConfiguringSwiftlyBotKit> lists every option.
- <doc:ClientIPAndProxies> matters before you trust the verification numbers in production.
- <doc:UnderstandingAgentPurposes> explains how to read what the dashboard shows.
