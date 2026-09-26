import XCTest
import XCTVapor
@testable import SwiftlyBotKit

final class UserAgentSummaryTests: XCTestCase {

    private func summary(_ ua: String, brands: String? = nil, mobile: String? = nil) -> UserAgentSummary {
        UserAgentSummary(userAgent: ua, clientHintBrands: brands, clientHintMobile: mobile)
    }

    func testCommonBrowsers() {
        let cases: [(String, UserAgentSummary.Device, String, String, String, String)] = [
            ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
             .desktop, "Safari", "Safari 18", "macOS", "macOS"),
            ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
             .mobile, "Safari", "Safari 18", "iOS", "iOS 18"),
            ("Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
             .tablet, "Safari", "Safari 17", "iPadOS", "iPadOS 17"),
            ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
             .desktop, "Chrome", "Chrome 128", "Windows", "Windows"),
            ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.2739.42",
             .desktop, "Edge", "Edge 128", "Windows", "Windows"),
            ("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36",
             .mobile, "Chrome", "Chrome 128", "Android", "Android"),
            ("Mozilla/5.0 (Android 14; Mobile; rv:130.0) Gecko/130.0 Firefox/130.0",
             .mobile, "Firefox", "Firefox 130", "Android", "Android 14"),
            ("Mozilla/5.0 (Linux; Android 13; SM-X700) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Safari/537.36",
             .tablet, "Samsung Internet", "Samsung Internet 25", "Android", "Android 13"),
            ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/128.0.6613.98 Mobile/15E148 Safari/604.1",
             .mobile, "Chrome", "Chrome 128", "iOS", "iOS 17"),
            ("Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0",
             .desktop, "Firefox", "Firefox 130", "Linux", "Linux"),
            ("Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
             .desktop, "Chrome", "Chrome 128", "ChromeOS", "ChromeOS"),
            ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/470.0]",
             .mobile, "Facebook", "Facebook", "iOS", "iOS 17"),
            ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
             .mobile, "iOS web view", "iOS web view", "iOS", "iOS 17"),
        ]
        for (ua, device, browser, browserVersion, os, osVersion) in cases {
            let s = summary(ua)
            XCTAssertEqual(s.device, device, ua)
            XCTAssertEqual(s.browser, browser, ua)
            XCTAssertEqual(s.browserVersion, browserVersion, ua)
            XCTAssertEqual(s.os, os, ua)
            XCTAssertEqual(s.osVersion, osVersion, ua)
        }
    }

    func testClientHints() {
        let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
        let brave = summary(chrome, brands: "\"Chromium\";v=\"128\", \"Not;A=Brand\";v=\"24\", \"Brave\";v=\"128\"")
        XCTAssertEqual(brave.browserVersion, "Brave 128")
        XCTAssertEqual(summary(chrome, mobile: "?1").device, .mobile)
    }

    /// A version is a small number or nothing, never whatever the header
    /// happened to hold.
    func testGarbageNeverBecomesAValue() {
        let s = summary("Mozilla/5.0 Firefox/12345678901234567890 <script>")
        XCTAssertEqual(s.browserVersion, "Firefox")
        XCTAssertEqual(summary("").browser, UserAgentSummary.otherFamily)
    }
}

final class ReferrerSummaryTests: XCTestCase {

    private func summary(_ referer: String?, host: String? = "swiftly-developed.com") -> ReferrerSummary {
        ReferrerSummary(referer: referer, host: host)
    }

