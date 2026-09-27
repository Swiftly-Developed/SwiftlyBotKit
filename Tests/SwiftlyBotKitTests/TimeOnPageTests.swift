import Foundation
import XCTest
import Vapor
@testable import SwiftlyBotKit

final class TimeOnPageTests: XCTestCase {

    // MARK: - Beacon

    func testParsesABeacon() {
        XCTAssertEqual(TimeOnPageBeacon.parse("42\n/blog/one/"), TimeOnPageBeacon(seconds: 42, path: "/blog/one/"))
        XCTAssertEqual(TimeOnPageBeacon.parse("0\n/"), TimeOnPageBeacon(seconds: 0, path: "/"))
    }

    func testDropsTheQueryAndCollapsesSlashes() {
        XCTAssertEqual(TimeOnPageBeacon.parse("5\n//blog//one/?utm_source=x#top")?.path, "/blog/one/")
    }

    func testCapsTheSeconds() {
        XCTAssertEqual(TimeOnPageBeacon.parse("99999\n/")?.seconds, TimeOnPageBand.maximumSeconds)
    }

    func testRefusesWhatIsNotABeacon() {
        for body in ["", "42", "42 /x", "-1\n/", "4.2\n/", "12a\n/", "12345678\n/", "42\nblog", "42\nhttps://evil.example/",
                     "\u{0664}\u{0662}\n/", "42\n/" + String(repeating: "a", count: 1_100)] {
            XCTAssertNil(TimeOnPageBeacon.parse(body), body.debugDescription)
        }
    }

    // MARK: - Bands

