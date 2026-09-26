import Foundation
import XCTest
import XCTVapor
import SQLKit
@testable import SwiftlyBotKit

private let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

final class PageViewIntegrationTests: PostgresIntegrationTestCase {

    private func install(timeZone: BotKitTimeZone = .utc) async throws -> PageViewCounter {
        var config = baseConfiguration()
        config.pageViews.isEnabled = true
        config.dashboard.timeZone = timeZone
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
        return try XCTUnwrap(app.storage[BotKit.PageViewCounterKey.self])
    }

    private func storedViews(_ whereClause: String = "TRUE") async throws -> Int {
        let row = try await sql().raw("SELECT COALESCE(SUM(views), 0)::bigint AS n FROM page_view_counts WHERE \(unsafeRaw: whereClause)").first()
        return try row?.decode(column: "n", as: Int.self) ?? 0
    }

    /// The table holds counters and nothing else.
    func testTheTableHasNoColumnForTheVisitor() async throws {
        _ = try await install()
        let columns = try await sql().raw("""
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = \(bind: schema) AND table_name = 'page_view_counts' ORDER BY column_name
            """).all().map { try $0.decode(column: "column_name", as: String.self) }
        XCTAssertEqual(columns, ["bucket_start", "path", "site_key", "views"])
    }

    func testTheTableIsOnlyCreatedWhenEnabled() async throws {
        try BotKit.install(on: app, config: baseConfiguration())
        try await app.autoMigrate()
        let row = try await sql().raw("SELECT to_regclass('page_view_counts') IS NOT NULL AS present").first()
        XCTAssertEqual(try row?.decode(column: "present", as: Bool.self), false)
    }

    /// Flushes add to what is stored rather than replacing it, which is also
    /// what keeps several app processes from overwriting each other.
    func testFlushesAddUp() async throws {
        let counter = try await install()
        let at = Date(timeIntervalSince1970: 1_790_330_850)
        for _ in 0..<3 { counter.record(siteKey: "a", path: "/x/", at: at) }
        counter.record(siteKey: "a", path: "/x/", at: at.addingTimeInterval(900))
        counter.record(siteKey: "b", path: "/x/", at: at)
        await counter.flush()
        for _ in 0..<2 { counter.record(siteKey: "a", path: "/x/", at: at) }
        await counter.flush()

        let rows = try await sql().raw("SELECT COUNT(*) AS n FROM page_view_counts").first()
        XCTAssertEqual(try rows?.decode(column: "n", as: Int.self), 3)
        let sameQuarterHour = try await storedViews("site_key = 'a' AND bucket_start = to_timestamp(1790330400)")
        let all = try await storedViews()
        XCTAssertEqual(sameQuarterHour, 5)
        XCTAssertEqual(all, 7)
    }

    /// Through HTTP, then the lifecycle's shutdown flush.
    func testCountsBrowserPagesEndToEnd() async throws {
        let counter = try await install()
        app.get("guide") { _ -> Response in
            Response(status: .ok, headers: ["content-type": "text/html; charset=utf-8"], body: "<p>guide</p>")
        }
        for _ in 0..<2 {
            try await app.test(.GET, "/guide/", headers: ["User-Agent": browserUA])
        }
        try await app.test(.GET, "/guide/", headers: ["User-Agent": gptbotUA])
        try await app.test(.GET, "/guide/", headers: ["User-Agent": browserUA, "HX-Request": "true"])
        await counter.shutdown()

        let views = try await storedViews("path = '/guide/'")
        XCTAssertEqual(views, 2)
        // The AI agent went to its own table as usual.
        try await waitForRows(1, where: "agent_name = 'GPTBot'")
    }