    func testDirectInternalAndExternal() {
        XCTAssertEqual(summary(nil).referrer, "(direct)")
        XCTAssertEqual(summary("").referrer, "(direct)")
        let internalLink = summary("https://www.swiftly-developed.com/insights/some-article/?utm_source=x#top", host: "swiftly-developed.com:443")
        XCTAssertEqual(internalLink.referrer, "(internal)")
        XCTAssertEqual(internalLink.previousPage, "/insights/some-article/")
        let google = summary("https://www.google.com/search?q=my+name+is+private")
        XCTAssertEqual(google.referrer, "google.com")
        XCTAssertEqual(google.previousPage, "(none)")
        XCTAssertEqual(summary("https://l.facebook.com/l.php?u=x").referrer, "facebook.com")
        XCTAssertEqual(summary("https://m.example").referrer, "m.example")
        XCTAssertEqual(summary("https://chatgpt.com/c/abc").referrer, "chatgpt.com")
        XCTAssertEqual(summary("android-app://com.google.android.gm/").referrer, "android-app://com.google.android.gm")
    }

    /// Only a hostname survives: no IP literal, no path, no credentials.
    func testNothingPersonalSurvives() {
        XCTAssertEqual(summary("http://81.82.83.84/admin").referrer, "(other)")
        XCTAssertEqual(summary("http://[2a02:1810::1]/").referrer, "(other)")
        XCTAssertEqual(summary("https://user:secret@example.com/").referrer, "example.com")
        XCTAssertEqual(summary("javascript:alert(1)").referrer, "(other)")
        XCTAssertEqual(summary("https://" + String(repeating: "a", count: 120) + ".com/").referrer, "(other)")
    }
}

final class CampaignSummaryTests: XCTestCase {

    func testReadsTheFourParameters() {
        let c = CampaignSummary(query: "utm_source=Newsletter&utm_medium=email&utm_campaign=Continuity+Series&utm_content=footer-link&utm_term=my+secret+query")
        XCTAssertEqual(c.source, "newsletter")
        XCTAssertEqual(c.medium, "email")
        XCTAssertEqual(c.name, "continuity-series")
        XCTAssertEqual(c.content, "footer-link")
        let none = CampaignSummary(query: nil)
        XCTAssertEqual([none.source, none.medium, none.name, none.content], Array(repeating: "(none)", count: 4))
    }

    /// Anything that could carry a person is refused whole, not cleaned up.
    func testRefusesIdentifiers() {
        XCTAssertEqual(CampaignSummary.token("jane.doe@example.com"), "(other)")
        XCTAssertEqual(CampaignSummary.token("jane.doe%40example.com".removingPercentEncoding!), "(other)")
        XCTAssertEqual(CampaignSummary.token("user-4815162342"), "(other)")
        XCTAssertEqual(CampaignSummary.token("spring-2026"), "spring-2026")
        XCTAssertEqual(CampaignSummary.token(String(repeating: "a", count: 65)), "(other)")
        XCTAssertEqual(CampaignSummary.token("ünïcode"), "(other)")
        XCTAssertEqual(CampaignSummary(query: "utm_source=%zz").source, "(other)")
    }
}

final class LanguageSummaryTests: XCTestCase {
    func testPrimarySubtag() {
        XCTAssertEqual(LanguageSummary.language(acceptLanguage: "nl-BE,nl;q=0.9,en;q=0.8"), "nl")
        XCTAssertEqual(LanguageSummary.language(acceptLanguage: "EN-us"), "en")
        XCTAssertEqual(LanguageSummary.language(acceptLanguage: "*"), "(none)")
        XCTAssertEqual(LanguageSummary.language(acceptLanguage: nil), "(none)")
        XCTAssertEqual(LanguageSummary.language(acceptLanguage: "fil-PH"), "(other)")
        XCTAssertEqual(LanguageSummary.language(acceptLanguage: "<b>"), "(other)")
    }
}

final class CountryLookupTests: XCTestCase {

