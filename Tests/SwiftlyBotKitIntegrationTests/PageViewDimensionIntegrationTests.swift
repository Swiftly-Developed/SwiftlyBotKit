import Foundation
import XCTest
import XCTVapor
import SQLKit
@testable import SwiftlyBotKit

final class PageViewDimensionIntegrationTests: PostgresIntegrationTestCase {

    private func install() async throws -> PageViewCounter {
        var config = baseConfiguration()
        config.pageViews.isEnabled = true
        config.pageViews.dimensions.isEnabled = true
        config.dashboard.timeZone = .europeBrussels
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
        return try XCTUnwrap(app.storage[BotKit.PageViewCounterKey.self])
    }

    private func columns(of table: String) async throws -> [String] {
        try await sql().raw("""
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = \(bind: schema) AND table_name = \(bind: table) ORDER BY column_name
            """).all().map { try $0.decode(column: "column_name", as: String.self) }
    }

    /// The tables hold coarse values and counts, and have nowhere to put
    /// anything about a visitor. A new column here is a privacy decision,
    /// not a refactor.
    func testTheTablesHaveNoColumnForTheVisitor() async throws {
        _ = try await install()
        let dimensionColumns = try await columns(of: "page_view_dimension_counts")
        let pairColumns = try await columns(of: "page_view_pair_counts")
        XCTAssertEqual(dimensionColumns, ["day", "dimension", "path", "site_key", "value", "views"])
        XCTAssertEqual(pairColumns, ["day", "first_dimension", "first_value", "second_dimension", "second_value", "site_key", "views"])
    }

    /// The migrations revert cleanly, so a rolled-back deploy can drop them.
    func testTheMigrationsRevert() async throws {
        _ = try await install()
        try await app.autoRevert()
        let row = try await sql().raw("""
            SELECT to_regclass('page_view_dimension_counts') IS NULL AND to_regclass('page_view_pair_counts') IS NULL AS gone
            """).first()
        XCTAssertEqual(try row?.decode(column: "gone", as: Bool.self), true)
    }

    func testTheTablesAreOnlyCreatedWhenEnabled() async throws {
        var config = baseConfiguration()
        config.pageViews.isEnabled = true
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
        let row = try await sql().raw("SELECT to_regclass('page_view_dimension_counts') IS NOT NULL AS present").first()
        XCTAssertEqual(try row?.decode(column: "present", as: Bool.self), false)
    }

    /// Flushes add up, on the Brussels day, and each dimension sums to the
    /// page views.
    func testFlushesAddUpPerLocalDay() async throws {
        let counter = try await install()
        var headers = HTTPHeaders()
        headers.add(name: .userAgent, value: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")
        headers.add(name: .referer, value: "https://www.google.com/")
        let facts = PageViewFacts.derive(headers: headers, query: nil, host: "example.com", clientIP: nil, countries: nil)
        // 22:30 UTC on the 26th is the 27th in Brussels.
        let late = Date(timeIntervalSince1970: 1_790_461_800)
        counter.record(siteKey: "a", path: "/x/", facts: facts, at: late)
        counter.record(siteKey: "a", path: "/x/", facts: facts, at: late)
        await counter.flush()
        counter.record(siteKey: "a", path: "/x/", facts: facts, at: late)
        await counter.flush()

        let rows = try await sql().raw("""
            SELECT day::text AS day, value, views FROM page_view_dimension_counts WHERE dimension = 'device'
            """).all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try rows[0].decode(column: "day", as: String.self), "2026-09-27")
        XCTAssertEqual(try rows[0].decode(column: "value", as: String.self), "mobile")
        XCTAssertEqual(try rows[0].decode(column: "views", as: Int.self), 3)

        let pair = try await sql().raw("""
            SELECT views FROM page_view_pair_counts
            WHERE first_dimension = 'referrer' AND first_value = 'google.com'
              AND second_dimension = 'device' AND second_value = 'mobile'
            """).first()
        XCTAssertEqual(try pair?.decode(column: "views", as: Int.self), 3)

        let sums = try await sql().raw("""
            SELECT dimension, SUM(views)::bigint AS n FROM page_view_dimension_counts GROUP BY dimension
            """).all()
        XCTAssertEqual(sums.count, PageViewDimension.allCases.count - 1)
        XCTAssertTrue(try sums.allSatisfy { try $0.decode(column: "n", as: Int.self) == 3 })
    }

