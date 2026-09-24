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
