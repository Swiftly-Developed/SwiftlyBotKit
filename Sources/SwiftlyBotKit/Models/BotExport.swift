import Foundation

/// How finely an export is broken down in time.
enum BotExportDetail: String, CaseIterable, Sendable {
    /// One line per stored row: per request for AI agents and referrals, per
    /// quarter-hour counter for people, which is the finest that is stored.
    case raw
    case day
    /// ISO weeks, Monday to Sunday.
    case week
    case month
    /// One period covering the whole range.
    case total

    var label: String {
        switch self {
        case .raw: return "Raw rows"
        case .day: return "Per day"
        case .week: return "Per week"
        case .month: return "Per month"
        case .total: return "Totals"
        }
    }

    var hint: String {
        switch self {
        case .raw: return "One line per AI request; people as quarter-hour counters"
        case .day: return "Calendar days"
        case .week: return "ISO weeks, Monday to Sunday"
        case .month: return "Calendar months"
        case .total: return "One line per group over the whole period"
        }
    }

    /// The `Calendar` unit a period spans, `nil` for raw and totals.
    fileprivate var calendarUnit: Calendar.Component? {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .raw, .total: return nil
        }
    }
}

/// Whose traffic an export includes. Any combination can be ticked; each
/// line of the file says which one it belongs to.
enum BotExportAudience: String, CaseIterable, Sendable {
    /// Requests by AI agents in the catalog.
    case agents
    /// People arriving from an AI assistant's answer.
    case referrals
    /// Page views by people, from the anonymous counters.
    case people

    /// The `audience` column's value.
    var csvValue: String {
        switch self {
        case .agents: return "ai_agent"
        case .referrals: return "ai_referral"
        case .people: return "people"
        }
    }

    var label: String {
        switch self {
        case .agents: return "AI agents"
        case .referrals: return "AI referrals"
        case .people: return "People"
        }
    }

    var hint: String {
        switch self {
        case .agents: return "Requests by AI crawlers, search indexers and assistants"
        case .referrals: return "People who arrived from an AI assistant's answer"
        case .people: return "Anonymous page views, counted per quarter-hour"
        }
    }
}

/// What a grouped export can be broken down by besides time. A dimension
/// that does not apply to an audience (an agent name for people) is left
/// empty on that audience's lines.
enum BotExportDimension: String, CaseIterable, Sendable {
    case site
    case path
    /// The agent and its operator, as two columns.
    case agent
    case purpose
    case verification
    case referrer

    var label: String {
        switch self {
        case .site: return "Site"
        case .path: return "Page"
        case .agent: return "Agent and operator"
        case .purpose: return "Purpose"
        case .verification: return "Verification"
        case .referrer: return "Referring assistant"
        }
    }

    var hint: String {
        switch self {
        case .site: return "All audiences"
        case .path: return "All audiences"
        case .agent: return "AI agents"
        case .purpose: return "AI agents: training, AI search, user-triggered, ..."
        case .verification: return "AI agents: verified, unverified, spoofed"
        case .referrer: return "AI referrals: ChatGPT, Claude, ..."
        }
    }

    /// The CSV header(s) this dimension adds.
    var columns: [String] {
        switch self {
        case .site: return ["site"]
        case .path: return ["path"]
        case .agent: return ["agent", "operator"]
        case .purpose: return ["purpose"]
        case .verification: return ["verification"]
        case .referrer: return ["referrer_platform"]
        }
    }

    func applies(to audience: BotExportAudience) -> Bool {
        switch self {
        case .site, .path: return true
        case .agent, .purpose, .verification: return audience == .agents
        case .referrer: return audience == .referrals
        }
    }
}

/// A calendar date typed into the export form, `yyyy-MM-dd`.
struct BotExportDay: Sendable, Equatable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    /// Parses `yyyy-MM-dd`, the value an `<input type="date">` submits, and
    /// refuses dates that do not exist (`2026-02-30`).
    init?(_ raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1970...9999).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let calendar = BotDateRange.calendar(in: TimeZone(secondsFromGMT: 0)!)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    var string: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The first instant of this date in `calendar`'s zone: local midnight,
    /// or the first hour after it on a day whose midnight is skipped.
    func start(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day)).map(calendar.startOfDay(for:))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// Why an export could not be built. Shown above the form.
enum BotExportError: Error, Equatable, Sendable {
    case missingDates
    case invalidDate(String)
    case reversedDates
    case rangeTooLong
    case noAudience
    case peopleUnavailable