    func testCountsBrowserPagesWithDimensionsEndToEnd() async throws {
        let counter = try await install()
        app.get("page") { _ -> Response in
            Response(status: .ok, headers: ["content-type": "text/html; charset=utf-8"], body: "<p>hi</p>")
        }
        try await app.test(.GET, "/page/?utm_source=Newsletter", headers: [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept-Language": "nl-BE,nl;q=0.9",
        ])
        await counter.flush()
        let rows = try await sql().raw("""
            SELECT dimension, value FROM page_view_dimension_counts
            WHERE dimension IN ('utm_source', 'language', 'browser') ORDER BY dimension
            """).all()
        let values = try rows.map { try $0.decode(column: "dimension", as: String.self) + "=" + $0.decode(column: "value", as: String.self) }
        XCTAssertEqual(values, ["browser=Safari", "language=nl", "utm_source=newsletter"])
    }
}

final class PageViewBreakdownIntegrationTests: PostgresIntegrationTestCase {

    func testBreakdownsByPageSectionAndDimension() async throws {
        var config = baseConfiguration()
        config.pageViews.isEnabled = true
        config.pageViews.dimensions.isEnabled = true
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
        let counter = try XCTUnwrap(app.storage[BotKit.PageViewCounterKey.self])
        let now = Date(timeIntervalSince1970: 1_790_400_000)
        var headers = HTTPHeaders()
        headers.add(name: .userAgent, value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15")
        let facts = PageViewFacts.derive(headers: headers, query: nil, host: nil, clientIP: nil, countries: nil)
        for _ in 0..<6 { counter.record(siteKey: "a", path: "/blog/one/", facts: facts, at: now.addingTimeInterval(-3_600)) }
        for _ in 0..<2 { counter.record(siteKey: "a", path: "/blog/two/", facts: facts, at: now.addingTimeInterval(-3_600)) }
        // Counted without dimensions: they land in Other.
        for _ in 0..<3 { counter.record(siteKey: "a", path: "/", at: now.addingTimeInterval(-7_200)) }
        await counter.flush()

        let queries = PageViewQueries(database: sql(), timeZone: TimeZone(secondsFromGMT: 0)!)
        let pagesResult = try await queries.breakdown(.page, range: .week, siteKey: "a", smallCellThreshold: 5, now: now)
        let pages = try XCTUnwrap(pagesResult)
        XCTAssertEqual(pages.series.map(\.label), ["/blog/one/", "/", "/blog/two/"])
        let sectionsResult = try await queries.breakdown(.section, range: .day, siteKey: "a", smallCellThreshold: 5, now: now)
        let sections = try XCTUnwrap(sectionsResult)
        XCTAssertEqual(sections.series.map(\.label), ["/blog/", "/"])
        XCTAssertEqual(sections.buckets.count, 24)
        let topPages: [PageViewData.PageRow] = [.init(path: "/blog/one/", people: 6, agents: 0), .init(path: "/", people: 3, agents: 0)]
        let browsersResult = try await queries.breakdown(.dimension(.browser), range: .day, siteKey: "a",
                                                          smallCellThreshold: 5, pages: topPages, now: now)
        let browsers = try XCTUnwrap(browsersResult)
        XCTAssertTrue(browsers.isDailyFallback)
        XCTAssertEqual(browsers.buckets.count, 2)
        XCTAssertEqual(browsers.series.map(\.label), ["Safari", "Other"])
        XCTAssertEqual(browsers.series.map(\.total), [8, 3])
        XCTAssertEqual(browsers.pageSplits["/blog/one/"], [6, 0])
        XCTAssertEqual(browsers.pageSplits["/"], [0, 3])
        let sectionSplit = try await queries.breakdown(.section, range: .week, siteKey: "a", smallCellThreshold: 5,
                                                       pages: topPages, now: now)
        XCTAssertEqual(sectionSplit?.pageSplits["/blog/one/"], [6, 0])
        let none = try await queries.breakdown(.none, range: .week, siteKey: "a", smallCellThreshold: 5, now: now)
        XCTAssertNil(none)
    }
}
