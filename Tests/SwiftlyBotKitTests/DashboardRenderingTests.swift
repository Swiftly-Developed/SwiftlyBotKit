import XCTest
@testable import SwiftlyBotKit

final class BotDateRangeTests: XCTestCase {

    private let brussels = TimeZone(identifier: "Europe/Brussels")!

    func testBucketCounts() {
        let now = Date()
        XCTAssertEqual(BotDateRange.day.buckets(now: now, in: brussels).count, 24)
        XCTAssertEqual(BotDateRange.week.buckets(now: now, in: brussels).count, 7)
        XCTAssertEqual(BotDateRange.month.buckets(now: now, in: brussels).count, 30)
        XCTAssertEqual(BotDateRange.quarter.buckets(now: now, in: brussels).count, 90)
    }

    func testBucketsAreOrderedAndAlignedToTheBoundary() {
        let buckets = BotDateRange.week.buckets(now: Date(), in: brussels)
        XCTAssertEqual(buckets, buckets.sorted())

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = brussels
        for bucket in buckets {
            let parts = calendar.dateComponents([.hour, .minute, .second], from: bucket)
            XCTAssertEqual(parts.hour, 0)
            XCTAssertEqual(parts.minute, 0)
            XCTAssertEqual(parts.second, 0)
        }
    }

    /// The window starts at a bucket boundary, never mid-bucket: otherwise the
    /// leading bar covers a partial period and reads as a dip.
    func testWindowStartIsTheFirstBucket() {
        let now = Date()
        XCTAssertEqual(BotDateRange.month.start(from: now, in: brussels), BotDateRange.month.buckets(now: now, in: brussels).first)
    }

    // MARK: DST, computed without a database

    private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

    private func labels(_ range: BotDateRange, now: Date, in tz: TimeZone) -> [String] {
        range.buckets(now: now, in: tz).map { range.axisLabel(for: $0, in: tz) }
    }

    /// 2026-10-25, Brussels falls back at 03:00 CEST to 02:00 CET. The
    /// repeated hour is one bucket: 24 distinct labels over 25 real hours.
    func testRepeatedHourIsOneBucket() throws {
        let now = Date(timeIntervalSince1970: 1_792_927_200) // 2026-10-25 12:20 CET
        let window = BotDateRange.day.window(now: now, in: brussels)
        let labels = labels(.day, now: now, in: brussels)
        XCTAssertEqual(labels.count, 24)
        XCTAssertEqual(Set(labels).count, 24, "a label repeats: \(labels)")
        XCTAssertEqual(now.timeIntervalSince(window.start), 24 * 3_600 + 20 * 60)
        // Both passes of 02:00 follow each other, so they are one run of two
        // real hours.
        let index = try XCTUnwrap(labels.firstIndex(of: "02:00"))
        XCTAssertEqual(window.buckets[index + 1].start.timeIntervalSince(window.buckets[index].start), 7_200)
    }

    /// 2026-03-29, Brussels skips 02:00. 24 buckets, the newest just begun, so
    /// 23 real hours, and no "02:00" among them.
    func testSkippedHourHasNoBucket() {
        let now = Date(timeIntervalSince1970: 1_774_789_200) // 2026-03-29 15:00 CEST
        let labels = labels(.day, now: now, in: brussels)
        XCTAssertEqual(labels.count, 24)
        XCTAssertFalse(labels.contains("02:00"))
        XCTAssertEqual(now.timeIntervalSince(BotDateRange.day.start(from: now, in: brussels)), 23 * 3_600)
    }

    /// Santiago springs forward at local midnight (2026-09-06): that day's
    /// bucket starts at 01:00, and the 23-hour day is still one bucket.
    func testDayWhoseMidnightIsSkippedStartsAtOne() {
        let santiago = zone("America/Santiago")
        let now = Date(timeIntervalSince1970: 1_788_800_000) // 2026-09-07 13:53 -03
        let buckets = BotDateRange.week.buckets(now: now, in: santiago)
        XCTAssertEqual(buckets.count, 7)
        let calendar = BotDateRange.calendar(in: santiago)
        let hours = buckets.map { calendar.component(.hour, from: $0) }
        XCTAssertEqual(hours.filter { $0 == 1 }.count, 1, "\(hours)")
        XCTAssertEqual(hours.filter { $0 == 0 }.count, 6, "\(hours)")
        XCTAssertEqual(Set(labels(.week, now: now, in: santiago)).count, 7)
    }

