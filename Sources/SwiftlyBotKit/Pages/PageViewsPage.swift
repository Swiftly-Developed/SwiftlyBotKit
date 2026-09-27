import Foundation
import Elementary

/// The "Page views" tab, at `<dashboard path>/pages/`, shown when
/// ``BotKitConfiguration/PageViews`` is on.
///
/// Same chrome as ``DashboardPage`` (header, tabs, site switcher, range
/// pills) plus an audience filter: people, AI agents, or both. The same rules
/// apply: no script but ``ViewerTimeZone``, nothing loaded from elsewhere, every stored string
/// escaped.
///
/// People are drawn in the first palette slot and AI agents in the second;
/// in the combined view they stack in that order, which keeps touching
/// segments on adjacent slots as the palette requires.
enum PageViewsPage {

    static let peopleColor = "var(--series-1)"
    static let agentsColor = "var(--series-2)"

    static func render(
        data: PageViewData,
        range: BotDateRange,
        sites: [BotDashboardSite],
        selectedSite: BotDashboardSite?,
        generatedAt: Date,
        options: BotKitConfiguration.Dashboard = .default,
        audience: PageViewAudience = .people,
        colorBy: PageViewColorBy = .none,
        colorOptions: [PageViewColorBy] = [],
        breakdown: PageViewBreakdown? = nil,
        extras: Extras = Extras()
    ) -> String {
        let siteName: String? = sites.count > 1 ? (selectedSite?.name ?? "All sites") : nil
        let base = options.basePath
        let timeZone = options.timeZone.foundationTimeZone
        let page = html(.lang("en")) {
            head {
                meta(.charset(.utf8))
                meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
                meta(.name("robots"), .content("noindex, nofollow"))
                Elementary.title {
                    [DashboardSection.pageViews.label, siteName, options.title].compactMap { $0 }.joined(separator: " \u{00B7} ")
                }
                style { HTMLRaw(DashboardTheme.css) }
                ViewerTimeZone.element(options, reloads: true)
            }
            body {
                main {
                    DashboardPage.header(title: options.title, base: base, range: range, siteName: siteName,
                                         generatedAt: generatedAt, timeZone: timeZone)
                    DashboardPage.filters(base: base, section: .pageViews, sections: DashboardSection.available(pageViews: true), range: range,
                                          ranges: options.offeredDateRanges, sites: sites, selectedSite: selectedSite,
                                          audience: audience, colorBy: colorBy)
                    if data.total(for: audience) == 0 {
                        emptyState(range: range, audience: audience)
                    } else {
                        if let comparison = extras.comparison {
                            tileGroups(comparison, data: data, range: range, audience: audience,
                                       timeOnPage: extras.timeOnPage)
                        } else {
                            tiles(data, range: range, audience: audience)
                        }
                        chartCard(data, range: range, timeZone: timeZone, audience: audience,
                                  colorMenu: audience == .people && colorOptions.count > 1
                                      ? ColorMenu(current: colorBy, options: colorOptions, base: base,
                                                  siteKey: selectedSite?.key ?? "all", range: range)
                                      : nil,
                                  breakdown: breakdown)
                        pagesCard(data.topPages, audience: audience, breakdown: breakdown,
                                  timeOnPage: extras.timeOnPage, smallCellThreshold: extras.smallCellThreshold)
                        if audience == .people {
                            insightCards(extras)
                        }
                    }
                    footnote(audience: audience)
                }
            }
        }
        return "<!DOCTYPE html>" + page.render()
    }

    /// What the tab shows beyond the chart and the page list, each `nil`
    /// when it is not loaded (the feature is off, or the audience does not
    /// use it).
    struct Extras: Sendable {
        /// The tiles' figures and the previous period's. Without it the tab
        /// shows the single row of tiles for the chosen audience.
        var comparison: PageViewComparison?
        var timeOnPage: TimeOnPageData?
        var referrers: PageViewRanking?
        var countries: PageViewRanking?
        var landingPages: PageViewRanking?
        /// Page averages from fewer readings than this are not shown.
        var smallCellThreshold = 5