    var message: String {
        switch self {
        case .missingDates: return "Choose a start and an end date for a custom period."
        case .invalidDate(let raw): return "\u{201C}\(raw)\u{201D} is not a date. Use the format 2026-09-26."
        case .reversedDates: return "The start date is after the end date."
        case .rangeTooLong: return "A custom period can be at most \(BotExportOptions.maximumCustomDays) days long."
        case .noAudience: return "Tick at least one of AI agents, AI referrals or people."
        case .peopleUnavailable: return "Page views are not counted on this app, so there is nothing to export for people."
        }
    }
}

/// Everything the export form asks for, as submitted.
///
/// Kept as the raw form state (the custom dates as typed) so a refused
/// submission comes back with the form filled in as it was sent.
struct BotExportOptions: Sendable, Equatable {
    /// The longest custom period, which bounds the bucket list sent to
    /// PostgreSQL. Ten years of days.
    static let maximumCustomDays = 3_660

    /// The preset in use when ``isCustom`` is off.
    var range: BotDateRange
    var isCustom: Bool
    var from: String
    var to: String
    var detail: BotExportDetail
    var audiences: Set<BotExportAudience>
    /// AI agents: only successful `GET`s of a page, the rows the Page views
    /// tab counts, so they add up like for like with people.
    var pageReadsOnly: Bool
    var dimensions: Set<BotExportDimension>

    /// The form as first shown.
    static func initial(range: BotDateRange, peopleAvailable: Bool) -> Self {
        .init(
            range: range,
            isCustom: false,
            from: "",
            to: "",
            detail: .day,
            audiences: peopleAvailable ? [.agents, .referrals, .people] : [.agents, .referrals],
            pageReadsOnly: false,
            dimensions: []
        )
    }

    /// Reads a submission. `value` looks up one query parameter.
    ///
    /// Checkboxes send nothing when unticked, so an absent one is off; the
    /// form's hidden `v` field tells a submission from a plain visit to the
    /// tab, which gets ``initial(range:peopleAvailable:)`` instead.
    init(
        query value: (String) -> String?,
        offeredRanges: [BotDateRange],
        defaultRange: BotDateRange,
        peopleAvailable: Bool
    ) {
        let rawRange = value("range")
        let preset = rawRange.flatMap(BotDateRange.init(rawValue:)).flatMap { offeredRanges.contains($0) ? $0 : nil }
        guard value("v") != nil else {
            self = .initial(range: preset ?? defaultRange, peopleAvailable: peopleAvailable)
            return
        }
        func ticked(_ name: String) -> Bool { value(name).map { !$0.isEmpty } ?? false }
        self.init(
            range: preset ?? defaultRange,
            isCustom: rawRange == "custom",
            from: value("from") ?? "",
            to: value("to") ?? "",
            detail: value("detail").flatMap(BotExportDetail.init(rawValue:)) ?? .day,
            audiences: Set(BotExportAudience.allCases.filter { ticked($0.rawValue) }),
            pageReadsOnly: ticked("page_reads"),
            dimensions: Set(BotExportDimension.allCases.filter { ticked("by_\($0.rawValue)") })
        )
    }

    init(
        range: BotDateRange,
        isCustom: Bool,
        from: String,
        to: String,
        detail: BotExportDetail,
        audiences: Set<BotExportAudience>,
        pageReadsOnly: Bool,
        dimensions: Set<BotExportDimension>
    ) {
        self.range = range
        self.isCustom = isCustom
        self.from = from
        self.to = to
        self.detail = detail
        self.audiences = audiences
        self.pageReadsOnly = pageReadsOnly
        self.dimensions = dimensions
    }

