import Foundation
import XCTest
import XCTVapor
import Fluent
import SQLKit
@testable import SwiftlyBotKit

/// The dashboard route and its five queries over real rows.
final class DashboardIntegrationTests: PostgresIntegrationTestCase {

    private func install(_ config: BotKitConfiguration? = nil) async throws {
        var config = config ?? baseConfiguration()
        config.sites = [
            .init(key: "alpha", name: "Alpha site"),
            .init(key: "beta", name: "Beta site"),
        ]
        try BotKit.install(on: app, config: config)
        try await app.autoMigrate()
    }

    func testEmptyTableRendersTheEmptyStateForEveryRange() async throws {
        try await install()
        let cookie = try await signIn()
        for range in BotDateRange.allCases {
            for site in ["all", "alpha", "beta", "nope"] {
                let (status, body) = try await dashboard("?range=\(range.rawValue)&site=\(site)", cookie: cookie)
                XCTAssertEqual(status, .ok, "\(range) \(site)")
                XCTAssertTrue(body.contains("Nothing recorded in the \(range.label.lowercased())."), "\(range) \(site)")
            }
        }
    }

    func testThousandsOfRowsRenderWithCorrectTotals() async throws {
        try await install()
        let now = Date()
        // 3,000 rows over the last 6 days: two sites, three agents, 40 paths.
        var alpha: [Date] = []
        var beta: [Date] = []
        for i in 0..<3_000 {
            let instant = now.addingTimeInterval(-Double(i) * 170)
            if i % 3 == 0 { beta.append(instant) } else { alpha.append(instant) }
        }
        try await insertBotRows(at: alpha, siteKey: "alpha", path: "/alpha-page", agent: "GPTBot", purpose: .training)
        try await insertBotRows(at: beta, siteKey: "beta", path: "/beta-page", agent: "Claude-User",
                                operatorName: "Anthropic", purpose: .userTriggered, verification: .spoofed)
        // Referrals, which count separately.
        try await sql().raw("""
            INSERT INTO ai_bot_visits (id, site_key, path, method, status_code, verification, referrer_platform, ip_hash, created_at)
            SELECT gen_random_uuid(), 'alpha', '/landing', 'GET', 200, 'notApplicable', 'ChatGPT', 'h', now() - (g || ' minutes')::interval
            FROM generate_series(1, 250) g
            """).run()

        let cookie = try await signIn()
        let (status, body) = try await dashboard("?range=7d&site=all", cookie: cookie)
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(body.contains("3,000") || body.contains("3000"), "total bot visits missing")
        XCTAssertTrue(body.contains("/alpha-page"))
        XCTAssertTrue(body.contains("/beta-page"))
        XCTAssertTrue(body.contains("ChatGPT"))

        let queries = BotDashboardQueries(database: sql(), timeZone: TimeZone(identifier: "UTC")!)
        let all = try await queries.load(range: .week, siteKey: nil, now: now)
        XCTAssertEqual(all.totals.botVisits, 3_000)
        XCTAssertEqual(all.totals.userTriggered, 1_000)
        XCTAssertEqual(all.totals.spoofed, 1_000)
        XCTAssertEqual(all.totals.verified, 2_000)
        XCTAssertEqual(all.totals.referrals, 250)
        XCTAssertEqual(all.totals.distinctAgents, 2)
        XCTAssertEqual(all.series.reduce(0) { $0 + $1.total }, 3_000, "chart sum differs from the tile")
        XCTAssertEqual(all.referrals.first?.count, 250)

        let beta7 = try await queries.load(range: .week, siteKey: "beta", now: now)
        XCTAssertEqual(beta7.totals.botVisits, 1_000)
        XCTAssertEqual(beta7.topPages.map(\.path), ["/beta-page"])
        XCTAssertEqual(beta7.topAgents.first?.spoofed, 1_000)
        XCTAssertEqual(beta7.totals.referrals, 0)

        let (siteStatus, siteBody) = try await dashboard("?range=7d&site=beta", cookie: cookie)
        XCTAssertEqual(siteStatus, .ok)
        XCTAssertFalse(siteBody.contains("/alpha-page"), "site filter leaked another site's rows")
    }

