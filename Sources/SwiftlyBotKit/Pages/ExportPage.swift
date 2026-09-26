import Foundation
import Elementary

/// The "Export" tab, at `<dashboard path>/export/`: a form that downloads a
/// CSV from `<dashboard path>/export/csv`.
///
/// A plain `GET` form, so it works without script (the CSP allows none) and
/// an export's settings are a URL that can be bookmarked. The site comes
/// from the switcher, like on every other tab; everything else is in the
/// form. The same rules apply as elsewhere: nothing loaded from elsewhere,
/// every stored string escaped.
enum ExportPage {

    static func render(
        options exportOptions: BotExportOptions,
        sites: [BotDashboardSite],
        selectedSite: BotDashboardSite?,
        generatedAt: Date,
        options: BotKitConfiguration.Dashboard = .default,
        showsPageViews: Bool = false,
        error: BotExportError? = nil
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
                    [DashboardSection.export.label, siteName, options.title].compactMap { $0 }.joined(separator: " \u{00B7} ")
                }
                style { HTMLRaw(DashboardTheme.css) }
            }
            body {
                main {
                    DashboardPage.header(title: options.title, base: base, range: nil, siteName: siteName,
                                         generatedAt: generatedAt, timeZone: timeZone)
                    DashboardPage.filters(base: base, section: .export,
                                          sections: DashboardSection.available(pageViews: showsPageViews),
                                          range: exportOptions.range, ranges: [], sites: sites,
                                          selectedSite: selectedSite)
                    if let error {
                        div(.class("notice"), .custom(name: "role", value: "alert")) { error.message }
                    }
                    form(.method(.get), .action("\(base)/export/csv"), .class("card export")) {
                        h2 { "Export to CSV" }
                        p(.class("hint")) {
                            "\(siteName ?? "This site") \u{00B7} times in \(timeZone.identifier). Change the site with the switcher above."
                        }
                        input(.type(.hidden), .name("site"), .value(selectedSite?.key ?? "all"))
                        input(.type(.hidden), .name("v"), .value("1"))
                        div(.class("fields")) {
                            periodFieldset(exportOptions, ranges: options.offeredDateRanges)
                            detailFieldset(exportOptions)
                            audienceFieldset(exportOptions, showsPeople: showsPageViews)
                            dimensionFieldset(exportOptions)
                        }
                        div(.class("actions")) {
                            button(.type(.submit), .class("btn primary")) { "Download CSV" }
                        }
                    }
                    columnsCard(timeZone: timeZone)
                }
            }
        }
        return "<!DOCTYPE html>" + page.render()
    }

    // MARK: - Fieldsets

    private static func periodFieldset(_ options: BotExportOptions, ranges: [BotDateRange]) -> some HTML {
        fieldset {
            legend { "Period" }
            ForEach(ranges) { range in
                choice(type: .radio, name: "range", value: range.rawValue,
                       checked: !options.isCustom && options.range == range, label: range.label)
            }
            choice(type: .radio, name: "range", value: "custom", checked: options.isCustom,
                   label: "Custom dates", id: "range-custom")
            div(.class("dates")) {
                label {
                    span { "From" }
                    input(.type(.date), .name("from"), .value(options.from))
                }
                label {
                    span { "To" }
                    input(.type(.date), .name("to"), .value(options.to))
                }
            }
            p(.class("hint")) { "Custom dates are whole days, both included." }
        }
    }

    private static func detailFieldset(_ options: BotExportOptions) -> some HTML {
        fieldset {
            legend { "Level of detail" }
            ForEach(BotExportDetail.allCases) { detail in
                choice(type: .radio, name: "detail", value: detail.rawValue, checked: options.detail == detail,
                       label: detail.label, hint: detail.hint)
            }
        }
    }

    private static func audienceFieldset(_ options: BotExportOptions, showsPeople: Bool) -> some HTML {
        fieldset {
            legend { "Include" }
            ForEach(BotExportAudience.allCases.filter { $0 != .people || showsPeople }) { audience in
                choice(type: .checkbox, name: audience.rawValue, value: "1",
                       checked: options.audiences.contains(audience), label: audience.label, hint: audience.hint)
            }
            choice(type: .checkbox, name: "page_reads", value: "1", checked: options.pageReadsOnly,
                   label: "AI agents: page reads only",
                   hint: "Successful GETs of a page, as on the Page views tab; leaves out robots.txt, sitemaps and errors")
        }
    }

    private static func dimensionFieldset(_ options: BotExportOptions) -> some HTML {
        fieldset {
            legend { "Break down by" }
            ForEach(BotExportDimension.allCases) { dimension in
                choice(type: .checkbox, name: "by_\(dimension.rawValue)", value: "1",
                       checked: options.dimensions.contains(dimension), label: dimension.label, hint: dimension.hint)
            }
            p(.class("hint")) { "Raw rows always carry every column, so these apply to the other levels." }
        }
    }

    /// A radio button or checkbox inside its label, so the whole row is the
    /// target and no `for`/`id` pairing is needed.
    private static func choice(
        type: HTMLAttribute<HTMLTag.input>.InputType,
        name: String,
        value: String,
        checked: Bool,
        label text: String,
        hint: String? = nil,
        id: String? = nil
    ) -> some HTML {
        var attributes: [HTMLAttribute<HTMLTag.input>] = [.type(type), .name(name), .value(value)]
        if checked { attributes.append(.checked) }
        if let id { attributes.append(.id(id)) }
        return label(.class("choice")) {
            input(attributes: attributes)
            span {
                b { text }
                if let hint { small { hint } }
            }
        }
    }

    // MARK: - Columns

    private static func columnsCard(timeZone: TimeZone) -> some HTML {
        div(.class("card")) {
            h2 { "What is in the file" }
            p(.class("hint")) {
                "One line per period, audience and group, which pivots cleanly in a spreadsheet. The audience column is ai_agent, ai_referral or people; a column that does not apply to a line's audience is empty."
            }
            dl(.class("columns")) {
                dt { "period" }
                dd { "2026-09-26, 2026-W39 (ISO week), 2026-09 or total" }
                dt { "period_start, period_end" }
                dd { "The exact bounds in \(timeZone.identifier), with the offset; the end is exclusive. The first and last periods are cut to the chosen dates." }
                dt { "count" }
                dd { "Requests for AI agents, visits for AI referrals, page views for people. Periods with nothing recorded are listed with 0 when nothing is broken down." }
                dt { "Raw rows" }
                dd { "time, audience, site, path, method, status_code, agent, operator, purpose, verification, respects_robots_txt, referrer_platform, count. AI lines are one request each; people lines are quarter-hour counters, since that is all that is stored about them. IP hashes and user agents are never exported." }
            }
        }
    }
}