    /// A table with 0.0.0.0 ZZ, 1.0.0.0 AU, 81.0.0.0 BE and ::/0 ZZ,
    /// 2a02:1800:: BE.
    static func sampleTable() -> Data {
        var data = Data("BKCC".utf8)
        data.append(1)
        let attribution = Array("Test data".utf8)
        data.append(contentsOf: [0, UInt8(attribution.count)])
        data.append(contentsOf: attribution)
        func u32(_ v: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(v >> ($0 * 8) & 0xFF) } }
        func u64(_ v: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8(v >> ($0 * 8) & 0xFF) } }
        data.append(contentsOf: u32(3) + u32(2))
        data.append(contentsOf: u32(0) + u32(0x0100_0000) + u32(0x5100_0000))
        data.append(contentsOf: Array("ZZAUBE".utf8))
        data.append(contentsOf: u64(0) + u64(0x2A02_1800_0000_0000))
        data.append(contentsOf: Array("ZZBE".utf8))
        return data
    }

    func testLooksUpBothFamilies() throws {
        let lookup = try CountryLookup(data: Self.sampleTable())
        XCTAssertEqual(lookup.attribution, "Test data")
        XCTAssertEqual(lookup.rangeCount, 5)
        XCTAssertEqual(lookup.country(for: "81.82.83.84"), "BE")
        XCTAssertEqual(lookup.country(for: "1.2.3.4"), "AU")
        XCTAssertEqual(lookup.country(for: "0.0.0.1"), "ZZ")
        XCTAssertEqual(lookup.country(for: "::ffff:81.1.1.1"), "BE")
        XCTAssertEqual(lookup.country(for: "2a02:1810::1"), "BE")
        XCTAssertEqual(lookup.country(for: "2001:db8::1"), "ZZ")
        XCTAssertEqual(lookup.country(for: "not an ip"), "ZZ")
        XCTAssertEqual(lookup.country(for: nil), "ZZ")
    }

    func testRefusesAMalformedTable() {
        XCTAssertThrowsError(try CountryLookup(data: Data("nope".utf8)))
        var truncated = Self.sampleTable()
        truncated.removeLast()
        XCTAssertThrowsError(try CountryLookup(data: truncated))
        var badCode = Self.sampleTable()
        badCode[badCode.count - 1] = UInt8(ascii: "1")
        XCTAssertThrowsError(try CountryLookup(data: badCode))
    }

    /// The table the Server ships, when this checkout has it.
    func testTheShippedTable() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Server/Data/country-ranges.bin").path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no Server/Data/country-ranges.bin") }
        let lookup = try CountryLookup(contentsOfFile: path)
        XCTAssertGreaterThan(lookup.rangeCount, 500_000)
        XCTAssertEqual(lookup.country(for: "8.8.8.8"), "US")
        XCTAssertEqual(lookup.country(for: "192.168.1.1"), "ZZ")
    }
}

final class PageViewDimensionModelTests: XCTestCase {

    func testPairsNeverRepeatAFamilyOrIncludeThePreviousPage() {
        XCTAssertEqual(PageViewDimension.pairs.count, 64)
        XCTAssertFalse(PageViewDimension.pairs.contains { $0 == .previousPage || $1 == .previousPage })
        XCTAssertFalse(PageViewDimension.isPair(.browser, .browserVersion))
        XCTAssertTrue(PageViewDimension.isPair(.device, .country))
        XCTAssertTrue(PageViewDimension.pairs.allSatisfy { $0 < $1 })
    }

    func testDays() {
        let brussels = TimeZone(identifier: "Europe/Brussels")!
        // 2026-09-26 22:30 UTC is already the 27th in Brussels.
        let late = Date(timeIntervalSince1970: 1_790_461_800)
        XCTAssertEqual(PageViewDay(late, in: TimeZone(secondsFromGMT: 0)!).isoDate, "2026-09-26")
        XCTAssertEqual(PageViewDay(late, in: brussels).isoDate, "2026-09-27")
        XCTAssertEqual(PageViewDay(daysSince1970: 0).isoDate, "1970-01-01")
        XCTAssertEqual(PageViewDay(daysSince1970: -1).isoDate, "1969-12-31")
        XCTAssertEqual(PageViewDay(daysSince1970: 11_016).isoDate, "2000-02-29")
    }