    // MARK: - Performance and plans

    /// "12.3 ms". Interpolation rather than `String(format:)` with `%@`,
    /// which is not portable to Linux.
    private func ms(_ value: Double) -> String {
        "\((value * 10).rounded() / 10) ms"
    }

    /// Mirrors the series query in BotDashboardQueries, for EXPLAIN: 24
    /// hourly thresholds, then `width_bucket` over them.
    private static let seriesSQL = """
        SELECT width_bucket(created_at, ARRAY(
                   SELECT date_trunc('hour', now()) - (g || ' hours')::interval FROM generate_series(23, 0, -1) g
               )::timestamptz[]) AS run,
               COALESCE(purpose::text, 'scraper') AS purpose, COUNT(*) AS count
        FROM ai_bot_visits
        WHERE created_at >= date_trunc('hour', now()) - interval '23 hours' AND agent_name IS NOT NULL AND site_key = 'alpha'
        GROUP BY 1, 2
        """

    private static let totalsSQL90 = """
        SELECT COUNT(*) FILTER (WHERE agent_name IS NOT NULL), COUNT(DISTINCT agent_name)
        FROM ai_bot_visits WHERE created_at >= now() - interval '90 days'
        """

    private static let topPagesSQL24 = """
        SELECT path, COUNT(*) AS count FROM ai_bot_visits
        WHERE created_at >= now() - interval '1 day' AND agent_name IS NOT NULL
        GROUP BY path ORDER BY count DESC LIMIT 12
        """

    private func explain(_ query: String) async throws -> String {
        try await sql().raw("EXPLAIN (ANALYZE, BUFFERS) \(unsafeRaw: query)").all()
            .map { try $0.decode(column: "QUERY PLAN", as: String.self) }
            .joined(separator: "\n")
    }

