import Foundation
import XCTest
import XCTVapor
import SQLKit
@testable import SwiftlyBotKit

/// The export's queries and route over real rows.
final class ExportIntegrationTests: PostgresIntegrationTestCase {

    private let brussels = TimeZone(identifier: "Europe/Brussels")!

    private func install(pageViews: Bool = true) async throws {
        var config = baseConfiguration()
        config.pageViews.isEnabled = pageViews
        config.dashboard.timeZone = .europeBrussels
        config.sites = [.init(key: "alpha", name: "Alpha"), .init(key: "beta", name: "Beta")]
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
    }

    private func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func insertReferrals(_ count: Int, at instant: Date, siteKey: String = "alpha", platform: String = "ChatGPT") async throws {
        try await sql().raw("""
            INSERT INTO ai_bot_visits (id, site_key, path, method, status_code, verification, referrer_platform, ip_hash, created_at)
            SELECT gen_random_uuid(), \(bind: siteKey), '/landing', 'GET', 200, 'notApplicable', \(bind: platform), 'h', \(bind: instant)
            FROM generate_series(1, \(bind: count))
            """).run()
    }

    private func insertViews(_ views: Int, at bucket: Date, siteKey: String = "alpha", path: String = "/") async throws {
        try await sql().raw("""
            INSERT INTO page_view_counts (site_key, bucket_start, path, views)
            VALUES (\(bind: siteKey), \(bind: bucket), \(bind: path), \(bind: views))
            """).run()
    }

    /// 1 to 3 September 2026 in Brussels (CEST, UTC+2).
    private func seed() async throws {
        // 1 Sep: three GPTBot page reads and one robots.txt fetch.
        try await insertBotRows(at: Array(repeating: at("2026-09-01T10:00:00Z"), count: 3), siteKey: "alpha", path: "/a")
        try await insertBotRows(at: [at("2026-09-01T11:00:00Z")], siteKey: "alpha", path: "/robots.txt")
        // 23:30 UTC on the 1st is 01:30 on the 2nd in Brussels.
        try await insertBotRows(at: [at("2026-09-01T23:30:00Z"), at("2026-09-02T09:00:00Z")], siteKey: "beta", path: "/b",
                                agent: "Claude-User", operatorName: "Anthropic", purpose: .userTriggered, verification: .spoofed)
        try await insertReferrals(4, at: at("2026-09-02T12:00:00Z"))
        // 22:15 UTC on 31 Aug is 00:15 on 1 Sep; 21:45 UTC is still 31 Aug.
        try await insertViews(7, at: at("2026-08-31T22:15:00Z"))
        try await insertViews(100, at: at("2026-08-31T21:45:00Z"))
        try await insertViews(5, at: at("2026-09-03T08:00:00Z"), siteKey: "beta", path: "/b")
    }

    private func makePlan(_ query: [String: String], siteKey: String? = nil) throws -> BotExportPlan {
        let base = ["v": "1", "range": "custom", "from": "2026-09-01", "to": "2026-09-03"]
        return try BotExportOptions(
            query: { base.merging(query) { $1 }[$0] },
            offeredRanges: BotDateRange.allCases,
            defaultRange: .week,
            peopleAvailable: true
        ).plan(now: Date(), timeZone: brussels, siteKey: siteKey, peopleAvailable: true)
    }

