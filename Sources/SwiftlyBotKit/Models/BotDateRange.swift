import Foundation

/// The dashboard's date filter.
///
/// Four presets rather than a free date picker: crawler traffic is read in
/// "since yesterday / this week / this month" terms, and a preset keeps the URL
/// shareable and the bucket size decided. Which presets are offered, and which
/// one opens by default, is set in ``BotKitConfiguration/Dashboard``.
///
/// Every bucket boundary is drawn in one configured time zone
/// (``BotKitConfiguration/Dashboard/timeZone``). PostgreSQL is told the same
/// zone by name, so a "day" means the same thing on both sides of the query
/// even across DST changes, when a local day is 23 or 25 hours long and plain
/// epoch arithmetic would drift.
public enum BotDateRange: String, CaseIterable, Sendable {
    /// The last 24 hours, in hourly buckets. Query value `24h`.
    case day = "24h"
    /// The last 7 days, in daily buckets. Query value `7d`.
    case week = "7d"
    /// The last 30 days, in daily buckets. Query value `30d`.
    case month = "30d"
    /// The last 90 days, in daily buckets. Query value `90d`.
    case quarter = "90d"

    /// A Gregorian calendar in `timeZone`, the one all bucket arithmetic uses.
    public static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// The filter pill's long description, e.g. "Last 7 days".
    public var label: String {
        switch self {
        case .day: return "Last 24 hours"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .quarter: return "Last 90 days"
        }
    }

    /// Short form for the filter pills.
    public var shortLabel: String { rawValue }

    /// Hourly buckets over a day, daily buckets beyond it: 24 bars or 7/30/90,
    /// all of which fit a chart without thinning.
    var isHourly: Bool { self == .day }

    /// The `date_trunc` unit handed to Postgres.
    var truncation: String { isHourly ? "hour" : "day" }

    private var bucketCount: Int {
        switch self {
        case .day: return 24
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    private var component: Calendar.Component { isHourly ? .hour : .day }

    /// Start of the window: the first bucket boundary at or before
    /// `now - duration`. Aligning means the leading bar covers a whole hour or
    /// day rather than a partial one, which would otherwise read as a dip.
    public func start(from now: Date, in timeZone: TimeZone) -> Date {
        let calendar = Self.calendar(in: timeZone)
        let currentBucket = self.bucket(containing: now, calendar: calendar)
        return calendar.date(byAdding: component, value: -(bucketCount - 1), to: currentBucket) ?? currentBucket
    }

    /// Every bucket boundary in the window, oldest first.
    ///
    /// Generated here rather than taken from the query results, so a quiet hour
    /// shows as a zero-height bar instead of vanishing and silently compressing
    /// the axis.
    public func buckets(now: Date, in timeZone: TimeZone) -> [Date] {
        let calendar = Self.calendar(in: timeZone)
        var result: [Date] = []
        var cursor = start(from: now, in: timeZone)
        let last = bucket(containing: now, calendar: calendar)
        while cursor <= last, result.count < bucketCount {
            result.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    func bucket(containing date: Date, calendar: Calendar) -> Date {
        let units: Set<Calendar.Component> = isHourly
            ? [.year, .month, .day, .hour]
            : [.year, .month, .day]
        return calendar.date(from: calendar.dateComponents(units, from: date)) ?? date
    }

    /// Axis label for one bucket, in `timeZone`. `DateFormatter`, never
    /// `Date.formatted`: `FormatStyle` is incomplete on Linux.
    public func axisLabel(for date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = isHourly ? "HH:mm" : "d MMM"
        return formatter.string(from: date)
    }
}