    /// Checks the submission and works out the instants and periods.
    func plan(now: Date, timeZone: TimeZone, siteKey: String?, peopleAvailable: Bool) throws -> BotExportPlan {
        guard !audiences.isEmpty else { throw BotExportError.noAudience }
        if audiences.contains(.people), !peopleAvailable { throw BotExportError.peopleUnavailable }

        let calendar = Self.isoCalendar(in: timeZone)
        let start: Date
        let end: Date
        if isCustom {
            let fromText = from.trimmingCharacters(in: .whitespaces)
            let toText = to.trimmingCharacters(in: .whitespaces)
            guard !fromText.isEmpty, !toText.isEmpty else { throw BotExportError.missingDates }
            guard let first = BotExportDay(fromText) else { throw BotExportError.invalidDate(fromText) }
            guard let last = BotExportDay(toText) else { throw BotExportError.invalidDate(toText) }
            guard first <= last else { throw BotExportError.reversedDates }
            guard let startDate = first.start(in: calendar),
                  let lastStart = last.start(in: calendar),
                  let dayAfter = calendar.date(byAdding: .day, value: 1, to: lastStart)
            else { throw BotExportError.invalidDate(toText) }
            let days = calendar.dateComponents([.day], from: startDate, to: lastStart).day ?? 0
            guard days < Self.maximumCustomDays else { throw BotExportError.rangeTooLong }
            start = startDate
            // The day after `last`, from its own start, so a 23- or 25-hour
            // last day is covered exactly.
            end = calendar.startOfDay(for: dayAfter)
        } else {
            start = range.start(from: now, in: timeZone)
            end = now
        }

        return BotExportPlan(
            start: start,
            end: end,
            periods: Self.periods(detail: detail, start: start, end: end, calendar: calendar),
            detail: detail,
            audiences: BotExportAudience.allCases.filter(audiences.contains),
            dimensions: detail == .raw ? [] : BotExportDimension.allCases.filter(dimensions.contains),
            pageReadsOnly: pageReadsOnly,
            siteKey: siteKey,
            timeZone: timeZone
        )
    }

    /// Gregorian with ISO week rules (weeks start on Monday, week 1 holds the
    /// first Thursday), in `timeZone`. Built by hand rather than as
    /// `.iso8601` so Darwin and Linux agree.
    static func isoCalendar(in timeZone: TimeZone) -> Calendar {
        var calendar = BotDateRange.calendar(in: timeZone)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// The periods between `start` and `end`, oldest first. The first and
    /// last are clipped to the range, so a 24-hour export per day is two
    /// partial days whose exact bounds are in the file.
    ///
    /// Computed in Swift, like every dashboard bucket, and handed to
    /// PostgreSQL as instants: it never needs to know the zone.
    static func periods(detail: BotExportDetail, start: Date, end: Date, calendar: Calendar) -> [BotExportPlan.Period] {
        guard start < end else { return [] }
        switch detail {
        case .raw:
            return []
        case .total:
            return [.init(label: "total", start: start, end: end)]
        case .day, .week, .month:
            guard let unit = detail.calendarUnit else { return [] }
            var periods: [BotExportPlan.Period] = []
            var cursor = start
            while cursor < end, let interval = calendar.dateInterval(of: unit, for: cursor), interval.end > cursor {
                periods.append(.init(
                    label: label(for: interval.start, detail: detail, calendar: calendar),
                    start: max(interval.start, start),
                    end: min(interval.end, end)
                ))
                cursor = interval.end
            }
            return periods
        }
    }

    /// `2026-09-26`, `2026-W39` or `2026-09`.
    static func label(for date: Date, detail: BotExportDetail, calendar: Calendar) -> String {
        switch detail {
        case .week:
            let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
        case .month:
            let parts = calendar.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        default:
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
    }
}

/// A checked export: the instants it covers and how to break them down.
struct BotExportPlan: Sendable {
    /// One line group of a time-bucketed export.
    struct Period: Sendable, Equatable {
        /// `2026-09-26`, `2026-W39`, `2026-09` or `total`.
        let label: String
        let start: Date
        /// Exclusive.
        let end: Date
    }

    /// Inclusive.
    let start: Date
    /// Exclusive.
    let end: Date
    /// Empty for a raw export.
    let periods: [Period]
    let detail: BotExportDetail
    /// In ``BotExportAudience`` case order.
    let audiences: [BotExportAudience]
    /// In ``BotExportDimension`` case order; always empty for a raw export.
    let dimensions: [BotExportDimension]
    let pageReadsOnly: Bool
    /// `nil` for every site.
    let siteKey: String?
    let timeZone: TimeZone

    /// `ai-traffic_all-sites_2026-09-01_2026-09-26_day.csv`. The site key is
    /// app-defined, so it is reduced to characters that are safe in a
    /// `Content-Disposition` header and a file name.
    var fileName: String {
        let site = (siteKey ?? "all-sites").map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }
        let formatter = BotExportCSV.dayFormatter(in: timeZone)
        let lastInstant = end > start ? end.addingTimeInterval(-1) : start
        return "ai-traffic_\(String(site))_\(formatter.string(from: start))_\(formatter.string(from: lastInstant))_\(detail.rawValue).csv"
    }
}