        init(
            comparison: PageViewComparison? = nil,
            timeOnPage: TimeOnPageData? = nil,
            referrers: PageViewRanking? = nil,
            countries: PageViewRanking? = nil,
            landingPages: PageViewRanking? = nil,
            smallCellThreshold: Int = 5
        ) {
            self.comparison = comparison
            self.timeOnPage = timeOnPage
            self.referrers = referrers
            self.countries = countries
            self.landingPages = landingPages
            self.smallCellThreshold = smallCellThreshold
        }
    }

    // MARK: - Tiles

    /// Two rows of tiles, people and AI agents, whichever audience is
    /// chosen, the chosen one first. Each count says how it moved against
    /// the previous period of the same length.
    @HTMLBuilder
    static func tileGroups(
        _ comparison: PageViewComparison,
        data: PageViewData,
        range: BotDateRange,
        audience: PageViewAudience,
        timeOnPage: TimeOnPageData?
    ) -> some HTML {
        if audience == .agents {
            agentTiles(comparison, range: range, isFirst: true)
            peopleTiles(comparison, data: data, range: range, timeOnPage: timeOnPage, isFirst: false)
        } else {
            peopleTiles(comparison, data: data, range: range, timeOnPage: timeOnPage, isFirst: true)
            agentTiles(comparison, range: range, isFirst: false)
        }
    }

    private static func peopleTiles(
        _ comparison: PageViewComparison,
        data: PageViewData,
        range: BotDateRange,
        timeOnPage: TimeOnPageData?,
        isFirst: Bool
    ) -> some HTML {
        let now = comparison.current
        let before = comparison.previous
        let comparable = comparison.peopleComparable
        let period = previousLabel(range)
        let unit = range.isHourly ? "hour" : "day"
        return section(.class("tile-group")) {
            h2(.class("group-label")) { "People" }
            div(.class("tiles")) {
                DashboardPage.tile(
                    label: "Page views",
                    value: BotCharts.compact(now.peopleViews),
                    note: "by people, \(range.label.lowercased())",
                    isHero: isFirst,
                    delta: comparable ? .init(now.peopleViews, was: before.peopleViews, period: period, tone: .positive) : nil
                )
                DashboardPage.tile(
                    label: "Page views per \(unit)",
                    value: average(views: now.peopleViews, buckets: data.peopleBucketCount),
                    note: data.peopleCountedSince != nil ? "average since counting began" : "average over the window",
                    delta: comparable
                        ? .init(Double(now.peopleViews) / Double(max(1, data.peopleBucketCount)),
                                was: Double(before.peopleViews) / Double(range.bucketCount),
                                period: period, tone: .positive)
                        : nil
                )
                DashboardPage.tile(
                    label: "Unique pages",
                    value: BotCharts.compact(now.peoplePages),
                    note: "distinct pages people read",
                    delta: comparable ? .init(now.peoplePages, was: before.peoplePages, period: period, tone: .positive) : nil
                )
                if let timeOnPage {
                    DashboardPage.tile(
                        label: "Time on page",
                        value: timeOnPage.total.average.map(duration) ?? "\u{2013}",
                        note: timeOnPageNote(timeOnPage)
                    )
                }
                DashboardPage.tile(
                    label: "From AI assistants",
                    value: BotCharts.compact(now.referrals),
                    note: "people who followed a link in an AI answer",
                    delta: comparison.agentsComparable
                        ? .init(now.referrals, was: before.referrals, period: period, tone: .positive) : nil
                )
            }
        }
    }

