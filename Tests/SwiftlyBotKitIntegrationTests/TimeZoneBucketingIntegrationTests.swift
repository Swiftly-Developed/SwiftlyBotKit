import Foundation
import XCTest
import XCTVapor
import Fluent
import SQLKit
@testable import SwiftlyBotKit

/// The dashboard's time series: Swift computes every bucket boundary in the
/// configured zone (`BotDateRange.window`), PostgreSQL sorts rows between
/// those instants with `width_bucket`. These tests check, around real DST
/// transitions, that every row in the window lands in the bucket for its
/// local wall-clock hour or day (Foundation's `Calendar` is the oracle), that
/// nothing is lost between the tiles and the chart, and that the zone name
/// never reaches PostgreSQL.
final class TimeZoneBucketingIntegrationTests: PostgresIntegrationTestCase {

    override func setUp() async throws {
        try await super.setUp()
        BotKit.configure(for: app)
        try await app.autoMigrate()
    }

    private static let expectedBucketCount: [BotDateRange: Int] = [.day: 24, .week: 7, .month: 30, .quarter: 90]

    private static let utc: TimeZone = TimeZone(identifier: "UTC")!

    private static func iso(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"
        return f.string(from: date)
    }

    /// DST transitions in 2026 for `tz`, or an empty list.
    private static func transitions(in tz: TimeZone, year: Int = 2026) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var cursor = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        var result: [Date] = []
        while let next = tz.nextDaylightSavingTimeTransition(after: cursor), next < end {
            result.append(next)
            cursor = next
        }
        return result
    }

    /// Which `now`s to test for a zone: around each 2026 transition, or a
    /// fixed date for zones without DST.
    private static func scenarios(for tz: TimeZone) -> [(BotDateRange, Date)] {
        var anchors = transitions(in: tz)
        if anchors.isEmpty {
            anchors = [Date(timeIntervalSince1970: 1_774_785_600)] // 2026-03-29 12:00 UTC
        }
        var result: [(BotDateRange, Date)] = []
        for t in anchors {
            for offset: TimeInterval in [0, 1_800, 10_800, 72_000, 84_600] {
                result.append((.day, t.addingTimeInterval(offset)))
            }
            for offset: TimeInterval in [-3_600, 172_800, 596_160] {
                result.append((.week, t.addingTimeInterval(offset)))
            }
            result.append((.month, t.addingTimeInterval(10 * 86_400)))
            result.append((.quarter, t.addingTimeInterval(40 * 86_400)))
        }
        return result
    }

    /// The wall-clock hour or day of `instant`, by `Calendar`, independent of
    /// the offset arithmetic in `BotDateRange`.
    private static func oracle(_ instant: Date, range: BotDateRange, calendar: Calendar) -> DateComponents {
        calendar.dateComponents(range.isHourly ? [.year, .month, .day, .hour] : [.year, .month, .day], from: instant)
    }

    /// The same components for a bucket key (local time since 1970, in units).
    private static func components(ofKey key: Int64, range: BotDateRange) -> DateComponents {
        let unit: Int64 = range.isHourly ? 3_600 : 86_400
        return oracle(Date(timeIntervalSince1970: Double(key * unit)), range: range,
                      calendar: BotDateRange.calendar(in: utc))
    }

    /// Runs one window and returns every disagreement found, empty when the
    /// chart is right.
    private func checkWindow(zone: TimeZone, range: BotDateRange, now: Date) async throws -> [String] {
        var problems: [String] = []
        let calendar = BotDateRange.calendar(in: zone)
        let window = range.window(now: now, in: zone)
        let buckets = window.buckets
        let since = range.start(from: now, in: zone)
        let label = "\(zone.identifier) \(range.rawValue) now=\(Self.iso(now, zone))"

        // Swift-side invariants.
        if buckets.count != Self.expectedBucketCount[range] {
            problems.append("\(label): \(buckets.count) buckets, expected \(Self.expectedBucketCount[range]!)")
        }
        if buckets.first?.start != since || window.start != since {
            problems.append("\(label): first bucket \(buckets.first.map { Self.iso($0.start, zone) } ?? "nil") != since \(Self.iso(since, zone))")
        }
        if range.buckets(now: now, in: zone) != buckets.map(\.start) {
            problems.append("\(label): buckets(now:in:) differs from the window")
        }
        for (a, b) in zip(buckets, buckets.dropFirst()) where !(a.start < b.start && a.key < b.key) {
            problems.append("\(label): buckets not increasing at \(Self.iso(a.start, zone))")
        }
        for (a, b) in zip(window.runs, window.runs.dropFirst()) where !(a.start < b.start) {
            problems.append("\(label): runs not increasing at \(Self.iso(a.start, zone))")
        }
        for bucket in buckets {
            let own = Self.oracle(bucket.start, range: range, calendar: calendar)
            if own != Self.components(ofKey: bucket.key, range: range) {
                problems.append("\(label): bucket starting \(Self.iso(bucket.start, zone)) is keyed \(Self.components(ofKey: bucket.key, range: range)), Calendar says \(own)")
            }
            // A bucket starts where its wall-clock hour or day starts: the
            // second before it belongs elsewhere.
            if Self.oracle(bucket.start.addingTimeInterval(-1), range: range, calendar: calendar) == own {
                problems.append("\(label): bucket \(Self.iso(bucket.start, zone)) does not start at a boundary")
            }
        }

        // Instants: every 15 minutes from two hours before the window, plus
        // each run start and one second either side of it.
        var instants: Set<Date> = []
        let step = 900.0
        var t = (since.timeIntervalSince1970 / step).rounded(.down) * step - 7_200
        while t <= now.timeIntervalSince1970 {
            instants.insert(Date(timeIntervalSince1970: t))
            t += step
        }
        for run in window.runs {
            for d in [-1.0, 0, 1] where run.start.addingTimeInterval(d) <= now {
                instants.insert(run.start.addingTimeInterval(d))
            }
        }
        let sorted = instants.sorted()

        try await sql().raw("TRUNCATE ai_bot_visits").run()
        try await insertBotRows(at: sorted)

        // Expected: each row in the window counts toward the bucket with the
        // same wall-clock components.
        let index = Dictionary(uniqueKeysWithValues: buckets.enumerated().map {
            (Self.components(ofKey: $1.key, range: range), $0)
        })
        let inWindow = sorted.filter { $0 >= since }
        var expected = Array(repeating: 0, count: buckets.count)
        var orphans = 0
        for instant in inWindow {
            if let i = index[Self.oracle(instant, range: range, calendar: calendar)] {
                expected[i] += 1
            } else {
                orphans += 1
                if orphans <= 2 { problems.append("\(label): row at \(Self.iso(instant, zone)) is in the window but has no bucket") }
            }
        }

        // The real query path.
        let data = try await BotDashboardQueries(database: sql(), timeZone: zone).load(range: range, siteKey: nil, now: now)
        let actual = data.series.map(\.total)
        if data.totals.botVisits != inWindow.count {
            problems.append("\(label): totals \(data.totals.botVisits), expected \(inWindow.count)")
        }
        let charted = actual.reduce(0, +)
        if charted != inWindow.count {
            problems.append("\(label): chart holds \(charted) of \(inWindow.count) rows in the window (\(inWindow.count - charted) dropped)")
        }
        if actual != expected {
            let diffs = zip(buckets, zip(expected, actual)).filter { $0.1.0 != $0.1.1 }.prefix(4)
            for (b, (e, a)) in diffs {
                problems.append("\(label): bucket \(Self.iso(b.start, zone)) has \(a), expected \(e)")
            }
        }
        return problems
    }

    private func assertAgreement(_ zone: BotKitTimeZone, file: StaticString = #filePath, line: UInt = #line) async throws {
        let tz = zone.foundationTimeZone
        var problems: [String] = []
        let scenarios = Self.scenarios(for: tz)
        for (range, now) in scenarios {
            problems += try await checkWindow(zone: tz, range: range, now: now)
        }
        if !problems.isEmpty {
            // Lead with the lines that say what a reader would see: lost rows
            // and missing bars. The key-level detail follows.
            let headline = problems.filter { $0.contains("dropped") || $0.contains("buckets, expected") || $0.contains("totals") }
            let detail = problems.filter { !headline.contains($0) }
            print("BOTKIT-TZ \(tz.identifier): \(problems.count) problem(s) over \(scenarios.count) windows\n  "
                  + (headline + detail.prefix(12)).joined(separator: "\n  "))
        }
        let headline = problems.filter { $0.contains("dropped") || $0.contains("buckets, expected") }
        XCTAssertTrue(problems.isEmpty,
                      "\(tz.identifier) (\(scenarios.count) windows): \(problems.count) problem(s)\n"
                          + (headline.prefix(8) + problems.prefix(4)).joined(separator: "\n"),
                      file: file, line: line)
    }

    // MARK: - Zones

    func testUTC() async throws { try await assertAgreement(.utc) }
    func testEuropeBrussels() async throws { try await assertAgreement(.europeBrussels) }
    func testAmericaNewYork() async throws { try await assertAgreement(.americaNewYork) }
    /// Half-hour offset, no DST, and a canonical name (`Asia/Kolkata`) that
    /// used to be missing from the list in favour of `Asia/Calcutta`.
    func testAsiaKolkata() async throws { try await assertAgreement(.asiaKolkata) }
    func testLegacyNameResolvesToTheCanonicalCase() async throws {
        XCTAssertEqual(BotKitTimeZone(identifier: "Asia/Calcutta"), .asiaKolkata)
        XCTAssertEqual(BotKitTimeZone(identifier: "Europe/Kiev"), .europeKyiv)
        try await assertAgreement(try XCTUnwrap(BotKitTimeZone(identifier: "Asia/Calcutta")))
    }
    func testAsiaKathmandu() async throws { try await assertAgreement(.asiaKathmandu) }
    /// 30-minute DST shift.
    func testAustraliaLordHowe() async throws { try await assertAgreement(.australiaLordHowe) }
    /// +12:45 / +13:45, and the fall-back happens at 03:45, so the repeated
    /// wall-clock hours 02:45 to 03:45 interleave with their first pass.
    func testPacificChatham() async throws { try await assertAgreement(.pacificChatham) }
    func testAustraliaSydney() async throws { try await assertAgreement(.australiaSydney) }
    /// Southern hemisphere, and DST changes at local midnight: on the
    /// spring-forward day 00:00 does not exist.
    func testAmericaSantiago() async throws { try await assertAgreement(.americaSantiago) }
    /// Also changes at midnight (00:00 -> 01:00 in April).
    func testAfricaCairo() async throws { try await assertAgreement(.africaCairo) }
    /// Fixed offsets, which PostgreSQL would misread by name (`GMT+0100` is
    /// POSIX-inverted and taken as hours). The name is never sent, so they
    /// bucket like any other zone, including a 45-minute negative offset.
    func testFixedOffsetCustomZones() async throws {
        try await assertAgreement(.custom(TimeZone(secondsFromGMT: 3_600)!))
        try await assertAgreement(.custom(TimeZone(secondsFromGMT: -(9 * 3_600 + 2_700))!))
    }

    /// The dashboard route with India's zone, by case, by legacy name, and
    /// with zones PostgreSQL does not know by that name. Before, the zone name
    /// was sent to PostgreSQL, and Debian's tzdata (the official postgres
    /// images) no longer has `Asia/Calcutta`: every load was a 500.
    func testDashboardRendersWhateverZonePostgresKnows() async throws {
        try await insertBotRows(at: [Date()])
        var zones: [BotKitTimeZone] = [.asiaKolkata, .custom(TimeZone(secondsFromGMT: 3_600)!), .americaCoyhaique]
        zones.append(try XCTUnwrap(BotKitTimeZone(identifier: "Asia/Calcutta")))
        for (index, zone) in zones.enumerated() {
            var config = baseConfiguration()
            config.dashboard.timeZone = zone
            let path = "/admin/ai-bots-\(index)"
            config.dashboard.path = path
            // One app mounts one dashboard per zone here, which the
            // double-install guard would refuse; each mount has its own path,
            // so clearing the marker between them is safe in this test.
            app.storage[BotKit.InstallationKey.self] = nil
            try BotKit.configureRoutes(for: app, config: config)
            let cookie = try await signIn(path: path)
            let (status, body) = try await dashboard("?range=7d", cookie: cookie, path: path)
            XCTAssertEqual(status, .ok, "dashboard with \(zone.identifier): \(body.prefix(200))")
        }
    }

    /// Every named zone through the real query path: the chart holds exactly
    /// the rows the tiles count. Zones this platform's Foundation lacks fall
    /// back to UTC and are listed.
    func testEveryNamedZoneChartsEveryRow() async throws {
        let now = Date(timeIntervalSince1970: 1_792_800_000) // 2026-10-24 00:00 UTC
        let instants = stride(from: 0.0, to: 8 * 86_400, by: 1_800).map { now.addingTimeInterval(-$0) }
        try await insertBotRows(at: instants)
        var problems: [String] = []
        let unavailable = BotKitTimeZone.allNamed.filter { !$0.isAvailable }.map(\.identifier)
        for zone in BotKitTimeZone.allNamed {
            let tz = zone.foundationTimeZone
            for range in [BotDateRange.day, .week] {
                let data = try await BotDashboardQueries(database: sql(), timeZone: tz).load(range: range, siteKey: nil, now: now)
                let charted = data.series.reduce(0) { $0 + $1.total }
                if charted != data.totals.botVisits || data.series.count != Self.expectedBucketCount[range] {
                    problems.append("\(zone.identifier) \(range.rawValue): chart \(charted), tiles \(data.totals.botVisits), \(data.series.count) buckets")
                }
            }
        }
        print("BOTKIT-TZ \(BotKitTimeZone.allNamed.count) zones charted; unavailable here (drawn in UTC): \(unavailable)")
        XCTAssertEqual(problems, [])
    }
}
