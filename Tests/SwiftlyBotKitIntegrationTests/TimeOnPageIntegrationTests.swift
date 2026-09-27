import Foundation
import XCTest
import XCTVapor
import SQLKit
@testable import SwiftlyBotKit

final class TimeOnPageIntegrationTests: PostgresIntegrationTestCase {

    private let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private func install(timeOnPage: Bool = true, dimensions: Bool = true) async throws -> PageViewCounter {
        var config = baseConfiguration()
        config.pageViews.isEnabled = true
        config.pageViews.dimensions.isEnabled = dimensions
        config.pageViews.timeOnPage.isEnabled = timeOnPage
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
        return try XCTUnwrap(app.storage[BotKit.PageViewCounterKey.self])
    }

    /// Like the other page view tables: counts, and nowhere to put the reader.
    func testTheTableHasNoColumnForTheReader() async throws {
        _ = try await install()
        let columns = try await sql().raw("""
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = \(bind: schema) AND table_name = 'page_view_durations' ORDER BY column_name
            """).all().map { try $0.decode(column: "column_name", as: String.self) }
        XCTAssertEqual(columns, ["band", "day", "path", "readings", "seconds", "site_key"])
    }

    /// The migration reverts cleanly, so a rolled-back deploy can drop it.
    func testTheMigrationReverts() async throws {
        _ = try await install()
        try await app.autoRevert()
        let row = try await sql().raw("SELECT to_regclass('page_view_durations') IS NULL AS gone").first()
        XCTAssertEqual(try row?.decode(column: "gone", as: Bool.self), true)
    }

