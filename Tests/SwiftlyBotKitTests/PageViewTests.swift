import XCTest
import XCTVapor
@testable import SwiftlyBotKit

let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
let chromeAndroidUA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36"

final class PageViewFilterTests: XCTestCase {

    private let filter = PageViewFilter(classifier: BotRequestClassifier(configuration: {
        var config = BotKitConfiguration()
        config.recording.excludedPathPrefixes = ["/healthz"]
        return config
    }()))

    private func counts(
        path: String = "/about/",
        method: HTTPMethod = .GET,
        userAgent: String? = safariUA,
        status: HTTPResponseStatus = .ok,
        contentType: String? = "text/html; charset=utf-8",
        headers extra: [(String, String)] = []
    ) -> Bool {
        var request = HTTPHeaders()
        if let userAgent { request.add(name: .userAgent, value: userAgent) }
        for (name, value) in extra { request.add(name: name, value: value) }
        var response = HTTPHeaders()
        if let contentType { response.add(name: .contentType, value: contentType) }
        return filter.counts(method: method, path: path, requestHeaders: request,
                             status: status, responseHeaders: response)
    }

    func testCountsABrowserReadingAPage() {
        XCTAssertTrue(counts())
        XCTAssertTrue(counts(userAgent: chromeAndroidUA))
        XCTAssertTrue(counts(headers: [("Sec-Fetch-Dest", "document"), ("Sec-Fetch-Mode", "navigate")]))
        XCTAssertTrue(counts(contentType: "TEXT/HTML"))
    }

    /// Only a successful HTML page is something a person read.
    func testSkipsWhatIsNotASuccessfulPage() {
        XCTAssertFalse(counts(method: .POST))
        XCTAssertFalse(counts(method: .HEAD))
        XCTAssertFalse(counts(status: .notFound))
        XCTAssertFalse(counts(status: .movedPermanently))
        XCTAssertFalse(counts(status: .notModified))
        XCTAssertFalse(counts(contentType: "application/json"))
        XCTAssertFalse(counts(contentType: "application/xml"))
        XCTAssertFalse(counts(contentType: nil))
    }

    /// Fragments, subresources and speculative loads are not page views.
    func testSkipsFragmentsAndPrefetches() {
        XCTAssertFalse(counts(headers: [("HX-Request", "true")]))
        XCTAssertFalse(counts(headers: [("Sec-Fetch-Dest", "empty")]))
        XCTAssertFalse(counts(headers: [("Sec-Fetch-Dest", "iframe")]))
        XCTAssertFalse(counts(headers: [("Sec-Purpose", "prefetch;prerender")]))
        XCTAssertFalse(counts(headers: [("Purpose", "prefetch")]))
        XCTAssertFalse(counts(headers: [("X-Moz", "prefetch")]))
    }

    func testSkipsAIAgentsAndOtherAutomatedClients() {
        for userAgent in [
            "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)",
            "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-User/1.0; +Claude-User@anthropic.com)",
            "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
            "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/128.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Linux; Android 11; moto g power (2022)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Mobile Safari/537.36 Chrome-Lighthouse",
            "Mozilla/5.0 (compatible; UptimeRobot/2.0; http://www.uptimerobot.com/)",
            "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
            "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)",
            "curl/8.7.1",
            "python-requests/2.32.3",
            "Go-http-client/2.0",
            "",
        ] {
            XCTAssertFalse(counts(userAgent: userAgent), userAgent)
        }
        XCTAssertFalse(counts(userAgent: nil))
    }

    /// CUBOT is a phone brand, not a bot.
    func testAPhoneWhoseModelNameContainsBotStillCounts() {
        XCTAssertTrue(counts(userAgent: "Mozilla/5.0 (Linux; Android 10; CUBOT X30) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"))
    }

    /// The same path rules as recording: assets, the dashboard, excluded
    /// prefixes.
    func testSkipsExcludedPaths() {
        XCTAssertFalse(counts(path: "/admin/ai-bots/"))
        XCTAssertFalse(counts(path: "/admin/ai-bots/pages/"))
        XCTAssertFalse(counts(path: "/healthz"))
        XCTAssertFalse(counts(path: "/logo.png"))
    }
}

final class PageViewTallyTests: XCTestCase {

    private func key(_ path: String = "/", bucket: Int64 = 0) -> PageViewTally.Key {
        .init(siteKey: "default", path: path, bucketStart: bucket)
    }

    func testBucketsAreQuarterHours() {
        // 2026-09-25 10:07:30 UTC.
        let date = Date(timeIntervalSince1970: 1_790_330_850)
        let start = PageViewTally.bucketStart(for: date)
        XCTAssertEqual(start % 900, 0)
        XCTAssertEqual(start, 1_790_330_400) // 10:00:00
        XCTAssertEqual(PageViewTally.bucketStart(for: Date(timeIntervalSince1970: 1_790_331_300)), 1_790_331_300)
        XCTAssertEqual(PageViewTally.bucketStart(for: Date(timeIntervalSince1970: 1_790_331_299.9)), 1_790_330_400)
    }