    func testFactsFromARequest() throws {
        var headers = HTTPHeaders()
        headers.add(name: .userAgent, value: safariUA)
        headers.add(name: .referer, value: "https://news.ycombinator.com/item?id=1")
        headers.add(name: .acceptLanguage, value: "fr-BE,fr;q=0.9")
        let facts = PageViewFacts.derive(
            headers: headers, query: "utm_source=hn", host: "swiftly-developed.com",
            clientIP: "81.82.83.84", countries: try CountryLookup(data: CountryLookupTests.sampleTable())
        )
        XCTAssertEqual(facts[.country], "BE")
        XCTAssertEqual(facts[.referrer], "news.ycombinator.com")
        XCTAssertEqual(facts[.campaignSource], "hn")
        XCTAssertEqual(facts[.campaignMedium], "(none)")
        XCTAssertEqual(facts[.device], "desktop")
        XCTAssertEqual(facts[.language], "fr")
        XCTAssertEqual(facts.values.count, PageViewDimension.allCases.count)
        // Nothing in the facts is the address or a header verbatim.
        let stored = facts.values.map(\.value)
        XCTAssertFalse(stored.contains { $0.contains("81.82") || $0.contains("Mozilla") || $0.contains("item?id") })

        let withoutCountries = PageViewFacts.derive(headers: headers, query: nil, host: nil, clientIP: "81.82.83.84", countries: nil)
        XCTAssertNil(withoutCountries[.country])
    }

    func testCountingAddsOnePerDimensionAndPair() async {
        var configuration = BotKitConfiguration.PageViews(isEnabled: true)
        configuration.dimensions.isEnabled = true
        let counter = PageViewCounter(database: { nil }, configuration: configuration, logger: Logger(label: "test"))
        var headers = HTTPHeaders()
        headers.add(name: .userAgent, value: safariUA)
        let facts = PageViewFacts.derive(headers: headers, query: nil, host: nil, clientIP: nil, countries: nil)
        counter.record(siteKey: "a", path: "/x/", facts: facts)
        counter.record(siteKey: "a", path: "/x/", facts: facts)
        let dimensions = counter.dimensionTally!.drain()
        XCTAssertEqual(dimensions.count, PageViewDimension.allCases.count - 1)
        XCTAssertTrue(dimensions.values.allSatisfy { $0 == 2 })
        let pairs = counter.pairTally!.drain()
        // Twelve pairable dimensions without the country: 11 choose 2, less
        // the two family pairs.
        XCTAssertEqual(pairs.count, 53)
        await counter.shutdown()
    }

    func testCampaignValuesAreCappedPerDay() {
        let cap = CampaignValueCap(maximum: 2)
        let day = PageViewDay(daysSince1970: 20_000)
        func facts(_ source: String) -> PageViewFacts {
            PageViewFacts.derive(headers: [:], query: "utm_source=\(source)", host: nil, clientIP: nil, countries: nil)
        }
        XCTAssertEqual(cap.capped(facts("a"), siteKey: "s", day: day)[.campaignSource], "a")
        XCTAssertEqual(cap.capped(facts("b"), siteKey: "s", day: day)[.campaignSource], "b")
        XCTAssertEqual(cap.capped(facts("c"), siteKey: "s", day: day)[.campaignSource], "(other)")
        XCTAssertEqual(cap.capped(facts("a"), siteKey: "s", day: day)[.campaignSource], "a")
        XCTAssertEqual(cap.capped(facts("c"), siteKey: "other-site", day: day)[.campaignSource], "c")
        let tomorrow = PageViewDay(daysSince1970: 20_001)
        XCTAssertEqual(cap.capped(facts("c"), siteKey: "s", day: tomorrow)[.campaignSource], "c")
    }
}

final class PageViewColorByTests: XCTestCase {

