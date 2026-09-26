import Foundation
import Elementary

/// Which tab of the dashboard a page is.
enum DashboardSection: Sendable, CaseIterable {
    /// AI agents and AI referrals, at the dashboard path itself.
    case agents
    /// Anonymous page view counts, at `<path>/pages/`.
    case pageViews
    /// The CSV export form, at `<path>/export/`.
    case export

    /// Appended to the dashboard's base path.
    var pathSuffix: String {
        switch self {
        case .agents: return "/"
        case .pageViews: return "/pages/"
        case .export: return "/export/"
        }
    }

    var label: String {
        switch self {
        case .agents: return "AI agents"
        case .pageViews: return "Page views"
        case .export: return "Export"
        }
    }

    /// The tabs an app shows: the page views tab only when page views are
    /// counted.
    static func available(pageViews: Bool) -> [DashboardSection] {
        allCases.filter { $0 != .pageViews || pageViews }
    }
}

/// The dashboard page, at `BotKitConfiguration.Dashboard.path`.
///
/// Self-contained on purpose: no Tailwind CDN, no shared site layout, no
/// JavaScript. It is an owner-facing page behind a password, so it should
/// render identically whether or not a CDN is reachable, and it must never pull
/// the public sites' consent or analytics chrome into an admin view.
enum DashboardPage {

    static func render(
        data: BotDashboardData,
        range: BotDateRange,
        sites: [BotDashboardSite],
        selectedSite: BotDashboardSite?,
        generatedAt: Date,
        options: BotKitConfiguration.Dashboard = .default,
        knownAgentCount: Int = AIAgentCatalog.all.count,
        showsPageViews: Bool = false
    ) -> String {
        // A single-site app has nothing to switch between, so it names no site.
        let siteName: String? = sites.count > 1 ? (selectedSite?.name ?? "All sites") : nil
        let base = options.basePath
        let page = html(.lang("en")) {
            head {
                meta(.charset(.utf8))
                meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
                meta(.name("robots"), .content("noindex, nofollow"))
                Elementary.title { [options.title, siteName].compactMap { $0 }.joined(separator: " \u{00B7} ") }
                style { HTMLRaw(DashboardTheme.css) }
            }
            body {
                main {
                    header(title: options.title, base: base, range: range, siteName: siteName,
                           generatedAt: generatedAt, timeZone: options.timeZone.foundationTimeZone)
                    filters(base: base, section: .agents, sections: DashboardSection.available(pageViews: showsPageViews), range: range,
                            ranges: options.offeredDateRanges, sites: sites, selectedSite: selectedSite)
                    if data.isEmpty {
                        emptyState(range: range)
                    } else {
                        tiles(data.totals)
                        timeSeriesCard(data: data, range: range, timeZone: options.timeZone.foundationTimeZone)
                        div(.class("cols")) {
                            agentsCard(data.topAgents)
                            pagesCard(data.topPages)
                        }
                        referralsCard(data.referrals)
                    }
                    footnote(knownAgentCount: knownAgentCount)
                }
            }
        }
        return "<!DOCTYPE html>" + page.render()
    }

    // MARK: - Header and filters

    static func header(
        title: String,
        base: String,
        range: BotDateRange?,
        siteName: String?,
        generatedAt: Date,
        timeZone: TimeZone
    ) -> some HTML {
        div(.class("top")) {
            div {
                h1 { title }
                p(.class("sub")) {
                    [siteName, range?.label, "generated \(timestamp(generatedAt, timeZone: timeZone))"]
                        .compactMap { $0 }
                        .joined(separator: " \u{00B7} ")
                }
            }
            form(.method(.post), .action("\(base)/logout")) {
                button(.type(.submit), .class("btn")) { "Sign out" }
            }
        }
    }