    private static func agentTiles(_ comparison: PageViewComparison, range: BotDateRange, isFirst: Bool) -> some HTML {
        let now = comparison.current
        let before = comparison.previous
        let comparable = comparison.agentsComparable
        let period = previousLabel(range)
        let unit = range.isHourly ? "hour" : "day"
        return section(.class("tile-group")) {
            h2(.class("group-label")) { "AI agents" }
            div(.class("tiles")) {
                DashboardPage.tile(
                    label: "AI agent reads",
                    value: BotCharts.compact(now.agentReads),
                    note: agentRatio(views: now.peopleViews, agents: now.agentReads),
                    isHero: isFirst,
                    delta: comparable ? .init(now.agentReads, was: before.agentReads, period: period, tone: .neutral) : nil
                )
                DashboardPage.tile(
                    label: "Unique visitors",
                    value: BotCharts.compact(now.agentAddresses),
                    note: "distinct IP addresses; one crawler can use many",
                    delta: comparable ? .init(now.agentAddresses, was: before.agentAddresses, period: period, tone: .neutral) : nil
                )
                DashboardPage.tile(
                    label: "Agents",
                    value: BotCharts.compact(now.agents),
                    note: "distinct AI agents, such as GPTBot",
                    delta: comparable ? .init(now.agents, was: before.agents, period: period, tone: .neutral) : nil
                )
                DashboardPage.tile(
                    label: "Reads per \(unit)",
                    value: average(views: now.agentReads, buckets: range.bucketCount),
                    note: "average over the window",
                    delta: comparable ? .init(now.agentReads, was: before.agentReads, period: period, tone: .neutral) : nil
                )
                DashboardPage.tile(
                    label: "Unique pages",
                    value: BotCharts.compact(now.agentPages),
                    note: "distinct pages AI agents read",
                    delta: comparable ? .init(now.agentPages, was: before.agentPages, period: period, tone: .neutral) : nil
                )
            }
        }
    }

    /// "previous 24 hours", "previous 7 days".
    static func previousLabel(_ range: BotDateRange) -> String {
        "previous " + range.label.dropFirst("Last ".count).lowercased()
    }

    /// "median 30 s to 1 min, 34% under 10 s".
    static func timeOnPageNote(_ data: TimeOnPageData) -> String {
        guard let median = data.medianBand, let glance = data.glanceShare else { return "no readings yet" }
        var note = "median \(median.label.lowercased()), \(BotCharts.share(Int((glance * 1000).rounded()), of: 1000)) under 10 s"
        if data.isDailyFallback { note += "; yesterday and today" }
        return note
    }

