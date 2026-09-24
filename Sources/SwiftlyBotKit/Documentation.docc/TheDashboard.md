# The dashboard

What the dashboard shows, how its filters work, and how it is built.

## Overview

The dashboard is mounted at ``BotKitConfiguration/Dashboard/path``, `/admin/ai-bots/` by default, once a username and password are configured. It has three routes, all under that path:

- `GET /admin/ai-bots/`: the dashboard, or the sign-in page when signed out.
- `POST /admin/ai-bots/login`: signs in with the form fields `username` and `password`.
- `POST /admin/ai-bots/logout`: signs out.

Every response from these routes, including the sign-in and sign-out redirects, sends `X-Robots-Tag: noindex, nofollow`, `Cache-Control: no-store`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and a `Content-Security-Policy` that allows no script at all (see "Response headers" below). Keep the path under something your `robots.txt` disallows as well.

It is mounted on every host the app answers for, so a multi-site app has one dashboard across all of its sites, with the site switcher doing the filtering.

### What it shows

- **Tiles**: AI agent visits with the number of distinct agents, user-triggered visits, the verified share of the visits that could be checked, spoofed visits, and AI referrals.
- **Visits over time**: a stacked column chart split by ``AIAgentPurpose``, in hourly buckets for 24 hours and daily buckets otherwise.
- **Top agents**: who is reading the site, how much, and how much of it could be verified. Agents whose operators document that they ignore `robots.txt` are flagged.
- **Most-read pages**: which paths agents fetch, with the user-triggered share of each page highlighted against the fetches made without a person asking.
- **Visitors from AI assistants**: the referral counts per assistant. See <doc:AIReferrals>.

Tracking starts when the middleware is deployed. There is no backfill.

### Filters

The URL carries two query parameters:

- `range`: one of the raw values of ``BotDateRange``: `24h`, `7d`, `30d` or `90d`. The pills offered are ``BotKitConfiguration/Dashboard/dateRanges``, and a missing or unoffered value falls back to ``BotKitConfiguration/Dashboard/defaultDateRange``.
- `site`: a ``BotDashboardSite/key`` from ``BotKitConfiguration/sites``, or `all`.

With no `site` parameter, the dashboard opens on the site of the domain it was opened on, as decided by ``BotKitConfiguration/siteKey``. Signing in on one domain shows that domain's traffic. Every switcher link and range pill carries an explicit `site`, so choosing "All sites" sticks. An unknown key shows all sites.

The switcher is a menu of links with each site's logo, and is hidden when fewer than two sites are configured.

### Time zones

A bucket is one local wall-clock hour (24h) or one local calendar day (7d, 30d, 90d) in ``BotKitConfiguration/Dashboard/timeZone``. Every boundary is computed in Swift, from Foundation's rules for that zone, and PostgreSQL is sent the boundaries as instants: it sorts rows between them with `width_bucket` and never sees the zone's name. So the two sides cannot disagree about a DST change, and the zone does not have to exist in the database server's tz data.

Around DST changes the buckets follow the wall clock:

- The two change days are 23 and 25 hours long. Where the change happens at midnight (Santiago, Cairo), the day whose midnight is skipped starts at 01:00.
- On the 24h view, a skipped hour has no column.
- A repeated hour, when clocks go back, is one column holding both passes, so no label appears twice. That column can be up to twice as tall as its neighbours.

Any ``BotKitTimeZone`` works, including ``BotKitTimeZone/custom(_:)`` with a fixed offset such as `TimeZone(secondsFromGMT: 3600)`, which buckets correctly but never observes daylight saving time. A named zone the host's tz database does not have yet (``BotKitTimeZone/isAvailable`` is `false`, for example `America/Coyhaique` with Swift 6.0 or 6.1 on Linux) is drawn in UTC, and the chart caption names the zone actually used.

