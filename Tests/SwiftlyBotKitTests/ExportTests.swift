import XCTest
@testable import SwiftlyBotKit

final class ExportOptionsTests: XCTestCase {

    private let utc = TimeZone(secondsFromGMT: 0)!
    private let brussels = TimeZone(identifier: "Europe/Brussels")!
    /// 2026-09-26 12:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_425_200)

    private func options(_ query: [String: String], people: Bool = true) -> BotExportOptions {
        BotExportOptions(query: { query[$0] }, offeredRanges: BotDateRange.allCases, defaultRange: .week,
                         peopleAvailable: people)
    }

    private func submitted(_ extra: [String: String]) -> BotExportOptions {
        options(["v": "1", "agents": "1"].merging(extra) { $1 })
    }

    // MARK: Parsing

    func testAPlainVisitGetsTheDefaults() {
        let visit = options(["range": "30d"])
        XCTAssertEqual(visit, .initial(range: .month, peopleAvailable: true))
        XCTAssertEqual(visit.audiences, [.agents, .referrals, .people])
        XCTAssertEqual(visit.detail, .day)
        XCTAssertFalse(options([:], people: false).audiences.contains(.people))
    }

    /// Unticked checkboxes send nothing, so on a submission absent means off.
    func testASubmissionReadsAbsentCheckboxesAsOff() {
        let form = options(["v": "1", "range": "custom", "from": "2026-09-01", "to": "2026-09-10",
                            "detail": "week", "people": "1", "by_path": "1", "by_agent": "1", "page_reads": "1"])
        XCTAssertTrue(form.isCustom)
        XCTAssertEqual(form.detail, .week)
        XCTAssertEqual(form.audiences, [.people])
        XCTAssertEqual(form.dimensions, [.path, .agent])
        XCTAssertTrue(form.pageReadsOnly)
        XCTAssertEqual(options(["v": "1"]).audiences, [])
    }

    func testUnknownValuesFallBack() {
        let form = options(["v": "1", "range": "5y", "detail": "hourly"])
        XCTAssertEqual(form.range, .week)
        XCTAssertFalse(form.isCustom)
        XCTAssertEqual(form.detail, .day)
    }

    func testDayParsing() {
        XCTAssertEqual(BotExportDay("2026-09-26")?.string, "2026-09-26")
        XCTAssertEqual(BotExportDay(" 2024-02-29 ")?.string, "2024-02-29")
        for bad in ["2026-02-30", "2025-02-29", "2026-9-26", "26-09-26", "2026/09/26", "2026-13-01", "", "abcd-ef-gh", "٢٠٢٦-09-26"] {
            XCTAssertNil(BotExportDay(bad), bad)
        }
    }

    // MARK: Validation

    func testRefusals() {
        func error(_ form: BotExportOptions, people: Bool = true) -> BotExportError? {
            do {
                _ = try form.plan(now: now, timeZone: utc, siteKey: nil, peopleAvailable: people)
                return nil
            } catch {
                return error as? BotExportError
            }
        }
        XCTAssertEqual(error(options(["v": "1"])), .noAudience)
        XCTAssertEqual(error(submitted(["people": "1"]), people: false), .peopleUnavailable)
        XCTAssertEqual(error(submitted(["range": "custom", "from": "2026-09-01"])), .missingDates)
        XCTAssertEqual(error(submitted(["range": "custom", "from": "2026-09-01", "to": "yesterday"])), .invalidDate("yesterday"))
        XCTAssertEqual(error(submitted(["range": "custom", "from": "2026-09-10", "to": "2026-09-01"])), .reversedDates)
        XCTAssertEqual(error(submitted(["range": "custom", "from": "2000-01-01", "to": "2026-09-01"])), .rangeTooLong)
        XCTAssertNil(error(submitted(["range": "custom", "from": "2026-09-01", "to": "2026-09-01"])))
        // Dates typed while a preset is picked are ignored.
        XCTAssertNil(error(submitted(["range": "7d", "from": "junk"])))
    }

    func testMessagesAreSentences() {
        for error: BotExportError in [.missingDates, .invalidDate("x"), .reversedDates, .rangeTooLong, .noAudience, .peopleUnavailable] {
            XCTAssertTrue(error.message.hasSuffix("."), error.message)
            XCTAssertFalse(error.message.contains("\u{2014}"), "no em dashes")
        }
    }

    // MARK: Periods

    /// A custom period is whole local days, the last one included. The day
    /// Brussels falls back is 25 hours long and is covered exactly.
    func testCustomDaysAreLocalAndWhole() throws {
        let plan = try submitted(["range": "custom", "from": "2026-10-25", "to": "2026-10-25"])
            .plan(now: now, timeZone: brussels, siteKey: nil, peopleAvailable: true)
        XCTAssertEqual(plan.start, Date(timeIntervalSince1970: 1_792_879_200)) // 2026-10-25 00:00 CEST
        XCTAssertEqual(plan.end.timeIntervalSince(plan.start), 25 * 3_600)
        XCTAssertEqual(plan.periods.map(\.label), ["2026-10-25"])
    }

