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