    static func filters(
        base: String,
        section: DashboardSection,
        sections: [DashboardSection],
        range: BotDateRange,
        ranges: [BotDateRange],
        sites: [BotDashboardSite],
        selectedSite: BotDashboardSite?,
        audience: PageViewAudience? = nil
    ) -> some HTML {
        div(.class("filters")) {
            if sections.count > 1 {
                tabs(base: base, section: section, sections: sections, range: range, selectedSite: selectedSite)
            }
            // A switcher with only "All sites" in it would be noise: a
            // single-site app gets the range pills alone.
            if sites.count > 1 {
                siteSwitcher(base: base, section: section, range: range, sites: sites,
                             selectedSite: selectedSite, audience: audience)
            }
            if let audience {
                nav(.class("pills"), .custom(name: "aria-label", value: "Whose reads")) {
                    for option in PageViewAudience.allCases {
                        let href = dashboardURL(base: base, section: section, siteKey: selectedSite?.key ?? "all",
                                                range: range, audience: option)
                        if option == audience {
                            a(.href(href), .class("pill on"), .custom(name: "aria-current", value: "true")) { option.label }
                        } else {
                            a(.href(href), .class("pill")) { option.label }
                        }
                    }
                }
            }
            // The export form has its own period choice, so it passes none.
            if !ranges.isEmpty {
                div(.class("pills")) {
                    for option in ranges {
                        a(
                            .href(dashboardURL(base: base, section: section, siteKey: selectedSite?.key ?? "all",
                                               range: option, audience: audience)),
                            .class(option == range ? "pill on" : "pill")
                        ) { option.shortLabel }
                    }
                }
            }
        }
    }

    /// Links between the dashboard's tabs, keeping the site and range.
    private static func tabs(
        base: String,
        section: DashboardSection,
        sections: [DashboardSection],
        range: BotDateRange,
        selectedSite: BotDashboardSite?
    ) -> some HTML {
        nav(.class("pills tabs"), .custom(name: "aria-label", value: "Dashboard sections")) {
            for option in sections {
                let href = dashboardURL(base: base, section: option, siteKey: selectedSite?.key ?? "all", range: range)
                if option == section {
                    a(.href(href), .class("pill on"), .custom(name: "aria-current", value: "page")) { option.label }
                } else {
                    a(.href(href), .class("pill")) { option.label }
                }
            }
        }
    }

    /// A `<details>` menu of plain links rather than a `<select>`, because a
    /// native option cannot carry an image and the logo is what makes the
    /// current site readable at a glance. Links keep it working with
    /// JavaScript off, and every one carries an explicit `site=`, so choosing
    /// "All sites" is not undone by the host default.
    private static func siteSwitcher(
        base: String,
        section: DashboardSection,
        range: BotDateRange,
        sites: [BotDashboardSite],
        selectedSite: BotDashboardSite?,
        audience: PageViewAudience?
    ) -> some HTML {
        details(.class("switcher")) {
            summary(.custom(name: "aria-label", value: "Site: \(selectedSite?.name ?? "All sites")")) {
                siteMark(selectedSite, sites: sites)
                span { selectedSite?.name ?? "All sites" }
                span(.class("chev"), .custom(name: "aria-hidden", value: "true")) { "\u{25BE}" }
            }
            div(.class("menu")) {
                switcherLink(nil, base: base, section: section, sites: sites, range: range, audience: audience,
                             isCurrent: selectedSite == nil)
                ForEach(sites) { site in
                    switcherLink(site, base: base, section: section, sites: sites, range: range, audience: audience,
                                 isCurrent: site == selectedSite)
                }
            }
        }
    }

    @HTMLBuilder
    private static func switcherLink(
        _ site: BotDashboardSite?,
        base: String,
        section: DashboardSection,
        sites: [BotDashboardSite],
        range: BotDateRange,
        audience: PageViewAudience?,
        isCurrent: Bool
    ) -> some HTML {
        let href = dashboardURL(base: base, section: section, siteKey: site?.key ?? "all", range: range, audience: audience)
        if isCurrent {
            a(.href(href), .class("on"), .custom(name: "aria-current", value: "page")) {
                siteMark(site, sites: sites)
                span { site?.name ?? "All sites" }
            }
        } else {
            a(.href(href)) {
                siteMark(site, sites: sites)
                span { site?.name ?? "All sites" }
            }
        }
    }