    /// A preset ends now, so per-day periods of the last 24 hours are two
    /// partial days, each carrying its exact bounds.
    func testPresetPeriodsAreClippedToTheWindow() throws {
        let plan = try submitted(["range": "24h"]).plan(now: now, timeZone: utc, siteKey: nil, peopleAvailable: true)
        XCTAssertEqual(plan.periods.map(\.label), ["2026-09-25", "2026-09-26"])
        XCTAssertEqual(plan.periods.first?.start, Date(timeIntervalSince1970: 1_790_341_200)) // 25 Sep 13:00
        XCTAssertEqual(plan.periods.last?.end, now)
        XCTAssertEqual(plan.periods[0].end, plan.periods[1].start)
    }

    func testWeeksAreISO() throws {
        let plan = try submitted(["range": "custom", "from": "2026-12-27", "to": "2027-01-05", "detail": "week"])
            .plan(now: now, timeZone: utc, siteKey: nil, peopleAvailable: true)
        // 27 Dec 2026 is a Sunday; 2026 has 53 ISO weeks.
        XCTAssertEqual(plan.periods.map(\.label), ["2026-W52", "2026-W53", "2027-W01"])
        let formatter = BotExportCSV.timestampFormatter(in: utc)
        XCTAssertEqual(plan.periods.map { formatter.string(from: $0.start) },
                       ["2026-12-27T00:00:00+00:00", "2026-12-28T00:00:00+00:00", "2027-01-04T00:00:00+00:00"])
    }

    func testMonthsAndTotals() throws {
        let months = try submitted(["range": "custom", "from": "2026-01-15", "to": "2026-03-10", "detail": "month"])
            .plan(now: now, timeZone: brussels, siteKey: nil, peopleAvailable: true)
        XCTAssertEqual(months.periods.map(\.label), ["2026-01", "2026-02", "2026-03"])
        XCTAssertEqual(months.periods.first?.start, months.start)
        XCTAssertEqual(months.periods.last?.end, months.end)

        let total = try submitted(["range": "90d", "detail": "total"])
            .plan(now: now, timeZone: brussels, siteKey: nil, peopleAvailable: true)
        XCTAssertEqual(total.periods, [.init(label: "total", start: total.start, end: now)])

        let raw = try submitted(["range": "7d", "detail": "raw", "by_path": "1"])
            .plan(now: now, timeZone: utc, siteKey: nil, peopleAvailable: true)
        XCTAssertTrue(raw.periods.isEmpty)
        XCTAssertTrue(raw.dimensions.isEmpty, "raw rows carry every column already")
    }

    /// Consecutive periods tile the range with no gap or overlap, in every
    /// zone, over DST changes.
    func testPeriodsTileTheRange() throws {
        for zone in ["Europe/Brussels", "America/Santiago", "Australia/Lord_Howe", "Asia/Kolkata"] {
            let tz = TimeZone(identifier: zone)!
            for detail in ["day", "week", "month"] {
                let plan = try submitted(["range": "custom", "from": "2026-01-01", "to": "2026-12-31", "detail": detail])
                    .plan(now: now, timeZone: tz, siteKey: nil, peopleAvailable: true)
                XCTAssertEqual(plan.periods.first?.start, plan.start, "\(zone) \(detail)")
                XCTAssertEqual(plan.periods.last?.end, plan.end, "\(zone) \(detail)")
                for (a, b) in zip(plan.periods, plan.periods.dropFirst()) {
                    XCTAssertEqual(a.end, b.start, "\(zone) \(detail) \(a.label)")
                }
                XCTAssertEqual(Set(plan.periods.map(\.label)).count, plan.periods.count, "\(zone) \(detail)")
                if detail == "day" { XCTAssertEqual(plan.periods.count, 365, zone) }
                if detail == "month" { XCTAssertEqual(plan.periods.count, 12, zone) }
            }
        }
    }

    func testFileName() throws {
        let plan = try submitted(["range": "custom", "from": "2026-09-01", "to": "2026-09-26", "detail": "week"])
            .plan(now: now, timeZone: brussels, siteKey: "blog\"; x=/../é", peopleAvailable: true)
        XCTAssertEqual(plan.fileName, "ai-traffic_blog---x------_2026-09-01_2026-09-26_week.csv")
        let all = try submitted([:]).plan(now: now, timeZone: utc, siteKey: nil, peopleAvailable: true)
        XCTAssertTrue(all.fileName.hasPrefix("ai-traffic_all-sites_"))
    }
}

final class ExportCSVTests: XCTestCase {