    private func counts(_ rows: [BotExportQueries.GroupedRow], _ plan: BotExportPlan) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: rows.map { ("\(plan.periods[$0.period].label) \($0.audience.csvValue)", $0.count) })
    }

    // MARK: - Grouped

    func testPerDaySeriesForEveryAudience() async throws {
        try await install()
        try await seed()
        let plan = try makePlan(["agents": "1", "referrals": "1", "people": "1", "detail": "day"])
        let rows = try await BotExportQueries(database: sql()).grouped(plan)
        XCTAssertEqual(rows.count, 9, "three days times three audiences, zeros included")
        XCTAssertEqual(counts(rows, plan), [
            "2026-09-01 ai_agent": 4, "2026-09-01 ai_referral": 0, "2026-09-01 people": 7,
            "2026-09-02 ai_agent": 2, "2026-09-02 ai_referral": 4, "2026-09-02 people": 0,
            "2026-09-03 ai_agent": 0, "2026-09-03 ai_referral": 0, "2026-09-03 people": 5,
        ])
        XCTAssertEqual(rows.map(\.audience).prefix(3), [.agents, .referrals, .people])

        let reads = try makePlan(["agents": "1", "page_reads": "1", "detail": "total"])
        let total = try await BotExportQueries(database: sql()).grouped(reads)
        XCTAssertEqual(total.map(\.count), [5], "robots.txt is not a page read")
    }

    func testBreakdownsAndSiteFilter() async throws {
        try await install()
        try await seed()
        let plan = try makePlan(["agents": "1", "people": "1", "detail": "total", "by_agent": "1", "by_verification": "1", "by_path": "1"])
        let rows = try await BotExportQueries(database: sql()).grouped(plan)
        let lines = rows.map { [$0.audience.csvValue, $0.path ?? "", $0.agent ?? "", $0.agentOperator ?? "", $0.verification ?? "", String($0.count)] }
        XCTAssertEqual(lines, [
            ["ai_agent", "/a", "GPTBot", "OpenAI", "verified", "3"],
            ["ai_agent", "/b", "Claude-User", "Anthropic", "spoofed", "2"],
            ["ai_agent", "/robots.txt", "GPTBot", "OpenAI", "verified", "1"],
            ["people", "/", "", "", "", "7"],
            ["people", "/b", "", "", "", "5"],
        ])

        let beta = try makePlan(["agents": "1", "referrals": "1", "people": "1", "detail": "total", "by_site": "1"], siteKey: "beta")
        let betaRows = try await BotExportQueries(database: sql()).grouped(beta)
        XCTAssertEqual(betaRows.map { "\($0.audience.csvValue) \($0.site ?? "-") \($0.count)" },
                       ["ai_agent beta 2", "people beta 5"], "no zero lines once broken down")
    }

    func testWeeksAndMonths() async throws {
        try await install()
        try await seed()
        let weeks = try makePlan(["agents": "1", "detail": "week"])
        XCTAssertEqual(weeks.periods.map(\.label), ["2026-W36"])
        let rows = try await BotExportQueries(database: sql()).grouped(weeks)
        XCTAssertEqual(rows.map(\.count), [6])
    }

    // MARK: - Raw

    /// Pages are cut on (time, key), so rows sharing an instant are neither
    /// lost nor repeated at a page boundary.
    func testRawStreamsEveryLineAcrossPages() async throws {
        try await install()
        try await seed()
        try await insertBotRows(at: Array(repeating: at("2026-09-02T15:00:00Z").addingTimeInterval(0.123456), count: 7), siteKey: "alpha", path: "/tie")
        let plan = try makePlan(["agents": "1", "referrals": "1", "people": "1", "detail": "raw"])

        let collected = Collected()
        try await BotExportQueries(database: sql(), rawPageSize: 3).streamRaw(plan) { await collected.append($0) }
        let lines = await collected.text.components(separatedBy: "\r\n").dropLast()
        XCTAssertEqual(lines.first, BotExportCSV.rawColumns.joined(separator: ","))
        let body = Array(lines.dropFirst())
        // 4 + 2 GPTBot/Claude rows, 7 ties, 4 referrals, 2 counters.
        XCTAssertEqual(body.count, 19)
        XCTAssertEqual(body.filter { $0.contains(",/tie,") }.count, 7)
        let times = body.map { String($0.prefix(25)) }
        XCTAssertEqual(times, times.sorted(), "oldest first")
        XCTAssertEqual(times.first, "2026-09-01T00:15:00+02:00")
        XCTAssertTrue(body.first!.hasSuffix(",people,alpha,/,,,,,,,,,7"), body.first!)
        XCTAssertTrue(body.contains { $0.contains(",ai_referral,alpha,/landing,GET,200,,,,notApplicable,,ChatGPT,1") })
        XCTAssertFalse(body.contains { $0.contains("hash") || $0.contains("test") }, "no ip hash or user agent")
        let people = body.filter { $0.contains(",people,") }.compactMap { Int($0.split(separator: ",").last!) }
        XCTAssertEqual(people.reduce(0, +), 12)
    }

    // MARK: - Route

    func testTheRoute() async throws {
        try await install()
        try await seed()

        try await app.test(.GET, "/admin/ai-bots/export/csv?v=1&agents=1") { res async in
            XCTAssertTrue(res.body.string.contains("type=\"password\""), "signed out gets the sign-in page")
            XCTAssertFalse(res.headers.contentType?.description.contains("csv") ?? false)
        }

        let cookie = try await signIn()
        let (status, form) = try await dashboard("export/?site=beta&range=30d", cookie: cookie)
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(form.contains("name=\"site\" value=\"beta\""))
        XCTAssertTrue(form.contains("name=\"range\" value=\"30d\" checked"))

        let query = "v=1&site=alpha&range=custom&from=2026-09-01&to=2026-09-03&detail=day&agents=1&people=1"
        try await app.test(.GET, "/admin/ai-bots/export/csv?\(query)", headers: ["Cookie": cookie]) { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: .contentType), "text/csv; charset=utf-8")
            XCTAssertEqual(res.headers.first(name: .contentDisposition),
                           "attachment; filename=\"ai-traffic_alpha_2026-09-01_2026-09-03_day.csv\"")
            XCTAssertEqual(res.headers.first(name: "Cache-Control"), "no-store")
            XCTAssertEqual(res.body.string, """
                period,period_start,period_end,audience,count\r
                2026-09-01,2026-09-01T00:00:00+02:00,2026-09-02T00:00:00+02:00,ai_agent,4\r
                2026-09-01,2026-09-01T00:00:00+02:00,2026-09-02T00:00:00+02:00,people,7\r
                2026-09-02,2026-09-02T00:00:00+02:00,2026-09-03T00:00:00+02:00,ai_agent,0\r
                2026-09-02,2026-09-02T00:00:00+02:00,2026-09-03T00:00:00+02:00,people,0\r
                2026-09-03,2026-09-03T00:00:00+02:00,2026-09-04T00:00:00+02:00,ai_agent,0\r
                2026-09-03,2026-09-03T00:00:00+02:00,2026-09-04T00:00:00+02:00,people,0\r

                """)
        }

        try await app.test(.GET, "/admin/ai-bots/export/csv?\(query.replacingOccurrences(of: "detail=day", with: "detail=raw"))",
                           headers: ["Cookie": cookie]) { res async in
            XCTAssertEqual(res.status, .ok)
            let lines = res.body.string.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            XCTAssertEqual(lines.count, 1 + 4 + 1, "header, alpha's four GPTBot rows, one counter")
        }

        try await app.test(.GET, "/admin/ai-bots/export/csv?v=1&range=custom&from=2026-09-05&to=2026-09-01&agents=1",
                           headers: ["Cookie": cookie]) { res async in
            XCTAssertEqual(res.status, .badRequest)
            XCTAssertTrue(res.body.string.contains("The start date is after the end date."))
        }
    }

    func testPeopleAreRefusedWithoutPageViews() async throws {
        try await install(pageViews: false)
        let cookie = try await signIn()
        try await app.test(.GET, "/admin/ai-bots/export/csv?v=1&people=1", headers: ["Cookie": cookie]) { res async in
            XCTAssertEqual(res.status, .badRequest)
        }
        try await app.test(.GET, "/admin/ai-bots/export/csv?v=1&agents=1&referrals=1&detail=raw", headers: ["Cookie": cookie]) { res async in
            XCTAssertEqual(res.status, .ok)
        }
    }
}

private actor Collected {
    var text = ""
    func append(_ chunk: String) { text += chunk }
}
