# Page views

Count how often people read each page, next to how often AI agents do, without storing anything about the people.

## Overview

The AI agent numbers mean more with something to compare them to. A page that ChatGPT-User fetched forty times last week is a different story when people read it four hundred times than when they read it four. Page views give that comparison, in the same dashboard, without a second analytics product.

They are off by default. When turned on, the dashboard gains a **Page views** tab at `<dashboard path>/pages/`, with the same site switcher and date ranges: total views, pages read, a chart over time, and the most-viewed pages with each page's AI agent requests beside it.

### What is stored

One table, `page_view_counts`, with four columns:

| Column | Holds |
|---|---|
| `site_key` | what ``BotKitConfiguration/siteKey`` returned |
| `path` | the request path, query string dropped |
| `bucket_start` | the start of the quarter-hour the views fell in |
| `views` | how many there were |

That is all. No cookie is set or read. No IP address, IP hash, user agent, referrer or per-visit timestamp is stored, not even briefly in a row that is later aggregated: views are added up in memory and only the sums are written. A row cannot be traced back to a visitor because nothing about a visitor ever reaches it.

The trade is that these are **views, not visitors**. With no identifier there is no way to tell one person reading two pages from two people reading one, and no way to follow a path through the site. That is deliberate.

Quarter-hours rather than hours because every time zone's offset from UTC is a whole number of quarter-hours: India's midnight falls at 18:30 UTC and Nepal's at 18:15, so an hourly bucket would put views on the wrong local day. With quarter-hours every local hour and day boundary the dashboard draws falls between two buckets.

### What counts as a page view

A request is counted when all of these hold:

- It is a `GET` answered `2xx` with an HTML body (`Content-Type: text/html`). Redirects, errors, JSON, feeds and files are not views.
- The user agent reads as a browser: it starts `Mozilla/`, is not an agent in ``AIAgentCatalog`` (those are on the AI agents tab), and does not name itself a bot, crawler, spider, headless browser, uptime monitor, link preview or HTTP library.
- It is not an HTMX swap (`HX-Request`), not a prefetch or prerender (`Sec-Purpose`, `Purpose` or `X-Moz: prefetch`), and when the browser sends `Sec-Fetch-Dest`, it is `document`.
- Its path is not skipped by recording: ``BotKitConfiguration/Recording/excludedPathPrefixes``, the ignored file extensions and the dashboard itself.

A bot that fakes a browser's user agent is counted, as it would be by any analytics that does not fingerprint. Counting is server-side, so it sees readers whose browsers block scripts or who never answer a consent banner.

### Turning it on

With ``BotKit/install(on:config:)``, set the option and the table is registered for you:

```swift
var config = BotKitConfiguration()
config.pageViews.isEnabled = true
try BotKit.install(on: app, config: config)
try await app.autoMigrate()
```

An app that registers migrations and routes separately passes `pageViews: true` to ``BotKit/configure(for:database:pageViews:)`` as well. ``BotKit/configureRoutes(for:config:)`` throws ``BotKitConfigurationError/pageViewsNotMigrated`` when counting is on but the table was not registered.

### Cost

Counting a view is a lock and a dictionary increment on the request path, after the response is ready. The counts are written every ``BotKitConfiguration/PageViews/flushInterval`` (ten seconds by default) in one statement that adds to the stored rows, so several app processes can share the table. They are written again when the application shuts down; a process that is killed loses at most one interval. A failed write keeps its counts for the next attempt.

Memory is bounded by ``BotKitConfiguration/PageViews/maximumPendingCounters``: the distinct site, path and quarter-hour counters held between writes. Paths come only from successful HTML responses, so an app that answers `404` for unknown paths cannot be made to grow it, but an app with a catch-all route could, and the cap stops that.

### Privacy notices

Whether a notice is required is a legal question for your jurisdiction, not something this package can settle. What it can tell you is exactly what is processed: the request headers above are read to decide whether to count, then discarded, and only the four columns are kept. Nothing is stored on the visitor's device.

## Topics

- ``BotKitConfiguration/PageViews``