    /// Lord Howe moves 30 minutes. Labels still name whole wall-clock hours.
    func testHalfHourDSTLabelsWholeHours() {
        let lordHowe = zone("Australia/Lord_Howe")
        for now in [Date(timeIntervalSince1970: 1_775_318_400), Date(timeIntervalSince1970: 1_791_043_200)] {
            let labels = labels(.day, now: now, in: lordHowe)
            XCTAssertEqual(labels.count, 24)
            XCTAssertEqual(Set(labels).count, 24, "\(labels)")
            XCTAssertTrue(labels.allSatisfy { $0.hasSuffix(":00") }, "\(labels)")
        }
    }

    /// Chatham falls back at 03:45: wall-clock 02:45 to 03:45 happens twice,
    /// interleaved with the first pass. Two buckets, four runs, no repeats.
    func testChathamInterleavedRepeatIsMerged() {
        let chatham = zone("Pacific/Chatham")
        let now = Date(timeIntervalSince1970: 1_775_386_800) // 2026-04-05 23:45 +12:45
        let window = BotDateRange.day.window(now: now, in: chatham)
        let labels = labels(.day, now: now, in: chatham)
        XCTAssertEqual(labels.count, 24)
        XCTAssertEqual(Set(labels).count, 24, "\(labels)")
        XCTAssertNotEqual(window.runs.map(\.bucket), window.runs.map(\.bucket).sorted(), "runs should interleave")
        XCTAssertGreaterThan(window.runs.count, window.buckets.count)
    }

    /// A fixed offset has no transitions; every bucket is aligned to it.
    func testFixedOffsetBuckets() {
        let plus0545 = TimeZone(secondsFromGMT: 5 * 3_600 + 2_700)!
        let now = Date(timeIntervalSince1970: 1_774_785_600)
        let buckets = BotDateRange.week.buckets(now: now, in: plus0545)
        XCTAssertEqual(buckets.count, 7)
        for bucket in buckets {
            XCTAssertEqual((Int(bucket.timeIntervalSince1970) + plus0545.secondsFromGMT()) % 86_400, 0)
        }
    }

    /// Every named zone gets the full bucket count for every range, at a
    /// fall-back and a spring-forward instant for either hemisphere.
    func testEveryNamedZoneGetsAFullWindow() {
        let instants = [1_774_785_600.0, 1_775_386_800, 1_792_890_000, 1_788_800_000].map(Date.init(timeIntervalSince1970:))
        for zone in BotKitTimeZone.allNamed {
            let tz = zone.foundationTimeZone
            for now in instants {
                for range in BotDateRange.allCases {
                    let window = range.window(now: now, in: tz)
                    XCTAssertEqual(window.buckets.count, range.bucketCount, "\(zone.identifier) \(range)")
                    XCTAssertLessThanOrEqual(window.start, now)
                }
            }
        }
    }
}

final class BotChartsTests: XCTestCase {

    func testGrouping() {
        XCTAssertEqual(BotCharts.grouped(0), "0")
        XCTAssertEqual(BotCharts.grouped(999), "999")
        XCTAssertEqual(BotCharts.grouped(1_284), "1,284")
        XCTAssertEqual(BotCharts.grouped(1_234_567), "1,234,567")
    }

    func testCompacting() {
        XCTAssertEqual(BotCharts.compact(1_284), "1,284")
        XCTAssertEqual(BotCharts.compact(12_900), "12.9K")
        XCTAssertEqual(BotCharts.compact(1_400_000), "1.4M")
    }

    /// Axis ticks are drawn at quarters of the scale max, so it has to divide
    /// by four to land on whole numbers.
    func testNiceMaxIsAlwaysDivisibleByFour() {
        for peak in [0, 1, 7, 12, 13, 99, 100, 101, 4_321, 999_999] {
            let max = BotCharts.niceMax(peak)
            XCTAssertEqual(max % 4, 0, "niceMax(\(peak)) = \(max)")
            XCTAssertGreaterThanOrEqual(max, peak)
        }
    }

