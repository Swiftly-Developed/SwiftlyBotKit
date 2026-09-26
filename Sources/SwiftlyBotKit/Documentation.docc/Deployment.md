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

Each is logged as a warning at boot when missing. The names are defaults; point ``BotKitConfiguration/Dashboard/username``, ``BotKitConfiguration/Dashboard/password`` and ``BotKitConfiguration/signingSecret`` at your own variables if you prefer. See <doc:ConfiguringSwiftlyBotKit>.

Values are read once, when ``BotKit/configureRoutes(for:config:)`` runs. Changing a variable needs a restart.

### Secrets

- Generate the signing secret randomly and make it long, for example with `openssl rand -hex 32`. A secret shorter than 32 bytes is logged as a warning at boot: a captured session cookie is enough to brute-force a short key offline.
- Keep it stable. Rotating it signs everyone out and makes IP hashes written afterwards differ from those written before, so distinct-visitor counts spanning the change are overstated.
- Use the same secret on every instance of the app, so a session signed by one is accepted by the others.
- Keep all three values out of source control. Use your platform's secret store or config vars.
- A username or password that is empty or only whitespace counts as unset, so the dashboard is not mounted.
- Changing the dashboard password signs every session out, since sessions are bound to it. Do that if a session cookie may have leaked: signing out does not revoke a copied cookie.

### PostgreSQL

PostgreSQL is required (13 and 16 are tested). The migration creates two enum types, `ai_agent_purpose` and `bot_verification`, the `ai_bot_visits` table, and three indexes, in one transaction: if it fails halfway, for example because the app already has a type with one of those names, nothing is left behind, and it can be rerun once the cause is fixed. The table name is fixed. The dashboard does not depend on the server's time zone data.

Register the migration with ``BotKit/install(on:config:)`` or ``BotKit/configure(for:database:pageViews:)`` (one or the other, once) before migrating, then migrate however your app already does: `try await app.autoMigrate()` at boot, or a release step such as `swift run App migrate --yes`.

Recording writes to `app.db`, the app's default database. Rows are small and only AI traffic is recorded, so the table grows slowly, but it is never pruned automatically. The dashboard reads at most 90 days back. To keep the table bounded, delete older rows on a schedule:

```sql
DELETE FROM ai_bot_visits WHERE created_at < now() - interval '120 days';
```

### Data protection

Each recorded row holds the request method and path, the user agent, the matched agent and its purpose, the verification result, the referring assistant's platform, the site key, the status code, a timestamp and a keyed hash of the client IP address. Raw addresses are never stored, and ordinary human traffic is not recorded.

The IP hash is an HMAC under the signing secret. It cannot be reversed without the secret, but anyone holding the secret can reverse it by hashing the address space, so treat it as pseudonymous personal data, not anonymous data. Use a long random secret and guard it like the database.

There is no built-in retention; delete rows older than your retention period on a schedule, as shown under PostgreSQL above.

### Sign-in lockout

Failed sign-ins are limited per client and, as a backstop against forged client addresses, process-wide: at most ``BotKitConfiguration/LoginLimit/globalMaximumFailures`` (50 by default) failures from all clients together per ``BotKitConfiguration/Dashboard/loginLimit`` window. When that ceiling is reached every sign-in is refused, the owner's included, until the window passes, and a `critical` line starting `AI bot dashboard sign-in is locked for every client` is logged. Nothing needs to be done: it lifts on its own. If it recurs, someone is guessing the password; make sure it is long and random. See <doc:TheDashboard> for the details.

### Outbound network access

IP verification fetches the operators' range feeds over HTTPS from `openai.com`, `claude.com` and `www.perplexity.ai`, at the first agent visit after boot and then every 12 hours. Each fetch has a ten-second deadline and a 2 MiB size limit; a feed that fails is retried after 1 minute, then 2, 4 and 8, and every 15 minutes after that, keeping the ranges it last delivered. Feeds go through the app's own `app.client`, resolved at the first fetch, so its HTTP client configuration (proxy, TLS, whether redirects are followed) applies; nothing is created when verification is off. If your environment restricts egress, allow those hosts or set ``BotKitConfiguration/Verification/isEnabled`` to `false`.

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

**No proxy.** When the app faces the internet directly, you must use ``ClientIPStrategy/remoteAddress``. The default would read an `X-Forwarded-For` header the client sent itself, which lets anyone earn a verified badge and reset the sign-in throttle at will.

### Middleware order

Call ``BotKit/configureRoutes(for:config:)`` (or `install`) once, after adding `FileMiddleware`, so the status code recorded is the one the client received. A second call, or `configure` followed by `install`, throws ``BotKitConfigurationError/alreadyInstalled(_:)`` rather than recording every hit twice or registering the migration twice. The tracking middleware never delays a response: it does one in-memory catalog lookup and writes in a detached task. At most ``BotKitConfiguration/Recording/maximumPendingWrites`` writes (256 by default) are in flight at once; when the database falls that far behind, further visits are dropped and a warning starting `Dropped an AI bot visit` is logged (the first drop, then every thousandth). A process killed mid-write can lose a row, which is an acceptable trade for traffic statistics.

### Checking a deployment

1. Boot the app and read the log. Missing credentials or secret are reported as warnings.
2. Request a page with `curl -A "GPTBot" https://your.domain/` and confirm a row appears with verification `spoofed`, since your machine is not an OpenAI crawler.
3. Repeat it with `-H "X-Forwarded-For: <an address from openai.com/gptbot.json>"`. The row must still say `spoofed`. If it says `verified`, your client IP strategy is reading an address the client controls.
4. Sign in at the dashboard path and confirm the cookie is marked `Secure` and its `Path` is the dashboard path. The log shows `AI bot dashboard sign-in succeeded.`
5. Watch for `Could not refresh AI crawler ranges from` warnings over the following day. Each one means the agents that feed covers have fallen back to unverified.