    func testQueryValuesRoundTrip() {
        for option in PageViewColorBy.options(dimensionsEnabled: true) {
            XCTAssertEqual(PageViewColorBy(query: option.queryValue), option)
        }
        XCTAssertEqual(PageViewColorBy(query: "nonsense"), .none)
        XCTAssertEqual(PageViewColorBy.options(dimensionsEnabled: false), [.none, .page, .section])
        XCTAssertEqual(PageViewColorBy.options(dimensionsEnabled: true).count, 16)
    }

    private let buckets = (0..<3).map { Date(timeIntervalSince1970: Double($0) * 86_400) }

    /// Ranked by total; small values, the overflow and the views the
    /// breakdown cannot account for all in Other.
    func testBuildRanksFoldsAndFillsTheGap() {
        let rows: [(bucket: Int, value: String, count: Int)] = [
            (0, "BE", 10), (1, "BE", 20), (2, "US", 40), (0, "LU", 2), (1, "(other)", 6),
        ]
        let breakdown = PageViewBreakdown.build(
            colorBy: .dimension(.country), buckets: buckets, isDailyFallback: false,
            rows: rows, bucketTotals: [15, 26, 40], smallCellThreshold: 5
        )
        XCTAssertEqual(breakdown.series.map(\.label), ["US", "BE", "Other"])
        // LU and "(other)", plus the 3 views of the first day with no value.
        XCTAssertEqual(breakdown.series[2].counts, [5, 6, 0])
        XCTAssertEqual(breakdown.total, 81)
        XCTAssertEqual(breakdown.color(at: 0), "var(--cat-1)")
        XCTAssertEqual(breakdown.color(at: 2), DashboardTheme.otherColor)
        XCTAssertEqual(breakdown.display(3), "<5")
        XCTAssertEqual(breakdown.display(0), "0")
        XCTAssertEqual(breakdown.display(1_234), "1,234")
    }

    func testAtMostTwentyThreeValuesKeepTheirOwnColour() {
        let rows = (0..<30).map { (bucket: 0, value: "/page-\($0)/", count: 100 - $0) }
        let breakdown = PageViewBreakdown.build(colorBy: .page, buckets: buckets, isDailyFallback: false,
                                                rows: rows, bucketTotals: nil, smallCellThreshold: nil)
        XCTAssertEqual(breakdown.series.count, 24)
        XCTAssertEqual(breakdown.series.last?.kind, .other)
        XCTAssertEqual(breakdown.series.last?.total, (23..<30).map { 100 - $0 }.reduce(0, +))
        XCTAssertEqual(Set((0..<23).map(breakdown.color(at:))).count, 23)
    }

    func testTheChartCarriesTheMenuTheStackAndTheTotals() {
        var data = PageViewData()
        data.people = 30
        data.distinctPages = 1
        data.series = [.init(bucket: buckets[0], people: 30, agents: 0)]
        let breakdown = PageViewBreakdown.build(
            colorBy: .dimension(.referrer), buckets: [buckets[0]], isDailyFallback: false,
            rows: [(0, "google.com", 20), (0, "<script>x</script>.com", 7), (0, "tiny.example", 3)],
            bucketTotals: [30], smallCellThreshold: 5
        )
        let html = PageViewsPage.render(
            data: data, range: .week, sites: [], selectedSite: nil, generatedAt: Date(),
            audience: .people, colorBy: .dimension(.referrer),
            colorOptions: PageViewColorBy.options(dimensionsEnabled: true), breakdown: breakdown
        )
        XCTAssertTrue(html.contains("class=\"colorby\""))
        XCTAssertTrue(html.contains("color=utm_source"))
        XCTAssertTrue(html.contains("aria-current=\"true\">Referrer</a>"))
        XCTAssertTrue(html.contains("legend totals"))
        XCTAssertTrue(html.contains("google.com"))
        XCTAssertTrue(html.contains("var(--cat-2)"))
        XCTAssertFalse(html.contains("<script>x"))
        // The range pills keep the colour choice.
        XCTAssertTrue(html.contains("range=30d&amp;color=referrer") || html.contains("range=30d&color=referrer"))
        // The small value is folded into Other and its count masked.
        XCTAssertFalse(html.contains("tiny.example"))
        XCTAssertTrue(html.contains("&lt;5") || html.contains("<5</b>"))
    }