    /// The site's logo, or for the all-sites view a 2×2 of every logo.
    @HTMLBuilder
    private static func siteMark(_ site: BotDashboardSite?, sites: [BotDashboardSite]) -> some HTML {
        if let site {
            if let logo = site.logoPath {
                img(.src(logo), .alt(""), .class("logo"))
            }
        } else {
            span(.class("logo all"), .custom(name: "aria-hidden", value: "true")) {
                for logo in sites.compactMap(\.logoPath).prefix(4) {
                    img(.src(logo), .alt(""))
                }
            }
        }
    }

    /// `audience` is kept only on the page views tab, and only when it is not
    /// the default, so the common links stay short.
    static func dashboardURL(
        base: String,
        section: DashboardSection,
        siteKey: String,
        range: BotDateRange,
        audience: PageViewAudience? = nil
    ) -> String {
        let key = siteKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? siteKey
        var url = "\(base)\(section.pathSuffix)?site=\(key)&range=\(range.rawValue)"
        if section == .pageViews, let audience, audience != .people {
            url += "&audience=\(audience.rawValue)"
        }
        return url
    }

    // MARK: - Tiles

    private static func tiles(_ totals: BotDashboardData.Totals) -> some HTML {
        div(.class("tiles")) {
            tile(
                label: "AI agent visits",
                value: BotCharts.compact(totals.botVisits),
                note: "\(totals.distinctAgents) distinct agents",
                isHero: true
            )
            tile(
                label: "User-triggered",
                value: BotCharts.compact(totals.userTriggered),
                note: "Someone asked; the assistant read a page"
            )
            tile(
                label: "Verified",
                value: totals.verifiableShare.map(percentage) ?? "\u{2013}",
                note: "of the visits we can check by IP"
            )
            tile(
                label: "Spoofed",
                value: BotCharts.compact(totals.spoofed),
                note: "claimed an agent, IP says otherwise",
                isAlert: totals.spoofed > 0
            )
            tile(
                label: "AI referrals",
                value: BotCharts.compact(totals.referrals),
                note: "humans arriving from an AI answer"
            )
        }
    }

    static func tile(
        label: String,
        value: String,
        note: String,
        isHero: Bool = false,
        isAlert: Bool = false
    ) -> some HTML {
        div(.class(isHero ? "tile hero" : "tile")) {
            div(.class("label")) { label }
            div(.class(isAlert ? "value alert" : "value")) { value }
            div(.class("note")) { note }
        }
    }

    // MARK: - Cards

    private static func timeSeriesCard(
        data: BotDashboardData,
        range: BotDateRange,
        timeZone: TimeZone
    ) -> some HTML {
        div(.class("card")) {
            h2 { "Visits over time" }
            p(.class("hint")) {
                "Stacked by what the agent was doing. \(range.isHourly ? "Hourly" : "Daily") buckets, \(timeZone.identifier)."
            }
            div(.class("chart")) {
                HTMLRaw(BotCharts.stackedColumns(series: data.series, range: range, timeZone: timeZone))
            }
            div(.class("legend")) {
                for entry in data.purposeTotals {
                    div {
                        i(.custom(name: "style", value: "background:\(DashboardTheme.seriesColor(for: entry.purpose))")) {}
                        span { entry.purpose.label }
                        b { BotCharts.grouped(entry.count) }
                    }
                }
            }
        }
    }

