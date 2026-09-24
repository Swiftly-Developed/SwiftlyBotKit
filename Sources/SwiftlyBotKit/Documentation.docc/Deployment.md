# Deployment

Run SwiftlyBotKit in production: environment variables, PostgreSQL, secrets, and the proxy in front of your app.

## Overview

A production deployment needs four things: a PostgreSQL database, the migration applied, the dashboard's secrets set, and a client IP strategy that matches the proxy in front of the app.

### Environment variables

With the default configuration, SwiftlyBotKit reads three variables:

| Variable | Used for | If unset |
|---|---|---|
| `BOT_DASHBOARD_USER` | Dashboard username | Dashboard not mounted; recording continues |
| `BOT_DASHBOARD_PASSWORD` | Dashboard password | Dashboard not mounted; recording continues |
| `BOT_DASHBOARD_SECRET` | Session cookies and IP hashes | Random per-process key: sign-ins end at every restart and IP hashes stop matching earlier rows |

Each is logged as a warning at boot when missing. The names are defaults; point ``BotKitConfiguration/Dashboard/username``, ``BotKitConfiguration/Dashboard/password`` and ``BotKitConfiguration/signingSecret`` at your own variables if you prefer. See <doc:Configuration>.

Values are read once, when ``BotKit/configureRoutes(for:config:)`` runs. Changing a variable needs a restart.

### Secrets

- Generate the signing secret randomly and make it long, for example with `openssl rand -hex 32`.
- Keep it stable. Rotating it signs everyone out and makes IP hashes written afterwards differ from those written before, so distinct-visitor counts spanning the change are overstated.
- Use the same secret on every instance of the app, so a session signed by one is accepted by the others.
- Keep all three values out of source control. Use your platform's secret store or config vars.

### PostgreSQL

PostgreSQL is required. The migration creates two enum types, `ai_agent_purpose` and `bot_verification`, the `ai_bot_visits` table, and three indexes. The table name is fixed.

Register the migration with ``BotKit/install(on:config:)`` or ``BotKit/configure(for:database:)`` before migrating, then migrate however your app already does: `try await app.autoMigrate()` at boot, or a release step such as `swift run App migrate --yes`.

Recording writes to `app.db`, the app's default database. Rows are small and only AI traffic is recorded, so the table grows slowly, but it is never pruned automatically. The dashboard reads at most 90 days back. To keep the table bounded, delete older rows on a schedule:

```sql
DELETE FROM ai_bot_visits WHERE created_at < now() - interval '120 days';
```

### Outbound network access

IP verification fetches the operators' range feeds over HTTPS from `openai.com`, `claude.com` and `www.perplexity.ai`, at the first agent visit after boot and then every 12 hours. If your environment restricts egress, allow those hosts or set ``BotKitConfiguration/Verification/isEnabled`` to `false`.

### Behind a proxy

Pick the ``ClientIPStrategy`` that matches the chain of proxies in front of the app. <doc:ClientIPAndProxies> explains why this is a security decision and not only an accuracy one.

**Heroku, Render and similar platforms.** The platform router appends the client address to `X-Forwarded-For` and terminates TLS. The defaults are right: ``ClientIPStrategy/lastForwardedFor`` for the IP, and ``BotKitConfiguration/SecureCookiePolicy/automatic`` marks the session cookie `Secure` from `X-Forwarded-Proto: https`.

**nginx.** With one nginx in front of the app, forward the header by appending, and pass the scheme:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

The default ``ClientIPStrategy/lastForwardedFor`` then reads the address nginx saw. Make sure the app only listens on an address nginx can reach, so no one can bypass it.

**Cloudflare in front of a platform router.** Two proxies append to `X-Forwarded-For`: Cloudflare, then the router. The client is two entries from the right:

```swift
config.clientIP = .forwardedFor(trustedProxies: 2)
```

Alternatively read Cloudflare's own header:

```swift
config.clientIP = .custom { req in req.headers.first(name: "CF-Connecting-IP") }
```

Either choice assumes every request went through Cloudflare. If the origin is also reachable directly, for example on the platform's own hostname, a client can skip Cloudflare and choose the address you read. Lock the origin to Cloudflare, with authenticated origin pulls or by only accepting Cloudflare's addresses, before relying on verification.

**No proxy.** When the app faces the internet directly, use ``ClientIPStrategy/remoteAddress``. The default would read an `X-Forwarded-For` header the client sent itself.

### Middleware order

Call ``BotKit/configureRoutes(for:config:)`` (or `install`) after adding `FileMiddleware`, so the status code recorded is the one the client received. The tracking middleware never delays a response: it does one in-memory catalog lookup and writes in a detached task. A process killed mid-write can lose a row, which is an acceptable trade for traffic statistics.

### Checking a deployment

1. Boot the app and read the log. Missing credentials or secret are reported as warnings.
2. Request a page with `curl -A "GPTBot" https://your.domain/` and confirm a row appears with verification `spoofed`, since your machine is not an OpenAI crawler.
3. Repeat it with `-H "X-Forwarded-For: <an address from openai.com/gptbot.json>"`. The row must still say `spoofed`. If it says `verified`, your client IP strategy is reading an address the client controls.
4. Sign in at the dashboard path and confirm the cookie is marked `Secure`.
5. Watch for `Could not refresh AI crawler ranges from` warnings over the following day. Each one means the agents that feed covers have fallen back to unverified.
