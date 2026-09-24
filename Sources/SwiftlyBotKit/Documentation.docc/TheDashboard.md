# The dashboard

What the dashboard shows, how its filters work, and how it is built.

## Overview

The dashboard is mounted at ``BotKitConfiguration/Dashboard/path``, `/admin/ai-bots/` by default, once a username and password are configured. It has three routes, all under that path:

- `GET /admin/ai-bots/`: the dashboard, or the sign-in page when signed out.
- `POST /admin/ai-bots/login`: signs in with the form fields `username` and `password`.
- `POST /admin/ai-bots/logout`: signs out.

Both pages send `X-Robots-Tag: noindex, nofollow` and `Cache-Control: no-store`. Keep the path under something your `robots.txt` disallows as well.

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

Every bucket boundary is drawn in ``BotKitConfiguration/Dashboard/timeZone``, on both sides of the query: Swift builds the buckets with a `Calendar` in that zone, and PostgreSQL is handed the same zone's identifier for `AT TIME ZONE`. So a "day" means the same thing in both, including on the two days a year when a local day is 23 or 25 hours long, where plain epoch arithmetic would drift.

Use an IANA identifier such as `Europe/Paris`. A fixed-offset zone has an identifier like `GMT+0100`, which PostgreSQL reads with the opposite sign.

Buckets are generated in Swift rather than taken from the query results, so a quiet hour shows as an empty column instead of disappearing from the axis. ``BotDateRange/buckets(now:in:)``, ``BotDateRange/start(from:in:)`` and ``BotDateRange/axisLabel(for:in:)`` expose the same arithmetic.

### How it is built

The charts are server-rendered inline SVG and CSS bars. There is no JavaScript and no CDN dependency, so the page renders the same whether or not a third-party host is reachable. Everything that comes from the database, including agent names and request paths, is escaped before it reaches the markup, because both are attacker-influenced text.

Purpose colours come from a fixed categorical palette, assigned in ``AIAgentPurpose/displayOrder``. The stack is drawn in the same order, so neighbouring segments always use adjacent palette slots, which is the pairing the palette was checked for colour-blind readability against. Every legend entry also carries its count, and the agent and page breakdowns are tables, so no reading depends on colour alone.

### Signing in

Sessions are a signed cookie, not server state, so a sign-in survives a restart and works across instances as long as ``BotKitConfiguration/signingSecret`` is stable. The cookie is `HttpOnly` and `SameSite=Lax`, and `Secure` according to ``BotKitConfiguration/Dashboard/secureCookies``.

Username and password are both compared on every attempt, in constant time, so a failure does not reveal which half was wrong. Failed attempts are throttled per client by ``BotKitConfiguration/Dashboard/loginLimit``, keyed on a hash of the client IP.

### Database

The dashboard needs `req.db` to be a PostgreSQL database. It answers 503 when the database is not SQL-capable. The queries use `COUNT(*) FILTER`, `date_trunc`, `AT TIME ZONE` and `BOOL_AND`, and read the fixed table `ai_bot_visits`.