    private static func agentsCard(_ agents: [BotDashboardData.AgentRow]) -> some HTML {
        div(.class("card")) {
            h2 { "Top agents" }
            p(.class("hint")) { "Who is reading the site, and how much of it we could verify." }
            if agents.isEmpty {
                p(.class("hint")) { "No agent visits in this window." }
            } else {
                HTMLRaw(BotCharts.barRows(agents.map { agent in
                    .init(
                        name: agent.name,
                        // "Diffbot Diffbot" helps nobody: the operator is only
                        // worth showing when it adds something the name does not.
                        meta: (agent.operatorName == "Unknown" || agent.operatorName == agent.name)
                            ? nil : agent.operatorName,
                        value: agent.count,
                        note: agent.verified > 0 ? "\(BotCharts.grouped(agent.verified)) verified" : nil,
                        color: agent.purpose.map(DashboardTheme.seriesColor(for:)) ?? "var(--baseline)",
                        flag: agent.respectsRobotsTxt == false ? "ignores robots.txt" : nil
                    )
                }))
            }
        }
    }

    private static func pagesCard(_ pages: [BotDashboardData.PageRow]) -> some HTML {
        div(.class("card")) {
            h2 { "Most-read pages" }
            p(.class("hint")) { "What AI agents actually pull. The user-triggered count is the one to watch." }
            if pages.isEmpty {
                p(.class("hint")) { "No page requests in this window." }
            } else {
                HTMLRaw(BotCharts.barRows(pages.map { page in
                    .init(
                        name: page.path,
                        meta: nil,
                        value: page.count,
                        note: page.userTriggered > 0 ? "\(BotCharts.grouped(page.userTriggered)) user-triggered" : nil,
                        color: "var(--series-1-soft)",
                        flag: nil,
                        highlight: page.userTriggered,
                        highlightColor: "var(--series-1)"
                    )
                }))
                // Two shades means two marks, so the legend is not optional.
                div(.class("legend")) {
                    div {
                        i(.custom(name: "style", value: "background:var(--series-1)")) {}
                        span { "User-triggered" }
                    }
                    div {
                        i(.custom(name: "style", value: "background:var(--series-1-soft)")) {}
                        span { "Crawled without a person asking" }
                    }
                }
            }
        }
    }

    private static func referralsCard(_ referrals: [BotDashboardData.PlatformRow]) -> some HTML {
        div(.class("card")) {
            h2 { "Visitors from AI assistants" }
            p(.class("hint")) {
                "Humans who clicked through from an AI answer. Client-side analytics often miss these, for example when they wait for cookie consent."
            }
            if referrals.isEmpty {
                p(.class("hint")) { "No AI referrals in this window." }
            } else {
                HTMLRaw(BotCharts.barRows(referrals.map { row in
                    .init(name: row.platform, meta: nil, value: row.count, note: nil,
                          color: "var(--series-3)", flag: nil)
                }))
            }
        }
    }

    private static func emptyState(range: BotDateRange) -> some HTML {
        div(.class("card")) {
            div(.class("empty")) {
                p { "Nothing recorded in the \(range.label.lowercased())." }
                p(.class("hint")) {
                    "Tracking starts the moment the middleware is deployed. It cannot see traffic from before that. Crawlers usually show up within a day."
                }
            }
        }
    }

    private static func footnote(knownAgentCount: Int) -> some HTML {
        p(.class("sub")) {
            "\(knownAgentCount) known agents. \u{201C}Verified\u{201D} means the source IP fell inside the range list its operator publishes. OpenAI and Perplexity publish one list per agent and Anthropic one list for all its Claude agents. Agents whose operator publishes no list stay unverified rather than counting against the rate."
        }
    }

    /// Never rounds up to 100% while a single spoof is on record: the Spoofed
    /// tile sits right beside this one, and "100% verified / 3 spoofed" reads as
    /// a contradiction rather than as rounding.
    private static func percentage(_ share: Double) -> String {
        let scaled = share * 100
        if share < 1, scaled >= 99.5 { return "99%" }
        if share > 0, scaled < 0.5 { return "<1%" }
        return "\(Int(scaled.rounded()))%"
    }

    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }
}
