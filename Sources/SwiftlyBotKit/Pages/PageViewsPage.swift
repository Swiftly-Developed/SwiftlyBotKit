import Foundation
import Elementary

/// The "Page views" tab, at `<dashboard path>/pages/`, shown when
/// ``BotKitConfiguration/PageViews`` is on.
///
/// Same chrome as ``DashboardPage`` (header, tabs, site switcher, range
/// pills) and the same rules: no script, nothing loaded from elsewhere, every
/// stored string escaped.
enum PageViewsPage {

    static func render(
        data: PageViewData,
        range: BotDateRange,
        sites: [BotDashboardSite],
        selectedSite: BotDashboardSite?,
        generatedAt: Date,
        options: BotKitConfiguration.Dashboard = .default
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
                    DashboardPage.filters(base: base, section: .pageViews, showsTabs: true, range: range,
                                          ranges: options.offeredDateRanges, sites: sites, selectedSite: selectedSite)
                    if data.isEmpty {
                        emptyState(range: range)
                    } else {
                        tiles(data, range: range)
                        chartCard(data, range: range, timeZone: timeZone)
                        pagesCard(data.topPages)
                    }
                    footnote()
                }
            }
        }
        return "<!DOCTYPE html>" + page.render()
    }

    private static func tiles(_ data: PageViewData, range: BotDateRange) -> some HTML {
        div(.class("tiles")) {
            DashboardPage.tile(
                label: "Page views",
                value: BotCharts.compact(data.totalViews),
                note: "by people, \(range.label.lowercased())",
                isHero: true
            )
            DashboardPage.tile(
                label: "Pages read",
                value: BotCharts.compact(data.distinctPages),
                note: "distinct paths with a view"
            )
            DashboardPage.tile(
                label: range.isHourly ? "Per hour" : "Per day",
                value: average(views: data.totalViews, buckets: range.bucketCount),
                note: "average over the window"
            )
            DashboardPage.tile(
                label: "AI agent visits",
                value: BotCharts.compact(data.agentVisits),
                note: agentRatio(views: data.totalViews, agents: data.agentVisits)
            )
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

    /// Views per bucket. One decimal below ten, so a quiet site reads "0.4"
    /// rather than a flat "0".
    static func average(views: Int, buckets: Int) -> String {
        let value = Double(views) / Double(max(buckets, 1))
        return value < 9.95 ? oneDecimal(value) : BotCharts.compact(Int(value.rounded()))
    }

    private static func oneDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    private static func chartCard(_ data: PageViewData, range: BotDateRange, timeZone: TimeZone) -> some HTML {
        div(.class("card")) {
            h2 { "Page views over time" }
            p(.class("hint")) {
                "\(range.isHourly ? "Hourly" : "Daily") buckets, \(timeZone.identifier)."
            }
            div(.class("chart")) {
                HTMLRaw(BotCharts.singleColumns(
                    series: data.series, range: range, timeZone: timeZone,
                    label: "Page views", color: "var(--series-1)"
                ))
            }
        }
    }

    private static func pagesCard(_ pages: [PageViewData.PageRow]) -> some HTML {
        div(.class("card")) {
            h2 { "Most-viewed pages" }
            p(.class("hint")) {
                "What people read, with the AI agent requests for the same page beside it."
            }
            HTMLRaw(BotCharts.barRows(pages.map { page in
                .init(
                    name: page.path,
                    meta: nil,
                    value: page.views,
                    note: page.agentVisits > 0 ? "\(BotCharts.grouped(page.agentVisits)) AI agent" : nil,
                    color: "var(--series-1)",
                    flag: nil
                )
            }))
        }
    }

    private static func emptyState(range: BotDateRange) -> some HTML {
        div(.class("card")) {
            div(.class("empty")) {
                p { "No page views in the \(range.label.lowercased())." }
                p(.class("hint")) {
                    "Counting starts when page views are enabled and deployed. Counts are written every few seconds."
                }
            }
        }
    }

    private static func footnote() -> some HTML {
        p(.class("sub")) {
            "Counted without cookies and without storing anything about the visitor: no IP address, no user agent, no referrer. Each view adds one to a counter for its page and quarter-hour. Only successful HTML pages opened in a browser count; AI agents, other bots, HTMX swaps and prefetches do not. These are views, not visitors: one person reading two pages is two views."
        }
    }
}