    /// "45 s", "2 min 5 s", "12 min".
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60, rest = seconds % 60
        if minutes >= 10 || rest == 0 { return "\(minutes) min" }
        return "\(minutes) min \(rest) s"
    }

    private static func tiles(_ data: PageViewData, range: BotDateRange, audience: PageViewAudience) -> some HTML {
        let total = data.total(for: audience)
        // People were only counted from `peopleCountedSince`; averaging them
        // over the whole window would read as a slump that never happened.
        let buckets = audience == .people ? data.peopleBucketCount : range.bucketCount
        return div(.class("tiles")) {
            DashboardPage.tile(
                label: heroLabel(audience),
                value: BotCharts.compact(total),
                note: heroNote(audience, range: range),
                isHero: true
            )
            DashboardPage.tile(
                label: "Pages read",
                value: BotCharts.compact(data.distinctPages),
                note: "distinct paths with a read"
            )
            DashboardPage.tile(
                label: range.isHourly ? "Per hour" : "Per day",
                value: average(views: total, buckets: buckets),
                note: audience == .people && data.peopleCountedSince != nil
                    ? "average since counting began" : "average over the window"
            )
            switch audience {
            case .people:
                DashboardPage.tile(label: "AI agent reads", value: BotCharts.compact(data.agents),
                                   note: agentRatio(views: data.people, agents: data.agents))
            case .agents:
                DashboardPage.tile(label: "Page views by people", value: BotCharts.compact(data.people),
                                   note: peopleRatio(agents: data.agents, people: data.people))
            case .combined:
                DashboardPage.tile(label: "Read by people", value: share(data.people, of: total),
                                   note: "\(BotCharts.grouped(data.people)) people, \(BotCharts.grouped(data.agents)) AI agent")
            }
        }
    }

    private static func heroLabel(_ audience: PageViewAudience) -> String {
        switch audience {
        case .people: return "Page views"
        case .agents: return "AI agent reads"
        case .combined: return "Page reads"
        }
    }

    private static func heroNote(_ audience: PageViewAudience, range: BotDateRange) -> String {
        switch audience {
        case .people: return "by people, \(range.label.lowercased())"
        case .agents: return "pages AI agents fetched, \(range.label.lowercased())"
        case .combined: return "people and AI agents, \(range.label.lowercased())"
        }
    }

    /// "1 for every 4 page views", the scale of machine readership against
    /// human readership in the same window.
    static func agentRatio(views: Int, agents: Int) -> String {
        guard agents > 0 else { return "none in this window" }
        guard views > 0 else { return "and no page views" }
        if agents >= views {
            let ratio = Double(agents) / Double(views)
            return ratio < 1.05 ? "about one per page view" : "\(oneDecimal(ratio)) per page view"
        }
        let ratio = Double(views) / Double(agents)
        return "1 for every \(oneDecimal(ratio)) page views"
    }

    /// The same comparison seen from the AI agent side.
    static func peopleRatio(agents: Int, people: Int) -> String {
        guard people > 0 else { return "none in this window" }
        guard agents > 0 else { return "and no AI agent reads" }
        if people >= agents {
            let ratio = Double(people) / Double(agents)
            return ratio < 1.05 ? "about one per AI agent read" : "\(oneDecimal(ratio)) per AI agent read"
        }
        let ratio = Double(agents) / Double(people)
        return "1 for every \(oneDecimal(ratio)) AI agent reads"
    }

    /// "5%", never "0%" or "100%" while the other side has any reads.
    static func share(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "\u{2013}" }
        let percent = Double(part) / Double(total) * 100
        if part > 0, percent < 1 { return "<1%" }
        if part < total, percent > 99 { return ">99%" }
        return "\(Int(percent.rounded()))%"
    }

    /// Reads per bucket. One decimal below ten, so a quiet site reads "0.4"
    /// rather than a flat "0".
    static func average(views: Int, buckets: Int) -> String {
        let value = Double(views) / Double(max(buckets, 1))
        return value < 9.95 ? oneDecimal(value) : BotCharts.compact(Int(value.rounded()))
    }

    private static func oneDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    // MARK: - Chart

    /// What the "Color by" menu needs to build its links.
    struct ColorMenu {
        let current: PageViewColorBy
        let options: [PageViewColorBy]
        let base: String
        let siteKey: String
        let range: BotDateRange

        func href(_ option: PageViewColorBy) -> String {
            DashboardPage.dashboardURL(base: base, section: .pageViews, siteKey: siteKey, range: range,
                                       audience: .people, colorBy: option)
        }
    }

    private static func chartCard(
        _ data: PageViewData,
        range: BotDateRange,
        timeZone: TimeZone,
        audience: PageViewAudience,
        colorMenu: ColorMenu? = nil,
        breakdown: PageViewBreakdown? = nil
    ) -> some HTML {
        div(.class("card")) {
            div(.class("card-head")) {
                h2 { "\(heroLabel(audience)) over time" }
                if let colorMenu {
                    colorByMenu(colorMenu)
                }
            }
            p(.class("hint")) { chartHint(data, range: range, timeZone: timeZone, audience: audience, breakdown: breakdown) }
            if let breakdown {
                breakdownChart(breakdown, range: range, timeZone: timeZone)
            } else {
                div(.class("chart")) {
                    HTMLRaw(BotCharts.columns(
                        data.series.map { point in
                            var segments: [BotCharts.ColumnSegment] = []
                            if audience.includesPeople {
                                segments.append(.init(label: "People", color: peopleColor, count: point.people))
                            }
                            if audience.includesAgents {
                                segments.append(.init(label: "AI agents", color: agentsColor, count: point.agents))
                            }
                            return (point.bucket, segments)
                        },
                        range: range,
                        timeZone: timeZone,
                        ariaLabel: "\(heroLabel(audience)) per \(range.isHourly ? "hour" : "day")"
                    ))
                }
                if audience == .combined {
                    div(.class("legend")) {
                        legendEntry("People", color: peopleColor, count: data.people)
                        legendEntry("AI agents", color: agentsColor, count: data.agents)
                    }
                }
            }
        }
    }

    static func chartHint(
        _ data: PageViewData,
        range: BotDateRange,
        timeZone: TimeZone,
        audience: PageViewAudience,
        breakdown: PageViewBreakdown?
    ) -> String {
        let daily = breakdown?.isDailyFallback == true || !range.isHourly
        let zone = breakdown?.dayTimeZone ?? timeZone
        var hint = "\(daily ? "Daily" : "Hourly") buckets, \(zone.identifier)."
        if let dayZone = breakdown?.dayTimeZone, dayZone.identifier != timeZone.identifier {
            hint += " \(breakdown!.colorBy.label) is counted per \(dayZone.identifier) day, so this chart uses that zone."
        }
        if let breakdown {
            hint += " Coloured by \(breakdown.colorBy.label.lowercased())."
            if breakdown.isDailyFallback {
                hint += " \(breakdown.colorBy.label) is stored per day, so this shows yesterday and today."
            }
            if let threshold = breakdown.smallCellThreshold {
                hint += " Other holds values with fewer than \(threshold) views and views counted before this breakdown was switched on\(breakdown.colorBy == .dimension(.country) ? " or without a country table" : "")."
            }
        } else {
            hint += countingNote(data, audience: audience, timeZone: timeZone)
        }
        return hint
    }

    /// A `<details>` menu of links, like the site switcher, so it works
    /// with the dashboard's no-script CSP.
    private static func colorByMenu(_ menu: ColorMenu) -> some HTML {
        details(.class("colorby")) {
            summary(.custom(name: "aria-label", value: "Color by: \(menu.current.label)")) {
                "Color by "
                b { menu.current.label }
                span(.class("chev"), .custom(name: "aria-hidden", value: "true")) { "\u{25BE}" }
            }
            div(.class("menu")) {
                for option in menu.options {
                    if option == .dimension(PageViewDimension.allCases[0]) {
                        div(.class("group")) { "Breakdowns, per day" }
                    }
                    if option == menu.current {
                        a(.href(menu.href(option)), .class("on"), .custom(name: "aria-current", value: "true")) { option.label }
                    } else {
                        a(.href(menu.href(option))) { option.label }
                    }
                }
            }
        }
    }

    /// The stacked chart and, under it, every value's total for the period
    /// in its colour.
    @HTMLBuilder
    private static func breakdownChart(_ breakdown: PageViewBreakdown, range: BotDateRange, timeZone: TimeZone) -> some HTML {
        let masks = breakdown.smallCellThreshold != nil
        // Largest value at the baseline, Other on top.
        let stacks = breakdown.buckets.indices.map { bucket in
            (breakdown.buckets[bucket], breakdown.series.indices.map { index -> BotCharts.ColumnSegment in
                let count = breakdown.series[index].counts[bucket]
                let label = breakdown.display(count)
                return .init(label: breakdown.series[index].label, color: breakdown.color(at: index), count: count,
                             countLabel: masks && label.hasPrefix("<") ? label : nil,
                             isRemainder: breakdown.series[index].kind != .value)
            })
        }
        // The labels and popovers follow the buckets drawn, not the range:
        // days even on the 24-hour range when the breakdown is daily.
        let axisRange: BotDateRange = breakdown.isDailyFallback ? .week : range
        div(.class("chart")) {
            HTMLRaw(BotCharts.columns(
                stacks,
                range: axisRange,
                timeZone: breakdown.dayTimeZone ?? timeZone,
                ariaLabel: "Page views per \(axisRange.isHourly ? "hour" : "day"), coloured by \(breakdown.colorBy.label.lowercased())",
                popoverDescending: true
            ))
        }
        if breakdown.series.isEmpty {
            p(.class("hint")) { "Nothing recorded for this breakdown in the period." }
        } else {
            div(.class("legend totals"), .custom(name: "aria-label", value: "Totals for the period")) {
                for index in breakdown.series.indices {
                    let series = breakdown.series[index]
                    div {
                        i(.custom(name: "style", value: "background:\(breakdown.color(at: index))")) {}
                        span { series.label }
                        b { breakdown.display(series.total) }
                        if !(masks && breakdown.display(series.total).hasPrefix("<")) {
                            em { BotCharts.share(series.total, of: breakdown.total) }
                        }
                    }
                }
            }
        }
    }

    private static func legendEntry(_ name: String, color: String, count: Int) -> some HTML {
        div {
            i(.custom(name: "style", value: "background:\(color)")) {}
            span { name }
            b { BotCharts.grouped(count) }
        }
    }

    /// " People are counted from 26 Sep 11:00." when that falls in the window.
    private static func countingNote(_ data: PageViewData, audience: PageViewAudience, timeZone: TimeZone) -> String {
        guard audience.includesPeople, let since = data.peopleCountedSince else { return "" }
        return " People are counted from \(DashboardPage.timestamp(since, timeZone: timeZone)); there is no page view data before that."
    }

    // MARK: - Pages

    private static func pagesCard(
        _ pages: [PageViewData.PageRow],
        audience: PageViewAudience,
        breakdown: PageViewBreakdown? = nil,
        timeOnPage: TimeOnPageData? = nil,
        smallCellThreshold: Int = 5
    ) -> some HTML {
        div(.class("card")) {
            h2 { "Most-read pages" }
            p(.class("hint")) {
                switch audience {
                case .people:
                    if let breakdown {
                        "What people read, each page split by \(breakdown.colorBy.label.lowercased()) in the chart's colours\(breakdown.isDailyFallback ? " (the split is over yesterday and today)" : ""), with the AI agent reads beside it."
                    } else {
                        "What people read, with the AI agent reads of the same page beside it."
                    }
                    if timeOnPage != nil {
                        " Beside a page's name, its average time on page, when \(smallCellThreshold) or more readings make one."
                    }
                case .agents: "What AI agents fetched, with the page views by people beside it."
                case .combined: "Every read of each page, split into people and AI agents."
                }
            }
            HTMLRaw(BotCharts.barRows(pages.map { page in
                var row = audience == .people && breakdown != nil
                    ? row(for: page, breakdown: breakdown!)
                    : row(for: page, audience: audience)
                if audience.includesPeople, let sums = timeOnPage?.pages[page.path],
                   sums.readings >= smallCellThreshold, let average = sums.average {
                    row.meta = "\(duration(average)) on page"
                }
                return row
            }))
            if audience == .combined {
                div(.class("legend")) {
                    div {
                        i(.custom(name: "style", value: "background:\(peopleColor)")) {}
                        span { "People" }
                    }
                    div {
                        i(.custom(name: "style", value: "background:\(agentsColor)")) {}
                        span { "AI agents" }
                    }
                }
            }
        }
    }

    /// A page's bar split by the chart's breakdown, its popover listing
    /// each part.
    static func row(for page: PageViewData.PageRow, breakdown: PageViewBreakdown) -> BotCharts.BarRow {
        var row = row(for: page, audience: .people)
        guard let split = breakdown.pageSplits[page.path], split.contains(where: { $0 > 0 }) else { return row }
        let splitTotal = split.reduce(0, +)
        let order = split.indices.filter { split[$0] > 0 }
        // Largest first in the popover, catch-alls last; the bar keeps the
        // chart's order so colours sit in the same place on every row.
        let popoverOrder = order.sorted { (a: Int, b: Int) -> Bool in
            let aRest = breakdown.series[a].kind != .value
            let bRest = breakdown.series[b].kind != .value
            if aRest != bRest { return !aRest }
            if split[a] != split[b] { return split[a] > split[b] }
            return a < b
        }
        let details = popoverOrder.map { index -> BotCharts.PopoverLine in
            let label = breakdown.display(split[index])
            let masked = label.hasPrefix("<")
            return .init(label: breakdown.series[index].label, color: breakdown.color(at: index), count: split[index],
                         shareOf: masked ? nil : splitTotal, countLabel: masked ? label : nil)
        }
        row = BotCharts.BarRow(
            name: row.name, meta: row.meta, value: row.value, note: row.note, color: row.color, flag: row.flag,
            details: details,
            detailNote: breakdown.isDailyFallback
                ? "Split over yesterday and today"
                : (page.agents > 0 ? "\(BotCharts.grouped(page.agents)) AI agent reads" : nil)
        )
        row.parts = order.map { (color: breakdown.color(at: $0), count: split[$0]) }
        return row
    }

    static func row(for page: PageViewData.PageRow, audience: PageViewAudience) -> BotCharts.BarRow {
        // The popover always shows both audiences, with their share of the
        // page's reads, whichever one the bar is drawn for.
        let total = page.people + page.agents
        let details: [BotCharts.PopoverLine] = [
            .init(label: "People", color: peopleColor, count: page.people, shareOf: total),
            .init(label: "AI agents", color: agentsColor, count: page.agents, shareOf: total),
        ]
        let detailNote = "\(BotCharts.grouped(total)) reads in total"
        switch audience {
        case .people:
            return .init(name: page.path, meta: nil, value: page.people,
                         note: page.agents > 0 ? "\(BotCharts.grouped(page.agents)) AI agent" : nil,
                         color: peopleColor, flag: nil, details: details, detailNote: detailNote)
        case .agents:
            return .init(name: page.path, meta: nil, value: page.agents,
                         note: page.people > 0 ? "\(BotCharts.grouped(page.people)) people" : nil,
                         color: agentsColor, flag: nil, details: details, detailNote: detailNote)
        case .combined:
            // People are drawn at the baseline, inside the bar, in their own colour.
            return .init(name: page.path, meta: nil, value: page.people + page.agents,
                         note: "\(BotCharts.grouped(page.people)) people \u{00B7} \(BotCharts.grouped(page.agents)) AI",
                         color: agentsColor, flag: nil,
                         highlight: page.people, highlightColor: peopleColor,
                         details: details, detailNote: detailNote)
        }
    }

    // MARK: - Time on page, referrers, countries, landing pages

    @HTMLBuilder
    private static func insightCards(_ extras: Extras) -> some HTML {
        if let timeOnPage = extras.timeOnPage {
            timeOnPageCard(timeOnPage)
        }
        if extras.referrers != nil || extras.countries != nil {
            div(.class("cols")) {
                if let referrers = extras.referrers {
                    rankingCard(
                        title: "Top referrers",
                        hint: "The sites people came from. (direct) is a typed address, a bookmark or an app that sends no referrer; moves between your own pages are left out.",
                        ranking: referrers, threshold: extras.smallCellThreshold, label: { $0 }
                    )
                }
                if let countries = extras.countries {
                    rankingCard(
                        title: "Top countries",
                        hint: "Looked up from the IP address in a local table, which is then dropped.",
                        ranking: countries, threshold: extras.smallCellThreshold, label: countryName
                    )
                }
            }
        }
        if let landing = extras.landingPages {
            rankingCard(
                title: "Top landing pages",
                hint: "The first page people opened: views that did not come from another page on this site.",
                ranking: landing, threshold: nil, label: { $0 }
            )
        }
    }

    private static func timeOnPageCard(_ data: TimeOnPageData) -> some HTML {
        div(.class("card")) {
            h2 { "Time on page" }
            p(.class("hint")) {
                "How long a page stayed in view before the reader left or switched away, from \(BotCharts.grouped(data.total.readings)) readings\(data.isDailyFallback ? " over yesterday and today (stored per day)" : ""). Readings are capped at 30 minutes and come from a script, so readers who block scripts are not in them."
            }
            if data.total.readings == 0 {
                p(.class("hint")) { "No readings in this period yet." }
            } else {
                HTMLRaw(BotCharts.barRows(TimeOnPageBand.allCases.map { band in
                    let count = data.bands[band.rawValue]
                    return .init(name: band.label, meta: nil, value: count,
                                 note: BotCharts.share(count, of: data.total.readings),
                                 color: peopleColor, flag: nil)
                }))
            }
        }
    }

    private static func rankingCard(
        title: String,
        hint: String,
        ranking: PageViewRanking,
        threshold: Int?,
        label: @escaping (String) -> String
    ) -> some HTML {
        div(.class("card")) {
            h2 { title }
            p(.class("hint")) {
                hint
                if ranking.isDailyFallback { " Stored per day, so this covers yesterday and today." }
            }
            if ranking.total == 0 {
                p(.class("hint")) { "Nothing recorded in this period." }
            } else {
                HTMLRaw(BotCharts.barRows(ranking.rows.map { row in
                    .init(name: label(row.value), meta: nil, value: row.count,
                          note: BotCharts.share(row.count, of: ranking.total),
                          color: peopleColor, flag: nil)
                } + (ranking.folded > 0 ? [
                    .init(name: threshold.map { "Others (fewer than \($0) views each)" } ?? "Others",
                          meta: nil, value: ranking.folded,
                          note: BotCharts.share(ranking.folded, of: ranking.total),
                          color: "var(--cat-other)", flag: nil)
                ] : [])))
            }
        }
    }

    /// "Belgium" for `BE`, "Unknown" for `ZZ`, the code itself when the
    /// platform has no name for it.
    static func countryName(_ code: String) -> String {
        if code == "ZZ" { return "Unknown" }
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isUppercase }),
              let name = Locale(identifier: "en_US").localizedString(forRegionCode: code), !name.isEmpty
        else { return code }
        return name
    }

    // MARK: - Empty state and footnote

    private static func emptyState(range: BotDateRange, audience: PageViewAudience) -> some HTML {
        div(.class("card")) {
            div(.class("empty")) {
                switch audience {
                case .people:
                    p { "No page views in the \(range.label.lowercased())." }
                    p(.class("hint")) {
                        "Counting starts when page views are enabled and deployed. Counts are written every few seconds."
                    }
                case .agents:
                    p { "No AI agent read a page in the \(range.label.lowercased())." }
                case .combined:
                    p { "No page reads by people or AI agents in the \(range.label.lowercased())." }
                }
            }
        }
    }

    private static func footnote(audience: PageViewAudience) -> some HTML {
        p(.class("sub")) {
            "People: counted without cookies and without storing anything about the visitor (no IP address, no user agent, no full referrer); each view adds one to a counter for its page and quarter-hour and, for the Color by breakdowns, to daily counters of coarse values such as the country or the referring site, and only successful HTML pages opened in a browser count. These are views, not visitors. Time on page, when on, comes from a script that reports one number of seconds per page with no identifier. AI agents: successful page requests by agents in the catalog, their unique visitors counted by keyed IP hash; robots.txt, sitemaps and errors are on the AI agents tab. Other bots appear in neither."
        }
    }
}