    func testBands() {
        XCTAssertEqual(TimeOnPageBand(seconds: 0), .under10s)
        XCTAssertEqual(TimeOnPageBand(seconds: 9), .under10s)
        XCTAssertEqual(TimeOnPageBand(seconds: 10), .under30s)
        XCTAssertEqual(TimeOnPageBand(seconds: 59), .under1m)
        XCTAssertEqual(TimeOnPageBand(seconds: 60), .under3m)
        XCTAssertEqual(TimeOnPageBand(seconds: 599), .under10m)
        XCTAssertEqual(TimeOnPageBand(seconds: 600), .over10m)
        // Stored values: frozen.
        XCTAssertEqual(TimeOnPageBand.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5])
    }

    func testMedianAndGlanceShare() {
        var data = TimeOnPageData()
        data.bands = [4, 1, 1, 3, 1, 0]
        data.total = .init(readings: 10, seconds: 700)
        // The fifth of ten readings is the middle one.
        XCTAssertEqual(data.medianBand, .under30s)
        XCTAssertEqual(data.glanceShare, 0.4)
        XCTAssertEqual(data.total.average, 70)
        XCTAssertNil(TimeOnPageData().medianBand)
    }

    // MARK: - Known paths

    func testKnownPathsKeepTodayAndYesterday() {
        let paths = KnownPagePaths(maximumPerDay: 10)
        let day = PageViewDay(daysSince1970: 20_000)
        paths.insert(siteKey: "a", path: "/x/", day: day)
        XCTAssertTrue(paths.contains(siteKey: "a", path: "/x/", day: day))
        XCTAssertFalse(paths.contains(siteKey: "b", path: "/x/", day: day))
        XCTAssertTrue(paths.contains(siteKey: "a", path: "/x/", day: PageViewDay(daysSince1970: 20_001)))
        XCTAssertFalse(paths.contains(siteKey: "a", path: "/x/", day: PageViewDay(daysSince1970: 20_002)))
    }

    func testKnownPathsAreCapped() {
        let paths = KnownPagePaths(maximumPerDay: 2)
        let day = PageViewDay(daysSince1970: 20_000)
        for path in ["/a", "/b", "/c"] { paths.insert(siteKey: "s", path: path, day: day) }
        XCTAssertFalse(paths.contains(siteKey: "s", path: "/c", day: day))
    }

    // MARK: - Counter

    private func counter(timeOnPage: Bool = true) -> PageViewCounter {
        var configuration = BotKitConfiguration.PageViews(isEnabled: true)
        configuration.timeOnPage.isEnabled = timeOnPage
        return PageViewCounter(database: { nil }, configuration: configuration, logger: Logger(label: "test"))
    }

    func testAReadingNeedsACountedView() {
        let counter = counter()
        let now = Date(timeIntervalSince1970: 1_790_400_000)
        XCTAssertFalse(counter.recordTimeOnPage(siteKey: "a", path: "/x/", seconds: 30, at: now))
        counter.record(siteKey: "a", path: "/x/", at: now)
        XCTAssertTrue(counter.recordTimeOnPage(siteKey: "a", path: "/x/", seconds: 30, at: now))
        XCTAssertTrue(counter.recordTimeOnPage(siteKey: "a", path: "/x/", seconds: 5_000, at: now))
        let sums = counter.timeOnPageTally!.drain()
        let day = PageViewDay(now, in: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(sums[TimeOnPageKey(siteKey: "a", day: day, path: "/x/", band: .under1m)], .init(readings: 1, seconds: 30))
        XCTAssertEqual(sums[TimeOnPageKey(siteKey: "a", day: day, path: "/x/", band: .over10m)], .init(readings: 1, seconds: 1_800))
    }

    func testATrailingSlashIsIgnoredWhenMatching() {
        let counter = counter()
        let now = Date(timeIntervalSince1970: 1_790_400_000)
        counter.record(siteKey: "a", path: "/about", at: now)
        counter.record(siteKey: "a", path: "/team/", at: now)
        counter.record(siteKey: "a", path: "/", at: now)
        XCTAssertTrue(counter.recordTimeOnPage(siteKey: "a", path: "/about/", seconds: 5, at: now))
        XCTAssertTrue(counter.recordTimeOnPage(siteKey: "a", path: "/team", seconds: 5, at: now))
        XCTAssertTrue(counter.recordTimeOnPage(siteKey: "a", path: "/", seconds: 5, at: now))
        XCTAssertFalse(counter.recordTimeOnPage(siteKey: "a", path: "/about//", seconds: 5, at: now))
        // Stored as counted.
        XCTAssertEqual(Set(counter.timeOnPageTally!.drain().keys.map(\.path)), ["/about", "/team/", "/"])
    }

    func testOffKeepsNothing() {
        let counter = counter(timeOnPage: false)
        counter.record(siteKey: "a", path: "/x/")
        XCTAssertFalse(counter.recordTimeOnPage(siteKey: "a", path: "/x/", seconds: 30))
        XCTAssertNil(counter.timeOnPageTally)
    }

    func testTallyIsCappedAndRestores() {
        let tally = TimeOnPageTally(maximumKeys: 1)
        let day = PageViewDay(daysSince1970: 1)
        let a = TimeOnPageKey(siteKey: "s", day: day, path: "/a", band: .under10s)
        let b = TimeOnPageKey(siteKey: "s", day: day, path: "/b", band: .under10s)
        XCTAssertNil(tally.add(a, seconds: 3))
        XCTAssertEqual(tally.add(b, seconds: 3), 1)
        let drained = tally.drain()
        XCTAssertEqual(tally.restore(drained), 0)
        XCTAssertEqual(tally.restore([b: .init(readings: 2, seconds: 4)]), 2)
        XCTAssertEqual(tally.drain()[a], .init(readings: 1, seconds: 3))
    }

    // MARK: - Script and configuration

    func testScriptPostsToTheConfiguredPath() {
        let source = TimeOnPageScript.source(beaconPath: "/stats/time")
        XCTAssertTrue(source.contains("sendBeacon(\"/stats/time\""))
        XCTAssertFalse(source.contains("cookie"))
        XCTAssertFalse(source.contains("localStorage"))
    }

    func testPaths() {
        var timeOnPage = BotKitConfiguration.PageViews.TimeOnPage()
        XCTAssertEqual(timeOnPage.normalizedPath, "/_botkit/time")
        XCTAssertEqual(timeOnPage.scriptPath, "/_botkit/time.js")
        timeOnPage.path = "stats/time/"
        XCTAssertEqual(timeOnPage.normalizedPath, "/stats/time")
    }

    func testValidation() {
        var config = BotKitConfiguration()
        config.pageViews.isEnabled = true
        config.pageViews.timeOnPage.isEnabled = true
        XCTAssertNoThrow(try config.validate())
        for bad in ["/", "/a b", "/../x", "/admin/ai-bots/time", "/x/:id"] {
            config.pageViews.timeOnPage.path = bad
            XCTAssertThrowsError(try config.validate(), bad) { error in
                guard case BotKitConfigurationError.invalidTimeOnPagePath = error else {
                    return XCTFail("\(bad): \(error)")
                }
            }
        }
        // Not checked while off.
        config.pageViews.timeOnPage.isEnabled = false
        XCTAssertNoThrow(try config.validate())
    }

    func testTheBeaconIsNotRecordedAsAPage() {
        var config = BotKitConfiguration()
        config.pageViews.isEnabled = true
        config.pageViews.timeOnPage.isEnabled = true
        let classifier = BotRequestClassifier(configuration: config)
        XCTAssertTrue(classifier.isExcluded(path: "/_botkit/time"))
        XCTAssertTrue(classifier.isExcluded(path: "/_botkit/time.js"))
        XCTAssertFalse(classifier.isExcluded(path: "/_botkit/timeline"))
    }

    // MARK: - Dashboard

    func testDeltas() {
        typealias Delta = DashboardPage.TileDelta
        XCTAssertEqual(Delta(112, was: 100, period: "p", tone: .positive).text, "\u{25B2} 12%")
        XCTAssertEqual(Delta(92, was: 100, period: "p", tone: .positive).direction, .down)
        XCTAssertEqual(Delta(100, was: 100, period: "p", tone: .positive).text, "no change")
        XCTAssertEqual(Delta(5, was: 0, period: "p", tone: .positive).text, "new")
        XCTAssertEqual(Delta(0, was: 0, period: "p", tone: .positive).direction, .flat)
    }

    func testDurationsAndLabels() {
        XCTAssertEqual(PageViewsPage.duration(45), "45 s")
        XCTAssertEqual(PageViewsPage.duration(125), "2 min 5 s")
        XCTAssertEqual(PageViewsPage.duration(120), "2 min")
        XCTAssertEqual(PageViewsPage.duration(725), "12 min")
        XCTAssertEqual(PageViewsPage.previousLabel(.day), "previous 24 hours")
        XCTAssertEqual(PageViewsPage.previousLabel(.month), "previous 30 days")
        XCTAssertEqual(PageViewsPage.countryName("ZZ"), "Unknown")
        XCTAssertEqual(PageViewsPage.countryName("BE"), "Belgium")
        XCTAssertEqual(PageViewsPage.countryName("<b>"), "<b>")
    }

    func testRendersBothRowsOfTilesAndTheNewCards() {
        var data = PageViewData()
        data.people = 229
        data.agents = 145
        data.peopleBucketCount = 24
        data.topPages = [.init(path: "/", people: 123, agents: 10), .init(path: "/rare/", people: 2, agents: 0)]
        var comparison = PageViewComparison()
        comparison.current = .init(peopleViews: 229, peoplePages: 34, agentReads: 145, agentPages: 40,
                                   agentAddresses: 61, agents: 9, referrals: 12)
        comparison.previous = .init(peopleViews: 199, peoplePages: 34, agentReads: 150, agentPages: 38,
                                    agentAddresses: 60, agents: 9, referrals: 0)
        comparison.peopleComparable = true
        comparison.agentsComparable = true
        var time = TimeOnPageData()
        time.bands = [3, 2, 1, 4, 0, 0]
        time.total = .init(readings: 10, seconds: 500)
        time.pages = ["/": .init(readings: 8, seconds: 480), "/rare/": .init(readings: 2, seconds: 20)]
        time.isDailyFallback = true
        let ranking = PageViewRanking(rows: [.init(value: "google.com", count: 20)], total: 23, folded: 3)
        let countries = PageViewRanking(rows: [.init(value: "BE", count: 30)], total: 30)
        let landing = PageViewRanking(rows: [.init(value: "/", count: 50)], total: 60, folded: 10)
        let html = PageViewsPage.render(
            data: data, range: .day, sites: [], selectedSite: nil, generatedAt: Date(),
            extras: .init(comparison: comparison, timeOnPage: time, referrers: ranking,
                          countries: countries, landingPages: landing, smallCellThreshold: 5)
        )
        for text in ["People", "AI agents", "Page views per hour", "Unique pages", "Unique visitors", "Reads per hour",
                     "Time on page", "50 s", "From AI assistants", "\u{25B2} 15%", "vs previous 24 hours", "new",
                     "Top referrers", "google.com", "Others (fewer than 5 views each)", "Top countries", "Belgium",
                     "Top landing pages", "1 min on page", "10 min or more"] {
            XCTAssertTrue(html.contains(text), text)
        }
        // Two readings are too few to show a page's average.
        XCTAssertFalse(html.contains("10 s on page"))
        // People come first unless the agents are chosen.
        XCTAssertLessThan(html.range(of: ">People<")!.lowerBound, html.range(of: ">AI agents</h2>")!.lowerBound)
        let agents = PageViewsPage.render(data: data, range: .day, sites: [], selectedSite: nil, generatedAt: Date(),
                                          audience: .agents, extras: .init(comparison: comparison))
        XCTAssertLessThan(agents.range(of: ">AI agents</h2>")!.lowerBound, agents.range(of: ">People</h2>")!.lowerBound)
        XCTAssertFalse(agents.contains("Top referrers"))
    }

    func testWithoutAComparisonTheSingleRowStays() {
        var data = PageViewData()
        data.people = 5
        let html = PageViewsPage.render(data: data, range: .week, sites: [], selectedSite: nil, generatedAt: Date())
        XCTAssertTrue(html.contains("Pages read"))
        XCTAssertFalse(html.contains("class=\"tile-group\""))
    }
}