    /// A page's bar is split in the chart's colours; its popover lists the
    /// parts largest first with the catch-alls last.
    func testPageRowsSplitInTheChartsColours() {
        var breakdown = PageViewBreakdown.build(
            colorBy: .dimension(.country), buckets: [buckets[0]], isDailyFallback: false,
            rows: [(0, "BE", 30), (0, "US", 20)], bucketTotals: [60], smallCellThreshold: 5
        )
        breakdown.pageSplits["/a/"] = [4, 12, 8]
        let row = PageViewsPage.row(for: .init(path: "/a/", people: 24, agents: 0), breakdown: breakdown)
        XCTAssertEqual(row.parts.map(\.color), ["var(--cat-1)", "var(--cat-2)", DashboardTheme.otherColor])
        XCTAssertEqual(row.details.map(\.label), ["US", "BE", "Other"])
        XCTAssertEqual(row.details[1].countLabel, "<5")
        let html = BotCharts.barRows([row])
        XCTAssertTrue(html.contains("fill split"))
    }

    func testChartPopoversSortDescendingAndUseTwoColumnsWhenLong() {
        let segments = (0..<10).map { BotCharts.ColumnSegment(label: "v\($0)", color: "red", count: $0 + 1) }
            + [BotCharts.ColumnSegment(label: "Other", color: "grey", count: 50, isRemainder: true)]
        let html = BotCharts.columns([(buckets[0], segments)], range: .week, timeZone: TimeZone(secondsFromGMT: 0)!,
                                     ariaLabel: "x", popoverDescending: true)
        let v9 = html.range(of: ">v9<")!.lowerBound, v0 = html.range(of: ">v0<")!.lowerBound
        let other = html.range(of: ">Other<")!.lowerBound
        XCTAssertLessThan(v9, v0)
        XCTAssertLessThan(v0, other)
        XCTAssertTrue(html.contains("tip many"))
        XCTAssertTrue(html.contains("tip-grid"))
    }

    /// A dimension's days are the zone they were stored in; a viewer in
    /// another zone is told so rather than shown shifted days.
    func testDimensionChartsNameTheZoneTheirDaysAreIn() {
        var breakdown = PageViewBreakdown.build(colorBy: .dimension(.country), buckets: [buckets[0]], isDailyFallback: false,
                                                rows: [(0, "BE", 9)], bucketTotals: [9], smallCellThreshold: 5)
        breakdown.dayTimeZone = TimeZone(identifier: "Europe/Brussels")
        let hint = PageViewsPage.chartHint(PageViewData(), range: .week, timeZone: TimeZone(identifier: "Asia/Manila")!,
                                           audience: .people, breakdown: breakdown)
        XCTAssertTrue(hint.hasPrefix("Daily buckets, Europe/Brussels."))
        XCTAssertTrue(hint.contains("counted per Europe/Brussels day"))
        let same = PageViewsPage.chartHint(PageViewData(), range: .week, timeZone: TimeZone(identifier: "Europe/Brussels")!,
                                           audience: .people, breakdown: breakdown)
        XCTAssertFalse(same.contains("counted per"))
    }

    func testNoMenuForOtherAudiences() {
        var data = PageViewData()
        data.people = 1
        data.agents = 1
        data.series = [.init(bucket: buckets[0], people: 1, agents: 1)]
        let html = PageViewsPage.render(data: data, range: .week, sites: [], selectedSite: nil, generatedAt: Date(),
                                        audience: .agents, colorOptions: PageViewColorBy.options(dimensionsEnabled: true))
        XCTAssertFalse(html.contains("class=\"colorby\""))
    }
}