    func testStackedColumnsRenderOneMarkPerSeriesValue() {
        let now = Date()
        let buckets = BotDateRange.week.buckets(now: now, in: .current)
        let series = buckets.enumerated().map { index, bucket in
            BotDashboardData.SeriesPoint(
                bucket: bucket,
                counts: index == 0 ? [:] : [.userTriggered: index, .training: index * 2]
            )
        }
        let svg = BotCharts.stackedColumns(series: series, range: .week, timeZone: .current)
        XCTAssertTrue(svg.hasPrefix("<svg"))
        XCTAssertTrue(svg.hasSuffix("</svg>"))
        // Six populated buckets, two segments each: the top one is a rounded
        // path, the lower one a plain rect.
        XCTAssertEqual(svg.components(separatedBy: "<path").count - 1, 6)
        XCTAssertEqual(svg.components(separatedBy: "<rect").count - 1, 6)
        // Hover layer.
        XCTAssertTrue(svg.contains("<title>"))
    }

    func testEmptySeriesStillRendersAxes() {
        let svg = BotCharts.stackedColumns(series: [], range: .week, timeZone: .current)
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertFalse(svg.contains("<rect"))
    }

    /// The user-triggered share is drawn inside the bar, in a second shade of
    /// the same hue, rather than living only in the text beside it.
    func testHighlightSegmentIsDrawnInsideTheBar() {
        let html = BotCharts.barRows([
            .init(name: "/services/", meta: nil, value: 100, note: nil,
                  color: "var(--series-1-soft)", flag: nil,
                  highlight: 25, highlightColor: "var(--series-1)"),
        ])
        XCTAssertTrue(html.contains("var(--series-1-soft)"))
        XCTAssertTrue(html.contains("class=\"seg\""))
        XCTAssertTrue(html.contains("width:25%"))
    }

    func testHighlightIsOmittedWhenZeroAndSquaredOffWhenWhole() {
        let none = BotCharts.barRows([
            .init(name: "/a/", meta: nil, value: 10, note: nil, color: "var(--series-1-soft)",
                  flag: nil, highlight: 0, highlightColor: "var(--series-1)"),
        ])
        XCTAssertFalse(none.contains("class=\"seg"))

        // A bar that is entirely user-triggered keeps the rounded data end
        // instead of showing a 2px gap against nothing.
        let whole = BotCharts.barRows([
            .init(name: "/b/", meta: nil, value: 10, note: nil, color: "var(--series-1-soft)",
                  flag: nil, highlight: 10, highlightColor: "var(--series-1)"),
        ])
        XCTAssertTrue(whole.contains("seg whole"))
    }

    /// Agent names and request paths reach the markup as raw strings.
    func testTextFromTheDatabaseIsEscaped() {
        let html = BotCharts.barRows([
            .init(name: "<script>alert(1)</script>", meta: "a & b", value: 5, note: nil,
                  color: "var(--series-1)", flag: nil),
        ])
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("a &amp; b"))
    }
}

final class DashboardPageTests: XCTestCase {

    private let sites = [
        BotDashboardSite(key: "developed", name: "Swiftly Developed",
                         logoPath: "/images/developed/sd-logo.png"),
        BotDashboardSite(key: "marketing", name: "Swiftly Marketing",
                         logoPath: "/images/marketing/sm-logo.png"),
    ]