    func testFields() {
        XCTAssertEqual(BotExportCSV.field(nil), "")
        XCTAssertEqual(BotExportCSV.field("/blog/post"), "/blog/post")
        XCTAssertEqual(BotExportCSV.field("a,b"), "\"a,b\"")
        XCTAssertEqual(BotExportCSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(BotExportCSV.field("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(BotExportCSV.field(" padded"), "\" padded\"")
    }

    /// A value a spreadsheet would run as a formula is turned into text.
    func testFormulaInjectionIsNeutralised() {
        XCTAssertEqual(BotExportCSV.field("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(BotExportCSV.field("+1"), "'+1")
        XCTAssertEqual(BotExportCSV.field("-1"), "'-1")
        XCTAssertEqual(BotExportCSV.field("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(BotExportCSV.field("2026-09-26T14:00:00+02:00"), "2026-09-26T14:00:00+02:00")
    }

    func testLinesEndInCRLF() {
        XCTAssertEqual(BotExportCSV.line(["a", nil, "3"]), "a,,3\r\n")
    }

    func testTimestampsCarryTheOffset() {
        let instant = Date(timeIntervalSince1970: 1_790_425_200)
        XCTAssertEqual(BotExportCSV.timestampFormatter(in: TimeZone(identifier: "Europe/Brussels")!).string(from: instant),
                       "2026-09-26T14:20:00+02:00")
        XCTAssertEqual(BotExportCSV.timestampFormatter(in: TimeZone(secondsFromGMT: 0)!).string(from: instant),
                       "2026-09-26T12:20:00+00:00")
    }

    func testGroupedFile() throws {
        let plan = try BotExportOptions(
            range: .day, isCustom: true, from: "2026-09-01", to: "2026-09-02", detail: .day,
            audiences: [.agents, .people], pageReadsOnly: false, dimensions: [.agent, .path]
        ).plan(now: Date(), timeZone: TimeZone(secondsFromGMT: 0)!, siteKey: nil, peopleAvailable: true)
        var agent = BotExportQueries.GroupedRow(period: 0, audience: .agents, count: 3)
        agent.path = "/a,b"
        agent.agent = "GPTBot"
        agent.agentOperator = "OpenAI"
        var people = BotExportQueries.GroupedRow(period: 1, audience: .people, count: 12)
        people.path = "/"
        let csv = BotDashboardController.groupedCSV([agent, people], plan: plan)
        XCTAssertEqual(csv, """
            period,period_start,period_end,audience,path,agent,operator,count\r
            2026-09-01,2026-09-01T00:00:00+00:00,2026-09-02T00:00:00+00:00,ai_agent,"/a,b",GPTBot,OpenAI,3\r
            2026-09-02,2026-09-02T00:00:00+00:00,2026-09-03T00:00:00+00:00,people,/,,,12\r

            """)
    }
}

final class ExportPageTests: XCTestCase {

    private let sites = [BotDashboardSite(key: "a", name: "Alpha"), BotDashboardSite(key: "b", name: "Beta")]

    func testTheFormSubmitsToTheCSVByGet() {
        let html = ExportPage.render(options: .initial(range: .month, peopleAvailable: true), sites: sites,
                                     selectedSite: sites[1], generatedAt: Date(), showsPageViews: true)
        XCTAssertTrue(html.contains("action=\"/admin/ai-bots/export/csv\""))
        XCTAssertTrue(html.contains("method=\"get\""))
        XCTAssertTrue(html.contains("name=\"site\" value=\"b\""))
        XCTAssertTrue(html.contains("name=\"range\" value=\"30d\" checked"))
        XCTAssertTrue(html.contains("name=\"people\""))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.lowercased().contains("ip_hash"))
    }

    func testPeopleAreOfferedOnlyWhenCounted() {
        let html = ExportPage.render(options: .initial(range: .week, peopleAvailable: false), sites: [],
                                     selectedSite: nil, generatedAt: Date(), showsPageViews: false)
        XCTAssertFalse(html.contains("name=\"people\""))
        XCTAssertFalse(html.contains("/pages/"))
    }

    /// A refused form comes back filled in as sent, with the reason.
    func testARefusalKeepsTheForm() {
        var form = BotExportOptions.initial(range: .week, peopleAvailable: true)
        form.isCustom = true
        form.from = "2026-09-10"
        form.to = "\"><b>"
        form.detail = .month
        let html = ExportPage.render(options: form, sites: [], selectedSite: nil, generatedAt: Date(),
                                     error: .invalidDate("\"><b>"))
        XCTAssertTrue(html.contains("role=\"alert\""))
        XCTAssertFalse(html.contains("\"><b>"), "typed input must be escaped")
        XCTAssertTrue(html.contains("value=\"custom\" checked id=\"range-custom\""))
        XCTAssertTrue(html.contains("name=\"detail\" value=\"month\" checked"))
        XCTAssertTrue(html.contains("value=\"2026-09-10\""))
    }

    func testEveryTabLinksToExport() {
        let agents = DashboardPage.render(data: BotDashboardData(), range: .week, sites: sites, selectedSite: nil,
                                          generatedAt: Date())
        XCTAssertTrue(agents.contains("href=\"/admin/ai-bots/export/?site=all&amp;range=7d\""))
        let pages = PageViewsPage.render(data: PageViewData(), range: .day, sites: sites, selectedSite: sites[0],
                                         generatedAt: Date())
        XCTAssertTrue(pages.contains("href=\"/admin/ai-bots/export/?site=a&amp;range=24h\""))
    }
}