Buckets are generated in Swift rather than taken from the query results, so a quiet hour shows as an empty column instead of disappearing from the axis. ``BotDateRange/buckets(now:in:)``, ``BotDateRange/start(from:in:)`` and ``BotDateRange/axisLabel(for:in:)`` expose the same arithmetic.

A bot row with no purpose, which only a writer other than this package can leave, is counted in the tiles and charted as ``AIAgentPurpose/scraper``, the catalog's own fallback for an agent it cannot classify, so the chart always adds up to the tile.

### How it is built

The charts are server-rendered inline SVG and CSS bars. There is no JavaScript and no CDN dependency, so the page renders the same whether or not a third-party host is reachable. Everything that comes from the database, including agent names and request paths, is escaped before it reaches the markup, because both are attacker-influenced text.

Purpose colours come from a fixed categorical palette, assigned in ``AIAgentPurpose/displayOrder``. The stack is drawn in the same order, so neighbouring segments always use adjacent palette slots, which is the pairing the palette was checked for colour-blind readability against. Every legend entry also carries its count, and the agent and page breakdowns are tables, so no reading depends on colour alone.

### Signing in

Sessions are a signed cookie, not server state, so a sign-in survives a restart and works across instances as long as ``BotKitConfiguration/signingSecret`` is stable. The signature covers the expiry and a fingerprint of the configured username and password, so changing the password (or the username, or the secret) ends every existing session. The cookie is `HttpOnly`, `SameSite=Lax`, scoped with `Path` to ``BotKitConfiguration/Dashboard/path``, and `Secure` according to ``BotKitConfiguration/Dashboard/secureCookies``.

Username and password are both compared on every attempt, in constant time, so a failure does not reveal which half was wrong. A username or password that is empty or only whitespace counts as not configured, and the dashboard is not mounted. Successful sign-ins are logged at `info` and failed ones at `warning`, with a keyed hash of the client address rather than the address.

Sign-in and sign-out refuse cross-site requests with 403: a request whose `Sec-Fetch-Site` header is `cross-site`, or whose `Origin` header does not match its `Host` (or `X-Forwarded-Host`). A request carrying neither header, such as one from `curl`, is allowed.

#### Throttling

Failed attempts are limited by ``BotKitConfiguration/Dashboard/loginLimit`` in two ways, both in memory and per process:

- **Per client**, keyed on a hash of the client IP, with IPv6 addresses grouped by their /64 so one subscriber cannot rotate through its own prefix. When the client IP strategy yields no address, the socket peer address is used.
- **Process-wide**: at most 50 failures from all clients together per window (or ``BotKitConfiguration/LoginLimit/maximumFailures``, if higher). This bounds guessing even when the client address can be forged, for example by rotating `X-Forwarded-For` against an app reachable without its proxy. When the ceiling is reached, every sign-in, including the owner's, is refused with 429 until the window passes, and a `critical` log line is written once.

An attempt counts against both limits before the password is checked, in one step with the limit check, so concurrent requests cannot slip past it. A successful sign-in clears the client's count.

#### Signing out

Sign-out clears the cookie in the browser. Because sessions are stateless, it does not revoke a copy of the cookie taken earlier: that copy stays valid until it expires, or until the password or the signing secret changes. If a cookie may have leaked, change the dashboard password.

#### Response headers

The `Content-Security-Policy` is `default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`. The pages need no script; inline `<style>`, `style` attributes and inline SVG are covered by `style-src 'unsafe-inline'`. When a ``BotDashboardSite/logoPath`` is an absolute `http` or `https` URL, its origin is added to `img-src`; root-relative paths are covered by `'self'`.

### Database

The dashboard needs `req.db` to be a PostgreSQL database. It answers 503 when no database is registered under ``BotKitConfiguration/database`` or when the database is not SQL-capable. The queries use `COUNT(*) FILTER`, `width_bucket` over a `timestamptz[]` and `BOOL_AND`, and read the fixed table `ai_bot_visits`. They need nothing from the server's tz data.