    func testEmptyDashboardRenders() {
        let html = DashboardPage.render(
            data: BotDashboardData(),
            range: .week,
            sites: sites,
            selectedSite: nil,
            generatedAt: Date()
        )
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("Nothing recorded"))
        XCTAssertTrue(html.contains("noindex"))
        // The switcher offers every site plus the all-sites view.
        XCTAssertTrue(html.contains("Swiftly Developed"))
        XCTAssertTrue(html.contains("Swiftly Marketing"))
        XCTAssertTrue(html.contains("All sites"))
    }

    func testPopulatedDashboardShowsTilesChartAndLegend() {
        var data = BotDashboardData()
        data.totals = .init(botVisits: 420, userTriggered: 31, verified: 300, spoofed: 7,
                            referrals: 12, distinctAgents: 9)
        data.series = BotDateRange.week.buckets(now: Date(), in: .current).map {
            .init(bucket: $0, counts: [.userTriggered: 4, .training: 10])
        }
        data.topAgents = [
            .init(name: "GPTBot", operatorName: "OpenAI", purpose: .training, count: 200,
                  verified: 190, spoofed: 2, respectsRobotsTxt: true),
            .init(name: "Perplexity-User", operatorName: "Perplexity", purpose: .userTriggered,
                  count: 31, verified: 28, spoofed: 3, respectsRobotsTxt: false),
        ]
        data.topPages = [.init(path: "/services/", count: 88, userTriggered: 9)]
        data.referrals = [.init(platform: "ChatGPT", count: 12)]

        let html = DashboardPage.render(
            data: data,
            range: .week,
            sites: sites,
            selectedSite: sites[0],
            generatedAt: Date()
        )
        XCTAssertTrue(html.contains("<svg"))
        XCTAssertTrue(html.contains("GPTBot"))
        XCTAssertTrue(html.contains("/services/"))
        XCTAssertTrue(html.contains("ChatGPT"))
        // Documented robots.txt refusal is surfaced, not buried.
        XCTAssertTrue(html.contains("ignores robots.txt"))
        // Legend carries its own counts: the relief the light palette needs.
        XCTAssertTrue(html.contains("User-triggered"))
        XCTAssertTrue(html.contains("Model training"))
        // Two shades in the page bars means a legend for them too.
        XCTAssertTrue(html.contains("Crawled without a person asking"))
    }

    /// Every switcher link and range pill names its site, `all` included, so
    /// picking "All sites" is not overridden by the host default on the next
    /// click.
    func testSwitcherShowsLogosAndEveryLinkNamesItsSite() {
        let html = DashboardPage.render(
            data: BotDashboardData(),
            range: .month,
            sites: sites,
            selectedSite: sites[1],
            generatedAt: Date()
        )
        XCTAssertTrue(html.contains("/images/developed/sd-logo.png"))
        XCTAssertTrue(html.contains("/images/marketing/sm-logo.png"))
        XCTAssertTrue(html.contains("?site=all&amp;range=30d"))
        XCTAssertTrue(html.contains("?site=developed&amp;range=30d"))
        // Range pills keep the selected site.
        XCTAssertTrue(html.contains("?site=marketing&amp;range=24h"))
        XCTAssertFalse(html.contains("<select"))
    }

    func testLoginPageRendersAndShowsErrors() {
        XCTAssertTrue(LoginPage.render(error: nil).contains("Sign in"))
        XCTAssertTrue(LoginPage.render(error: "nope").contains("nope"))
    }
}

final class DashboardSiteSelectionTests: XCTestCase {

    private let config = BotKitConfiguration(
        siteKey: { _ in "developed" },
        sites: [
            BotDashboardSite(key: "developed", name: "Swiftly Developed"),
            BotDashboardSite(key: "marketing", name: "Swiftly Marketing"),
        ],
        signingSecret: "test-secret"
    )

    /// Signing in on swiftly-marketing.com lands on marketing, not all sites.
    func testNoSiteParameterOpensOnTheHostSite() {
        XCTAssertEqual(config.site(forKey: nil, hostSiteKey: "marketing")?.key, "marketing")
        XCTAssertEqual(config.site(forKey: nil, hostSiteKey: "developed")?.key, "developed")
    }

    func testExplicitAllOverridesTheHostSite() {
        XCTAssertNil(config.site(forKey: "all", hostSiteKey: "marketing"))
    }

    func testExplicitSiteOverridesTheHostSite() {
        XCTAssertEqual(config.site(forKey: "developed", hostSiteKey: "marketing")?.key, "developed")
    }

    func testUnknownSiteFallsBackToAllSites() {
        XCTAssertNil(config.site(forKey: "nope", hostSiteKey: "marketing"))
    }
}