    func testAddsUpAndDrains() {
        let tally = PageViewTally(maximumKeys: 10)
        XCTAssertNil(tally.add(key("/a")))
        XCTAssertNil(tally.add(key("/a")))
        XCTAssertNil(tally.add(key("/b")))
        XCTAssertNil(tally.add(key("/a", bucket: 900)))
        let drained = tally.drain()
        XCTAssertEqual(drained[key("/a")], 2)
        XCTAssertEqual(drained[key("/b")], 1)
        XCTAssertEqual(drained[key("/a", bucket: 900)], 1)
        XCTAssertEqual(tally.pendingKeys, 0)
    }

    /// A full tally still counts pages it already holds; only new ones drop.
    func testAFullTallyDropsOnlyNewCounters() {
        let tally = PageViewTally(maximumKeys: 1)
        XCTAssertNil(tally.add(key("/a")))
        XCTAssertEqual(tally.add(key("/b")), 1)
        XCTAssertEqual(tally.add(key("/c")), 2)
        XCTAssertNil(tally.add(key("/a")))
        XCTAssertEqual(tally.drain(), [key("/a"): 2])
    }

    func testRestoreMergesAndReportsWhatDidNotFit() {
        let tally = PageViewTally(maximumKeys: 2)
        _ = tally.add(key("/a"))
        let lost = tally.restore([key("/a"): 4, key("/b"): 1, key("/c"): 7])
        let drained = tally.drain()
        XCTAssertEqual(drained[key("/a")], 5)
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(lost, drained[key("/b")] == nil ? 1 : 7)
    }

    /// With no database registered, counts wait in memory instead of vanishing.
    func testFlushWithoutADatabaseKeepsTheCounts() async {
        let counter = PageViewCounter(database: { nil }, configuration: .init(isEnabled: true), logger: Logger(label: "test"))
        counter.record(siteKey: "default", path: "/a")
        counter.record(siteKey: "default", path: "/a")
        await counter.flush()
        XCTAssertEqual(counter.tally.drain().values.reduce(0, +), 2)
        await counter.shutdown()
    }
}

final class PageViewInstallTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    private func configuration() -> BotKitConfiguration {
        var config = BotKitConfiguration(signingSecret: "test-secret")
        // No database here, so nothing may try to write a bot row.
        config.recording = .init(recordsAgents: false, recordsReferrals: false)
        config.verification.isEnabled = false
        config.pageViews.isEnabled = true
        config.dashboard.username = "owner"
        config.dashboard.password = "correct horse"
        return config
    }

    func testOffByDefault() {
        XCTAssertEqual(BotKitConfiguration().pageViews, .default)
        XCTAssertFalse(BotKitConfiguration.PageViews.default.isEnabled)
        XCTAssertEqual(BotKitConfiguration.PageViews.default.flushInterval, 10)
        XCTAssertEqual(BotKitConfiguration.PageViews.default.maximumPendingCounters, 10_000)
    }

    func testEnablingWithoutTheMigrationThrows() throws {
        BotKit.configure(for: app)
        XCTAssertThrowsError(try BotKit.configureRoutes(for: app, config: configuration())) { error in
            XCTAssertEqual(error as? BotKitConfigurationError, .pageViewsNotMigrated)
        }
    }

    func testInstallRegistersTheMigration() throws {
        try BotKit.install(on: app, config: configuration())
        XCTAssertEqual(app.storage[BotKit.InstallationKey.self]?.pageViewsMigrationRegistered, true)
        XCTAssertNotNil(app.storage[BotKit.PageViewCounterKey.self])
    }

    func testOffInstallsNoCounterAndNoTab() async throws {
        var config = configuration()
        config.pageViews.isEnabled = false
        try BotKit.install(on: app, config: config)
        XCTAssertEqual(app.storage[BotKit.InstallationKey.self]?.pageViewsMigrationRegistered, false)
        XCTAssertNil(app.storage[BotKit.PageViewCounterKey.self])
        try await app.test(.GET, "/admin/ai-bots/pages/") { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    /// The middleware counts a browser's page, and nothing else, without a
    /// database and without changing the response.
    func testMiddlewareCountsBrowserPagesOnly() async throws {
        try BotKit.install(on: app, config: configuration())
        app.get("about") { _ -> Response in
            Response(status: .ok, headers: ["content-type": "text/html; charset=utf-8"], body: "<p>hi</p>")
        }
        app.get("api", "thing") { _ in ["ok": true] }
        let counter = try XCTUnwrap(app.storage[BotKit.PageViewCounterKey.self])

        try await app.test(.GET, "/about/?utm_source=x", headers: ["User-Agent": safariUA]) { res async in
            XCTAssertEqual(res.body.string, "<p>hi</p>")
        }
        try await app.test(.GET, "/about/", headers: ["User-Agent": safariUA])
        try await app.test(.GET, "/about/", headers: ["User-Agent": "curl/8.7.1"])
        try await app.test(.GET, "/api/thing", headers: ["User-Agent": safariUA])
        try await app.test(.GET, "/missing/", headers: ["User-Agent": safariUA])

        let counts = counter.tally.drain()
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first?.key.path, "/about/")
        XCTAssertEqual(counts.first?.key.siteKey, "default")
        XCTAssertEqual(counts.first?.value, 2)
    }

    /// The page views tab sits behind the same sign-in as the dashboard.
    func testThePageViewsTabNeedsASignIn() async throws {
        try BotKit.install(on: app, config: configuration())
        try await app.test(.GET, "/admin/ai-bots/pages/") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("action=\"/admin/ai-bots/login\""))
            XCTAssertFalse(res.body.string.contains("Most-viewed pages"))
        }
    }
}

