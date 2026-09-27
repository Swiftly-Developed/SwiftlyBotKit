# Page views

Count how often people read each page, next to how often AI agents do, without storing anything about the people.

## Overview

The AI agent numbers mean more with something to compare them to. A page that ChatGPT-User fetched forty times last week is a different story when people read it four hundred times than when they read it four. Page views give that comparison, in the same dashboard, without a second analytics product.

They are off by default. When turned on, the dashboard gains a **Page views** tab at `<dashboard path>/pages/`, with the same site switcher and date ranges: tiles, a chart over time, and the most-read pages.

The tiles come in two rows, whichever audience is chosen, the chosen one first:

- **People**: page views, page views per hour (24-hour range) or day, unique pages, time on page (with ``BotKitConfiguration/PageViews/TimeOnPage`` on) and arrivals from AI assistants.
- **AI agents**: reads, unique visitors (distinct IP hashes, so one crawler fleet counts as many), distinct agents, reads per hour or day, and unique pages.

Each count shows its change against the previous period of the same length, the 24 hours or days just before the window. When counting began inside that previous period the change is left out, since a leap from zero would say nothing.

An audience filter chooses whose reads the tab shows (`?audience=` in the URL, kept by every link on the tab):

- **People** (the default): the page view counts described below, with each page's AI agent reads beside it.
- **AI agents**: successful `GET` page requests by agents in the catalog, from the same table the AI agents tab reads, with each page's page views beside it. `robots.txt`, sitemaps and failed requests are left out, since nobody reads those; they stay on the AI agents tab.
- **Combined**: both, stacked in two colours in the chart and in every page's bar, so the split stays visible.

When page views were turned on inside the chosen window, the chart says from when people were counted, and the people average covers only the time since.

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

An app that registers migrations and routes separately passes `pageViews: true` to ``BotKit/configure(for:database:pageViews:pageViewDimensions:)`` as well. ``BotKit/configureRoutes(for:config:)`` throws ``BotKitConfigurationError/pageViewsNotMigrated`` when counting is on but the table was not registered.

### Cost

Counting a view is a lock and a dictionary increment on the request path, after the response is ready. The counts are written every ``BotKitConfiguration/PageViews/flushInterval`` (ten seconds by default) in one statement that adds to the stored rows, so several app processes can share the table. They are written again when the application shuts down; a process that is killed loses at most one interval. A failed write keeps its counts for the next attempt.

Memory is bounded by ``BotKitConfiguration/PageViews/maximumPendingCounters``: the distinct site, path and quarter-hour counters held between writes. Paths come only from successful HTML responses, so an app that answers `404` for unknown paths cannot be made to grow it, but an app with a catch-all route could, and the cap stops that.

### Dimensions

With ``BotKitConfiguration/PageViews/Dimensions`` on, each counted view is also summarised into one coarse value per ``PageViewDimension``: country, referring host, previous page on the same site, the four `utm_` campaign tags, device type, browser, browser version, operating system, OS version and language. The summary is built in memory from the request and the raw headers, IP address and query string are dropped. Only counts are written:

| Table | Key | Answers |
|---|---|---|
| `page_view_dimension_counts` | site, day, dimension, value, path | any dimension by page |
| `page_view_pair_counts` | site, day, two dimensions and their values | any two dimensions against each other |

Days, not quarter-hours, and never more than two dimensions in a row, so each count describes many readers rather than one. Values come from closed lists or are sanitised: a host name but never a path, a campaign token only when it is plain letters, digits, `.`, `_` and `-` without a long run of digits, a browser family and a major version. `utm_term` is not read. An IP-literal referrer, an email address in a campaign link and anything else that could carry a person is stored as `(other)`.

The country is looked up in a local table (``CountryLookup``) built by `Scripts/update-country-database.py` from DB-IP's free country database; set ``BotKitConfiguration/PageViews/Dimensions/countryDatabasePath`` to it. The address is never sent anywhere. Without a table the country is simply left out.

