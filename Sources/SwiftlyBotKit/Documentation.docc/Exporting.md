# Exporting to CSV

Download the recorded traffic as a CSV file, at the level of detail you need.

## Overview

The dashboard's **Export** tab, at `<path>/export/`, is a form that downloads a CSV. It sits behind the same sign-in as the rest of the dashboard and needs no configuration: every app that mounts the dashboard has it.

The form is a plain `GET` to `<path>/export/csv`, so it works without script, and an export's settings are a URL you can bookmark or share with someone who can sign in.

### What you choose

- **Site**: the site switcher above the form, as on every tab. `all` exports every site.
- **Period**: one of the dashboard's date ranges, which end now, or custom dates. Custom dates are whole local days in ``BotKitConfiguration/Dashboard/timeZone``, both included, up to ten years.
- **Level of detail**: raw rows, per day, per ISO week (Monday to Sunday), per calendar month, or totals over the whole period.
- **Include**: any combination of AI agents, AI referrals and people. People are offered only with ``BotKitConfiguration/PageViews`` on. *AI agents: page reads only* narrows AI agents to successful `GET`s of a page, the rows the Page views tab counts, so they compare like for like with people.
- **Break down by**: site, page, agent and operator, purpose, verification, and referring assistant. A breakdown applies to the audiences that have it: an agent name to AI agents, a referring assistant to AI referrals, a page to all three.

### The file

UTF-8, comma separated, CRLF line ends, a header line first. Every line says which audience it belongs to (`ai_agent`, `ai_referral` or `people`), so several audiences in one file pivot cleanly in a spreadsheet; a column that does not apply to a line's audience is empty.

A grouped export (every level except raw) has these columns:

| Column | Contents |
|---|---|
| `period` | `2026-09-26`, `2026-W39`, `2026-09`, or `total` |
| `period_start`, `period_end` | The period's exact bounds, as local time with its offset (`2026-09-26T00:00:00+02:00`). The end is exclusive. The first and last periods are cut to the chosen range, so "last 24 hours" per day is two partial days. |
| `audience` | `ai_agent`, `ai_referral` or `people` |
| One or two per breakdown | `site`, `path`, `agent` and `operator`, `purpose`, `verification`, `referrer_platform` |
| `count` | Requests for AI agents, visits for AI referrals, page views for people |

Lines are ordered by period, then audience, then count, largest first. With no breakdown chosen, every period has a line for every audience, with 0 when nothing was recorded, so the file is an unbroken series.

A raw export has `time`, `audience`, `site`, `path`, `method`, `status_code`, `agent`, `operator`, `purpose`, `verification`, `respects_robots_txt`, `referrer_platform` and `count`, oldest first. An AI agent or referral line is one request, with `count` 1. A people line is one stored counter: `time` is the start of its quarter-hour and `count` its views. That is the finest detail that exists for people, because nothing about an individual page view is stored.

The file name says what is in it: `ai-traffic_<site>_<first day>_<last day>_<detail>.csv`.

### What is never exported

The keyed IP hash and the user agent stay in the database. They are what the dashboard needs to count distinct clients and to find agents the catalog misses, not something to pass around in a spreadsheet.

Values that come from requests, such as paths, are written so a spreadsheet cannot run them: a value starting with `=`, `+`, `-`, `@`, a tab or a carriage return gets a leading `'`.

### How it is built

Periods are computed in Swift in the dashboard's time zone and sent to PostgreSQL as instants, exactly like the dashboard's buckets, so an export and the chart agree across DST changes. See <doc:TheDashboard>.

A grouped export is built in full before the response starts, so a failed query is an error page, not a truncated file. A raw export has no such bound, so it is streamed: rows are read in pages of 5,000, each page continuing from the last row's time and key, and written as they are read. Memory stays flat however long the period, and a slow client never holds more than one page. An error part way through ends the download as failed.

A refused form (no audience ticked, dates missing, reversed or malformed, or people asked for without page views) comes back with status 400, the reason above the form, and the form filled in as it was sent.