final class PageViewRenderingTests: XCTestCase {

    private let sites = [
        BotDashboardSite(key: "a", name: "Site A"),
        BotDashboardSite(key: "b", name: "Site B"),
    ]

    private func sample() -> PageViewData {
        var data = PageViewData()
        data.people = 1_234
        data.agents = 300
        data.distinctPages = 2
        data.series = BotDateRange.week.buckets(now: Date(), in: .gmt).map { .init(bucket: $0, people: 10, agents: 3) }
        data.peopleBucketCount = 7
        data.topPages = [
            .init(path: "/pricing/", people: 900, agents: 12),
            .init(path: "/<script>alert(1)</script>", people: 334, agents: 0),
        ]
        return data
    }

    func testRendersTotalsPagesAndEscapesPaths() {
        let html = PageViewsPage.render(data: sample(), range: .week, sites: sites, selectedSite: sites[1], generatedAt: Date())
        XCTAssertTrue(html.contains("1,234"))
        XCTAssertTrue(html.contains("/pricing/"))
        XCTAssertTrue(html.contains("12 AI agent"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        // The tabs keep the site and range.
        XCTAssertTrue(html.contains("href=\"/admin/ai-bots/?site=b&amp;range=7d\""))
        XCTAssertTrue(html.contains("aria-current=\"page\">Page views"))
        // Range pills and the switcher stay on this tab.
        XCTAssertTrue(html.contains("href=\"/admin/ai-bots/pages/?site=b&amp;range=24h\""))
        XCTAssertTrue(html.contains("href=\"/admin/ai-bots/pages/?site=all&amp;range=7d\""))
    }

    /// The audience pills, and every other link on the tab keeping the choice.
    func testAudienceFilterLinks() {
        let people = PageViewsPage.render(data: sample(), range: .week, sites: sites, selectedSite: sites[1], generatedAt: Date())
        XCTAssertTrue(people.contains("aria-current=\"true\">People"))
        XCTAssertTrue(people.contains("href=\"/admin/ai-bots/pages/?site=b&amp;range=7d&amp;audience=agents\""))
        XCTAssertTrue(people.contains("href=\"/admin/ai-bots/pages/?site=b&amp;range=7d&amp;audience=all\""))

        let combined = PageViewsPage.render(data: sample(), range: .week, sites: sites, selectedSite: sites[1],
                                            generatedAt: Date(), audience: .combined)
        XCTAssertTrue(combined.contains("aria-current=\"true\">Combined"))
        XCTAssertTrue(combined.contains("href=\"/admin/ai-bots/pages/?site=b&amp;range=24h&amp;audience=all\""), "range pills keep it")
        XCTAssertTrue(combined.contains("href=\"/admin/ai-bots/pages/?site=all&amp;range=7d&amp;audience=all\""), "site switcher keeps it")
        XCTAssertTrue(combined.contains("href=\"/admin/ai-bots/pages/?site=b&amp;range=7d\""), "People is the plain URL")
        XCTAssertTrue(combined.contains("href=\"/admin/ai-bots/?site=b&amp;range=7d\""), "the agents tab drops it")
        XCTAssertEqual(PageViewAudience(query: "all"), .combined)
        XCTAssertEqual(PageViewAudience(query: "nonsense"), .people)
        XCTAssertEqual(PageViewAudience(query: nil), .people)
    }

    func testEachAudienceShowsItsOwnNumbers() {
        let data = sample()
        let agents = PageViewsPage.render(data: data, range: .week, sites: [], selectedSite: nil,
                                          generatedAt: Date(), audience: .agents)
        XCTAssertTrue(agents.contains("AI agent reads"))
        XCTAssertTrue(agents.contains(">300<"))
        XCTAssertTrue(agents.contains("900 people"), "people beside each page")

        let combined = PageViewsPage.render(data: data, range: .week, sites: [], selectedSite: nil,
                                            generatedAt: Date(), audience: .combined)
        XCTAssertTrue(combined.contains(">1,534<"), "the sum")
        XCTAssertTrue(combined.contains("900 people \u{00B7} 12 AI"))
        XCTAssertTrue(combined.contains(">80%<"), "share read by people")
        // Two marks per populated column, and a legend naming both.
        XCTAssertEqual(combined.components(separatedBy: "\u{00B7} People: 10</title>").count - 1, 7)
        XCTAssertEqual(combined.components(separatedBy: "\u{00B7} AI agents: 3</title>").count - 1, 7)
    }

    func testCombinedBarDrawsPeopleInsideTheTotal() {
        let row = PageViewsPage.row(for: .init(path: "/", people: 61, agents: 38), audience: .combined)
        XCTAssertEqual(row.value, 99)
        XCTAssertEqual(row.highlight, 61)
        XCTAssertEqual(row.color, PageViewsPage.agentsColor)
        XCTAssertEqual(row.highlightColor, PageViewsPage.peopleColor)
    }

    /// Counting began inside the window: the average only spans the buckets
    /// since, and the chart says so.
    func testPartialWindowIsLabelled() {
        var data = sample()
        data.people = 109
        data.peopleBucketCount = 1
        data.peopleCountedSince = Date(timeIntervalSince1970: 1_790_330_400)
        let html = PageViewsPage.render(data: data, range: .week, sites: [], selectedSite: nil, generatedAt: Date())
        XCTAssertTrue(html.contains(">109<"))
        XCTAssertTrue(html.contains("average since counting began"))
        XCTAssertTrue(html.contains("People are counted from"))
        let agents = PageViewsPage.render(data: data, range: .week, sites: [], selectedSite: nil,
                                          generatedAt: Date(), audience: .agents)
        XCTAssertFalse(agents.contains("People are counted from"), "irrelevant to the agents view")
    }

    func testShare() {
        XCTAssertEqual(PageViewsPage.share(80, of: 100), "80%")
        XCTAssertEqual(PageViewsPage.share(1, of: 1_000), "<1%")
        XCTAssertEqual(PageViewsPage.share(999, of: 1_000), ">99%")
        XCTAssertEqual(PageViewsPage.share(0, of: 10), "0%")
        XCTAssertEqual(PageViewsPage.share(0, of: 0), "\u{2013}")
        XCTAssertEqual(PageViewsPage.peopleRatio(agents: 400, people: 100), "1 for every 4 AI agent reads")
    }

    func testEmptyWindow() {
        let html = PageViewsPage.render(data: PageViewData(), range: .day, sites: [], selectedSite: nil, generatedAt: Date())
        XCTAssertTrue(html.contains("No page views in the last 24 hours."))
    }

    func testTheAgentsTabLinksToPageViewsOnlyWhenEnabled() {
        let on = DashboardPage.render(data: BotDashboardData(), range: .week, sites: sites, selectedSite: nil,
                                      generatedAt: Date(), showsPageViews: true)
        XCTAssertTrue(on.contains("href=\"/admin/ai-bots/pages/?site=all&amp;range=7d\""))
        let off = DashboardPage.render(data: BotDashboardData(), range: .week, sites: sites, selectedSite: nil,
                                       generatedAt: Date())
        XCTAssertFalse(off.contains("/pages/"))
    }

    func testAverageKeepsADecimalWhenSmall() {
        XCTAssertEqual(PageViewsPage.average(views: 9, buckets: 24), "0.4")
        XCTAssertEqual(PageViewsPage.average(views: 0, buckets: 24), "0")
        XCTAssertEqual(PageViewsPage.average(views: 70, buckets: 7), "10")
        XCTAssertEqual(PageViewsPage.average(views: 48, buckets: 24), "2")
        XCTAssertEqual(PageViewsPage.average(views: 90_000, buckets: 7), "12.9K")
    }

    func testAgentRatio() {
        XCTAssertEqual(PageViewsPage.agentRatio(views: 400, agents: 100), "1 for every 4 page views")
        XCTAssertEqual(PageViewsPage.agentRatio(views: 250, agents: 100), "1 for every 2.5 page views")
        XCTAssertEqual(PageViewsPage.agentRatio(views: 100, agents: 300), "3 per page view")
        XCTAssertEqual(PageViewsPage.agentRatio(views: 100, agents: 102), "about one per page view")
        XCTAssertEqual(PageViewsPage.agentRatio(views: 100, agents: 0), "none in this window")
        XCTAssertEqual(PageViewsPage.agentRatio(views: 0, agents: 5), "and no page views")
    }
}