```swift
config.pageViews.isEnabled = true
config.pageViews.dimensions.isEnabled = true
config.pageViews.dimensions.countryDatabasePath = "Data/country-ranges.bin"
```

An app that registers migrations separately passes `pageViewDimensions: true` to ``BotKit/configure(for:database:pageViews:pageViewDimensions:)``.

### Color by

The chart on the Page views tab has a **Color by** menu (`?color=`, kept by every link on the tab). **None** draws one colour per bar. **Page** and **Section** (the first path segment, so `/blog` and `/blog/some-article` are both `/blog/`) stack each bar by page, at the range's own buckets. Any dimension stacks it by that dimension's values; those are stored per day, so on the 24-hour range the chart shows yesterday and today as two daily bars.

Values are ranked by their total in the period and drawn in up to 23 colours, largest at the baseline; the rest go into **Other**, together with page views that have no value for the dimension (counted before dimensions were switched on, or without a country table), so every bar still adds up to the page views. Under the chart, every value's total for the period is listed in its colour, and each page in **Most-read pages** is split the same way. Values with fewer views than ``BotKitConfiguration/PageViews/Dimensions/smallCellThreshold`` (default 5) are counted in Other, and counts under it are shown as `<5`.

### Rankings

With dimensions on, three lists follow the most-read pages: the top referrers (moves between the site's own pages left out), the top countries, and the top landing pages, the pages views arrived at with no previous page on the same site. Referrers and countries under ``BotKitConfiguration/PageViews/Dimensions/smallCellThreshold`` are folded into one line. They are daily counts, so on the 24-hour range they cover yesterday and today.

### Time on page

With ``BotKitConfiguration/PageViews/TimeOnPage`` on, BotKit serves a script at ``BotKitConfiguration/PageViews/TimeOnPage/scriptPath`` (`/_botkit/time.js` by default) for the site to include in every page:

```html
<script src="/_botkit/time.js" defer></script>
```

While the page is visible, the script adds up the time. The first time the reader leaves, closes the tab or switches away, it posts one beacon to ``BotKitConfiguration/PageViews/TimeOnPage/path``: the whole seconds and `location.pathname`, as plain text. A page that was never visible sends nothing. It sets no cookie, uses no storage and sends no identifier.

The server answers `204` whatever it does with the beacon. It keeps the reading when the user agent reads as a browser (the same test page views use), the request is not cross-site, and this process counted a view of the page today or yesterday; a trailing slash is ignored when matching, and the reading is filed under the path the view was counted as. Readings are capped at 30 minutes, so a tab left open does not count as an afternoon of reading. They are summed in memory and written with the page views, into one table:

| Column | Holds |
|---|---|
| `site_key`, `day`, `path` | as the dimension counters |
| `band` | under 10 s, 10 to 30 s, 30 s to 1 min, 1 to 3 min, 3 to 10 min, 10 min or more |
| `readings` | how many readings fell in the band |
| `seconds` | their sum |

The tab shows the average, the band holding the median, the share under ten seconds, the spread over the bands and, beside each most-read page, its average once five readings make one. The table, `page_view_durations`, is registered with the page view tables, so turning this on needs only the script tag.

What it measures is time in view before the reader first leaves. Readers who block scripts, and readers of a site served by several processes whose beacon reaches one that has not counted that page, are not in it.

```swift
config.pageViews.isEnabled = true
config.pageViews.timeOnPage.isEnabled = true
```

### Privacy notices

Whether a notice is required is a legal question for your jurisdiction, not something this package can settle. What it can tell you is exactly what is processed: the request headers above are read to decide whether to count, then discarded, and only the four columns are kept. With dimensions on, the IP address is briefly processed to look up the country, which in the EU is processing of personal data even though nothing is kept, so name it in your privacy notice (legitimate interest is the usual basis). Nothing is stored on the visitor's device. With time on page on, the script sends the page's address and a number of seconds; name that too.

## Topics

- ``BotKitConfiguration/PageViews``
- ``BotKitConfiguration/PageViews/TimeOnPage``
