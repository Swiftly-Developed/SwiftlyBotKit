import Foundation
import Elementary

/// The "Page views" tab, at `<dashboard path>/pages/`, shown when
/// ``BotKitConfiguration/PageViews`` is on.
///
/// Same chrome as ``DashboardPage`` (header, tabs, site switcher, range
/// pills) plus an audience filter: people, AI agents, or both. The same rules
/// apply: no script, nothing loaded from elsewhere, every stored string
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
        audience: PageViewAudience = .people
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
            }
            body {
                main {
                    DashboardPage.header(title: options.title, base: base, range: range, siteName: siteName,
                                         generatedAt: generatedAt, timeZone: timeZone)
                    DashboardPage.filters(base: base, section: .pageViews, sections: DashboardSection.available(pageViews: true), range: range,
                                          ranges: options.offeredDateRanges, sites: sites, selectedSite: selectedSite,
                                          audience: audience)
                    if data.total(for: audience) == 0 {
                        emptyState(range: range, audience: audience)
                    } else {
                        tiles(data, range: range, audience: audience)
                        chartCard(data, range: range, timeZone: timeZone, audience: audience)
                        pagesCard(data.topPages, audience: audience)
                    }
                    footnote(audience: audience)
                }
            }
        }
        return "<!DOCTYPE html>" + page.render()
    }

    // MARK: - Tiles

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

    private static func chartCard(
        _ data: PageViewData,
        range: BotDateRange,
        timeZone: TimeZone,
        audience: PageViewAudience
    ) -> some HTML {
        div(.class("card")) {
            h2 { "\(heroLabel(audience)) over time" }
            p(.class("hint")) {
                "\(range.isHourly ? "Hourly" : "Daily") buckets, \(timeZone.identifier).\(countingNote(data, audience: audience, timeZone: timeZone))"
            }
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

    private static func pagesCard(_ pages: [PageViewData.PageRow], audience: PageViewAudience) -> some HTML {
        div(.class("card")) {
            h2 { "Most-read pages" }
            p(.class("hint")) {
                switch audience {
                case .people: "What people read, with the AI agent reads of the same page beside it."
                case .agents: "What AI agents fetched, with the page views by people beside it."
                case .combined: "Every read of each page, split into people and AI agents."
                }
            }
            HTMLRaw(BotCharts.barRows(pages.map { row(for: $0, audience: audience) }))
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
            "People: counted without cookies and without storing anything about the visitor (no IP address, no user agent, no referrer); each view adds one to a counter for its page and quarter-hour, and only successful HTML pages opened in a browser count. These are views, not visitors. AI agents: successful page requests by agents in the catalog; robots.txt, sitemaps and errors are on the AI agents tab. Other bots appear in neither."
        }
    }
}