    func testThePageViewsTab() async throws {
        let counter = try await install()
        let now = Date()
        for _ in 0..<40 { counter.record(siteKey: "default", path: "/pricing/", at: now) }
        for _ in 0..<5 { counter.record(siteKey: "default", path: "/about/", at: now) }
        await counter.flush()
        try await insertBotRows(at: Array(repeating: now, count: 10), path: "/pricing/")

        let cookie = try await signIn()
        let (status, body) = try await dashboard("pages/?range=7d", cookie: cookie)
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(body.contains("Most-read pages"))
        XCTAssertTrue(body.contains(">45<"), "total views tile")
        XCTAssertTrue(body.contains("/pricing/"))
        XCTAssertTrue(body.contains("10 AI agent"))
        XCTAssertTrue(body.contains("1 for every 4.5 page views"))

        // AI agents only, and both combined.
        let (_, agentsOnly) = try await dashboard("pages/?range=7d&audience=agents", cookie: cookie)
        XCTAssertTrue(agentsOnly.contains(">10<"), "AI agent reads tile")
        XCTAssertTrue(agentsOnly.contains("40 people"))
        let (_, combined) = try await dashboard("pages/?range=7d&audience=all", cookie: cookie)
        XCTAssertTrue(combined.contains(">55<"), "people plus agents")
        XCTAssertTrue(combined.contains("40 people \u{00B7} 10 AI"))

        // And the agents tab links to it.
        let (_, agents) = try await dashboard("?range=7d", cookie: cookie)
        XCTAssertTrue(agents.contains("/admin/ai-bots/pages/?site=all&amp;range=7d"))
    }

    /// India is UTC+05:30, so its midnight falls on a UTC half-hour. Views at
    /// 18:15 and 18:45 UTC are on different local days, and quarter-hour
    /// buckets keep them apart where hourly ones could not.
    func testQuarterHoursLandOnTheRightLocalDay() async throws {
        let counter = try await install(timeZone: .asiaKolkata)
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        // 2026-09-24 18:15 and 18:45 UTC: 23:45 on the 24th and 00:15 on the
        // 25th in Kolkata.
        let before = Date(timeIntervalSince1970: 1_790_273_700)
        let after = Date(timeIntervalSince1970: 1_790_275_500)
        counter.record(siteKey: "default", path: "/", at: before)
        for _ in 0..<3 { counter.record(siteKey: "default", path: "/", at: after) }
        await counter.flush()

        let now = Date(timeIntervalSince1970: 1_790_300_000) // 25 Sep, 07:03 in Kolkata
        let data = try await PageViewQueries(database: sql(), timeZone: zone).load(range: .week, siteKey: nil, now: now)
        let labels = data.series.map { BotDateRange.week.axisLabel(for: $0.bucket, in: zone) }
        let byDay = Dictionary(uniqueKeysWithValues: zip(labels, data.series.map(\.people)))
        XCTAssertEqual(byDay["24 Sep"], 1)
        XCTAssertEqual(byDay["25 Sep"], 3)
        XCTAssertEqual(data.people, 4)
    }

    /// AI agent reads are page reads only: robots.txt, sitemaps, errors and
    /// POSTs stay on the AI agents tab. Pages rank by the chosen audience.
    func testAgentReadsAndRankingPerAudience() async throws {
        let counter = try await install()
        let now = Date()
        for _ in 0..<5 { counter.record(siteKey: "default", path: "/human-favourite/", at: now) }
        counter.record(siteKey: "default", path: "/bot-favourite/", at: now)
        await counter.flush()
        try await insertBotRows(at: Array(repeating: now, count: 8), path: "/bot-favourite/")
        try await insertBotRows(at: Array(repeating: now, count: 3), path: "/robots.txt")
        try await insertBotRows(at: Array(repeating: now, count: 2), path: "/sitemap.xml")
        try await sql().raw("UPDATE ai_bot_visits SET status_code = 404 WHERE ctid IN (SELECT ctid FROM ai_bot_visits WHERE path = '/bot-favourite/' LIMIT 2)").run()

        let queries = PageViewQueries(database: sql(), timeZone: TimeZone(identifier: "UTC")!)
        let people = try await queries.load(range: .week, siteKey: nil, audience: .people, now: now.addingTimeInterval(60))
        XCTAssertEqual(people.people, 6)
        XCTAssertEqual(people.agents, 6, "8 fetches minus 2 errors; robots.txt and the sitemap do not count")
        XCTAssertEqual(people.topPages.map(\.path), ["/human-favourite/", "/bot-favourite/"])
        XCTAssertEqual(people.distinctPages, 2)

        let agents = try await queries.load(range: .week, siteKey: nil, audience: .agents, now: now.addingTimeInterval(60))
        XCTAssertEqual(agents.topPages, [.init(path: "/bot-favourite/", people: 1, agents: 6)])
        XCTAssertEqual(agents.distinctPages, 1)

        let combined = try await queries.load(range: .week, siteKey: nil, audience: .combined, now: now.addingTimeInterval(60))
        XCTAssertEqual(combined.topPages.first, .init(path: "/bot-favourite/", people: 1, agents: 6))
        XCTAssertEqual(combined.series.reduce(0) { $0 + $1.people + $1.agents }, 12)
    }
}