    func testServesTheScriptAndKeepsAReadingEndToEnd() async throws {
        let counter = try await install()
        app.get("page") { _ -> Response in
            Response(status: .ok, headers: ["content-type": "text/html; charset=utf-8"], body: "<p>hi</p>")
        }
        try await app.test(.GET, "/_botkit/time.js") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.subType, "javascript")
            XCTAssertTrue(res.body.string.contains("\"/_botkit/time\""))
        }
        // A reading for a page nobody opened is dropped.
        try await app.test(.POST, "/_botkit/time", headers: ["User-Agent": safari, "Sec-Fetch-Site": "same-origin"],
                           body: ByteBuffer(string: "40\n/page")) { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        try await app.test(.GET, "/page", headers: ["User-Agent": safari])
        try await app.test(.POST, "/_botkit/time", headers: ["User-Agent": safari, "Sec-Fetch-Site": "same-origin"],
                           body: ByteBuffer(string: "40\n/page?x=1"))
        // A crawler's, and a cross-site one, are dropped.
        try await app.test(.POST, "/_botkit/time", headers: ["User-Agent": gptbotUA], body: ByteBuffer(string: "40\n/page"))
        try await app.test(.POST, "/_botkit/time", headers: ["User-Agent": safari, "Sec-Fetch-Site": "cross-site"],
                           body: ByteBuffer(string: "40\n/page"))
        await counter.flush()
        await counter.flush()

        let rows = try await sql().raw("SELECT path, band, readings, seconds FROM page_view_durations").all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try rows.first?.decode(column: "path", as: String.self), "/page")
        XCTAssertEqual(try rows.first?.decode(column: "band", as: Int.self), TimeOnPageBand.under1m.rawValue)
        XCTAssertEqual(try rows.first?.decode(column: "readings", as: Int.self), 1)
        XCTAssertEqual(try rows.first?.decode(column: "seconds", as: Int.self), 40)
        // Neither the script nor the beacon is an AI agent visit or a page view.
        let recorded = try await count()
        XCTAssertEqual(recorded, 0)
        let views = try await sql().raw("SELECT COALESCE(SUM(views), 0)::bigint AS n FROM page_view_counts").first()?
            .decode(column: "n", as: Int.self)
        XCTAssertEqual(views, 1)
    }

    func testOffServesNothing() async throws {
        _ = try await install(timeOnPage: false)
        try await app.test(.GET, "/_botkit/time.js") { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    func testFlushesAddUp() async throws {
        let counter = try await install()
        let now = Date()
        counter.record(siteKey: "a", path: "/x/", at: now)
        counter.recordTimeOnPage(siteKey: "a", path: "/x/", seconds: 20, at: now)
        await counter.flush()
        counter.recordTimeOnPage(siteKey: "a", path: "/x/", seconds: 25, at: now)
        await counter.flush()
        let row = try await sql().raw("SELECT readings, seconds FROM page_view_durations").first()
        XCTAssertEqual(try row?.decode(column: "readings", as: Int.self), 2)
        XCTAssertEqual(try row?.decode(column: "seconds", as: Int.self), 45)

        let data = try await PageViewQueries(database: sql(), timeZone: TimeZone(secondsFromGMT: 0)!)
            .timeOnPage(range: .week, siteKey: "a", paths: ["/x/"])
        XCTAssertEqual(data.total, .init(readings: 2, seconds: 45))
        XCTAssertEqual(data.bands[TimeOnPageBand.under30s.rawValue], 2)
        XCTAssertEqual(data.pages["/x/"]?.average, 23)
    }
}

final class PageViewInsightsIntegrationTests: PostgresIntegrationTestCase {

    func testComparesWithThePreviousPeriod() async throws {
        var config = baseConfiguration()
        config.pageViews.isEnabled = true
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
        let counter = try XCTUnwrap(app.storage[BotKit.PageViewCounterKey.self])
        let now = Date(timeIntervalSince1970: 1_790_400_000)
        let utc = TimeZone(secondsFromGMT: 0)!
        let start = BotDateRange.week.window(now: now, in: utc).start
        let span = now.timeIntervalSince(start)
        // Two views on two pages now, one a period ago, and one long before.
        counter.record(siteKey: "a", path: "/one/", at: now.addingTimeInterval(-3_600))
        counter.record(siteKey: "a", path: "/two/", at: now.addingTimeInterval(-3_600))
        counter.record(siteKey: "a", path: "/one/", at: start.addingTimeInterval(-span / 2))
        counter.record(siteKey: "a", path: "/one/", at: start.addingTimeInterval(-span * 3))
        await counter.flush()
        let reads = [now.addingTimeInterval(-60), now.addingTimeInterval(-120), start.addingTimeInterval(-60)]
        try await insertBotRows(at: reads, siteKey: "a", path: "/one/")
        try await insertBotRows(at: [now.addingTimeInterval(-60)], siteKey: "a", path: "/two/", agent: "ClaudeBot")

        let comparison = try await PageViewQueries(database: sql(), timeZone: utc)
            .comparison(range: .week, siteKey: "a", now: now)
        XCTAssertEqual(comparison.current.peopleViews, 2)
        XCTAssertEqual(comparison.current.peoplePages, 2)
        XCTAssertEqual(comparison.previous.peopleViews, 1)
        XCTAssertTrue(comparison.peopleComparable)
        XCTAssertEqual(comparison.current.agentReads, 3)
        XCTAssertEqual(comparison.current.agents, 2)
        XCTAssertEqual(comparison.current.agentPages, 2)
        // Every inserted row shares one hash.
        XCTAssertEqual(comparison.current.agentAddresses, 1)
        XCTAssertEqual(comparison.previous.agentReads, 1)
        XCTAssertFalse(comparison.agentsComparable)
    }

    func testRankingsFoldSmallValuesAndFindLandingPages() async throws {
        var config = baseConfiguration()
        config.pageViews.isEnabled = true
        config.pageViews.dimensions.isEnabled = true
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
        let counter = try XCTUnwrap(app.storage[BotKit.PageViewCounterKey.self])
        func facts(referer: String?) -> PageViewFacts {
            var headers = HTTPHeaders()
            headers.add(name: .userAgent, value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15")
            if let referer { headers.add(name: .referer, value: referer) }
            return PageViewFacts.derive(headers: headers, query: nil, host: "example.com", clientIP: nil, countries: nil)
        }
        let now = Date()
        for _ in 0..<6 { counter.record(siteKey: "a", path: "/", facts: facts(referer: "https://www.google.com/"), at: now) }
        for _ in 0..<2 { counter.record(siteKey: "a", path: "/", facts: facts(referer: "https://bing.com/"), at: now) }
        for _ in 0..<5 { counter.record(siteKey: "a", path: "/next/", facts: facts(referer: "https://example.com/"), at: now) }
        await counter.flush()

        let queries = PageViewQueries(database: sql(), timeZone: TimeZone(secondsFromGMT: 0)!)
        let referrers = try await queries.ranking(.referrer, range: .week, siteKey: "a",
                                                  excluding: [ReferrerSummary.internal], smallCellThreshold: 5)
        XCTAssertEqual(referrers.rows, [.init(value: "google.com", count: 6)])
        XCTAssertEqual(referrers.folded, 2)
        XCTAssertEqual(referrers.total, 8)
        let landing = try await queries.landingPages(range: .day, siteKey: "a")
        XCTAssertEqual(landing.rows, [.init(value: "/", count: 8)])
        XCTAssertTrue(landing.isDailyFallback)
    }

    func testTheTabShowsTheNewTilesAndCards() async throws {
        var config = baseConfiguration()
        config.pageViews.isEnabled = true
        config.pageViews.dimensions.isEnabled = true
        config.pageViews.timeOnPage.isEnabled = true
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
        let counter = try XCTUnwrap(app.storage[BotKit.PageViewCounterKey.self])
        counter.record(siteKey: "default", path: "/")
        counter.recordTimeOnPage(siteKey: "default", path: "/", seconds: 90)
        await counter.flush()
        let cookie = try await signIn()
        let (status, html) = try await dashboard("pages/?range=7d", cookie: cookie)
        XCTAssertEqual(status, .ok)
        for text in ["Unique visitors", "From AI assistants", "Time on page", "Top referrers", "Top landing pages"] {
            XCTAssertTrue(html.contains(text), text)
        }
    }
}