    /// The worst case for the 90-day view: 50,000 rows all inside it, so no
    /// index can narrow the scan.
    func testPerformanceWithFiftyThousandRowsInsideNinetyDays() async throws {
        try await install()
        let now = Date()
        let instants = (0..<50_000).map { now.addingTimeInterval(-Double($0) * (89 * 86_400 / 50_000)) }
        try await insertBotRows(at: Array(instants[..<25_000]), siteKey: "alpha", path: "/a", agent: "GPTBot")
        try await insertBotRows(at: Array(instants[25_000...]), siteKey: "beta", path: "/b", agent: "Claude-User",
                                operatorName: "Anthropic", purpose: .userTriggered)
        try await sql().raw("ANALYZE ai_bot_visits").run()

        let queries = BotDashboardQueries(database: sql(), timeZone: TimeZone(identifier: "America/New_York")!)
        var report: [String] = []
        for range in BotDateRange.allCases {
            for site in [nil, "alpha"] as [String?] {
                _ = try await queries.load(range: range, siteKey: site, now: now)
                var timings: [Double] = []
                for _ in 0..<5 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let data = try await queries.load(range: range, siteKey: site, now: now)
                    timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    if range == .quarter && site == nil {
                        XCTAssertEqual(data.totals.botVisits, 50_000)
                        XCTAssertEqual(data.series.reduce(0) { $0 + $1.total }, 50_000)
                    }
                }
                timings.sort()
                report.append("dense load(\(range.rawValue), site: \(site ?? "all")): median \(ms(timings[2])), max \(ms(timings[4]))")
                XCTAssertLessThan(timings[2], 2_000)
            }
        }
        print("BOTKIT-PERF-DENSE\n" + report.joined(separator: "\n"))
    }

    /// Seeds 50,000 rows and times the full five-query load for every range,
    /// all sites and one site. Prints the numbers and the plans; asserts only a
    /// generous ceiling so a slow CI box does not flake.
    func testPerformanceWithFiftyThousandRows() async throws {
        try await install()
        let now = Date()
        // Spread over 365 days so the 24h and 7d windows are selective and an
        // index is worth using: about 137 rows a day.
        let agents: [(String, String, AIAgentPurpose)] = [
            ("GPTBot", "OpenAI", .training), ("ClaudeBot", "Anthropic", .training),
            ("Claude-User", "Anthropic", .userTriggered), ("OAI-SearchBot", "OpenAI", .aiSearch),
            ("PerplexityBot", "Perplexity", .aiSearch), ("Bytespider", "ByteDance", .scraper),
        ]
        let perAgent = 50_000 / agents.count
        for (index, agent) in agents.enumerated() {
            let instants = (0..<perAgent).map { i in
                now.addingTimeInterval(-Double(i) * (365 * 86_400 / Double(perAgent)) - Double(index))
            }
            try await insertBotRows(at: instants, siteKey: index % 2 == 0 ? "alpha" : "beta",
                                    path: "/page-\(index)", agent: agent.0, operatorName: agent.1, purpose: agent.2)
        }
        try await sql().raw("ANALYZE ai_bot_visits").run()
        let total = try await count()
        XCTAssertGreaterThanOrEqual(total, 49_998)

        let queries = BotDashboardQueries(database: sql(), timeZone: TimeZone(identifier: "Europe/Brussels")!)
        var report: [String] = ["rows: \(total)"]
        for range in BotDateRange.allCases {
            for site in [nil, "alpha"] as [String?] {
                _ = try await queries.load(range: range, siteKey: site, now: now) // warm
                var timings: [Double] = []
                for _ in 0..<5 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = try await queries.load(range: range, siteKey: site, now: now)
                    timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                timings.sort()
                let median = timings[2]
                report.append("load(\(range.rawValue), site: \(site ?? "all")): median \(ms(median)), max \(ms(timings[4]))")
                XCTAssertLessThan(median, 2_000, "\(range) \(site ?? "all") too slow")
            }
        }

        // End to end through the route, including rendering.
        let cookie = try await signIn()
        let start = DispatchTime.now().uptimeNanoseconds
        let (status, _) = try await dashboard("?range=90d&site=all", cookie: cookie)
        report.append("GET dashboard 90d all sites: \(ms(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))")
        XCTAssertEqual(status, .ok)

        let seriesPlan = try await explain(Self.seriesSQL)
        let totalsPlan = try await explain(Self.totalsSQL90)
        let pagesPlan = try await explain(Self.topPagesSQL24)
        report.append("--- series 24h one site ---\n" + seriesPlan)
        report.append("--- totals 90d all sites ---\n" + totalsPlan)
        report.append("--- top pages 24h all sites ---\n" + pagesPlan)
        print("BOTKIT-PERF\n" + report.joined(separator: "\n") + "\nBOTKIT-PERF-END")

        // Which indexes the dashboard actually used. Stats reach the view
        // asynchronously, so give them a moment.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let usage = try await sql().raw("""
            SELECT indexrelname AS name, idx_scan FROM pg_stat_user_indexes
            WHERE relname = 'ai_bot_visits' ORDER BY indexrelname
            """).all().map { "\(try $0.decode(column: "name", as: String.self))=\(try $0.decode(column: "idx_scan", as: Int.self))" }
        print("BOTKIT-PERF index scans: \(usage.joined(separator: ", "))")

        XCTAssertTrue(seriesPlan.contains("idx_ai_bot_visits_site_time"),
                      "24h one-site series does not use the (site_key, created_at) index:\n\(seriesPlan)")
        XCTAssertTrue(pagesPlan.contains("idx_ai_bot_visits_time") || pagesPlan.contains("idx_ai_bot_visits_site_time"),
                      "24h all-sites top pages does not use a created_at index:\n\(pagesPlan)")
    }
}
