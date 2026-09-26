import Foundation

/// The dashboard's date filter.
///
/// Four presets rather than a free date picker: crawler traffic is read in
/// "since yesterday / this week / this month" terms, and a preset keeps the URL
/// shareable and the bucket size decided. Which presets are offered, and which
/// one opens by default, is set in ``BotKitConfiguration/Dashboard``.
///
/// ## Buckets
///
/// A bucket is one local wall-clock hour (`24h`) or one local calendar day
/// (`7d`, `30d`, `90d`) in the configured time zone
/// (``BotKitConfiguration/Dashboard/timeZone``). Every boundary is computed
/// here, in Swift, from Foundation's rules for that zone. PostgreSQL is sent
/// the boundaries as instants and only sorts rows between them, so it never
/// needs to know the zone, and the two sides cannot disagree about a DST
/// transition, a zone name or a fixed offset.
///
/// Around DST changes the buckets follow the wall clock:
///
/// - A day is 23 or 25 hours long on the change days, and a day whose local
///   midnight is skipped (Santiago, Cairo) starts at 01:00.
/// - A skipped hour (spring forward) has no bucket.
/// - A repeated hour (fall back) is **one** bucket holding both passes, so
///   the `24h` axis never shows the same label twice. Its bar can be up to
///   twice as tall as its neighbours.
public enum BotDateRange: String, CaseIterable, Sendable {
    /// The last 24 hours, in hourly buckets. Query value `24h`.
    case day = "24h"
    /// The last 7 days, in daily buckets. Query value `7d`.
    case week = "7d"
    /// The last 30 days, in daily buckets. Query value `30d`.
    case month = "30d"
    /// The last 90 days, in daily buckets. Query value `90d`.
    case quarter = "90d"

    /// A Gregorian calendar in `timeZone`.
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

    /// How many buckets the chart shows.
    var bucketCount: Int {
        switch self {
        case .day: return 24
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    /// Seconds of wall-clock time in one bucket.
    private var unitSeconds: Int64 { isHourly ? 3_600 : 86_400 }

    /// Start of the window: the first instant of the oldest bucket. Aligned to
    /// a bucket boundary, so the leading bar covers a whole hour or day rather
    /// than a partial one, which would otherwise read as a dip.
    public func start(from now: Date, in timeZone: TimeZone) -> Date {
        window(now: now, in: timeZone).start
    }

    /// The first instant of every bucket in the window, oldest first.
    ///
    /// Generated here rather than taken from the query results, so a quiet hour
    /// shows as a zero-height bar instead of vanishing and silently compressing
    /// the axis.
    public func buckets(now: Date, in timeZone: TimeZone) -> [Date] {
        window(now: now, in: timeZone).buckets.map(\.start)
    }

    /// Axis label for the bucket holding `date`, in `timeZone`: "14:00" or
    /// "3 Mar". It names the wall-clock hour or day, so a bucket that starts
    /// off the hour (Lord Howe's 02:30 after its 30-minute DST jump) is still
    /// labelled "02:00".
    public func axisLabel(for date: Date, in timeZone: TimeZone) -> String {
        // `DateFormatter`, never `Date.formatted`: `FormatStyle` is incomplete
        // on Linux. The key is local wall-clock time, so it is formatted as if
        // it were UTC.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = isHourly ? "HH:mm" : "d MMM"
        let local = Double(bucketKey(for: date, in: timeZone) * unitSeconds)
        return formatter.string(from: Date(timeIntervalSince1970: local))
    }

    /// Heading for a column's hover popover: "Sat 3 Mar, 14:00 to 15:00" or
    /// "Sat 3 Mar". Like ``axisLabel(for:in:)`` it names the wall-clock bucket,
    /// but spells out the day so an hourly bar is not just a time.
    func popoverLabel(for date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let local = Date(timeIntervalSince1970: Double(bucketKey(for: date, in: timeZone) * unitSeconds))
        formatter.dateFormat = "EEE d MMM"
        let day = formatter.string(from: local)
        guard isHourly else { return day }
        formatter.dateFormat = "HH:mm"
        return "\(day), \(formatter.string(from: local)) to \(formatter.string(from: local.addingTimeInterval(3_600)))"
    }

    // MARK: - Wall-clock keys

    /// The bucket an instant belongs to: its local wall-clock time, in whole
    /// hours or days since 1970-01-01 00:00 local. Two instants share a bucket
    /// exactly when they share a key, which is what makes a repeated hour one
    /// bucket.
    func bucketKey(for date: Date, in timeZone: TimeZone) -> Int64 {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let local = seconds + Int64(timeZone.secondsFromGMT(for: date))
        return floorDivide(local, unitSeconds)
    }

    /// One bar of the chart.
    struct Bucket: Sendable, Equatable {
        /// Wall-clock key, see ``BotDateRange/bucketKey(for:in:)``.
        let key: Int64
        /// First instant in the window with this key.
        let start: Date
    }

    /// A stretch of time in which the wall-clock key does not change. A bucket
    /// is one run, or several when the clock falls back across it.
    struct Run: Sendable, Equatable {
        let start: Date
        /// Index into ``Window/buckets``.
        let bucket: Int
    }

    /// Everything the series query needs.
    struct Window: Sendable {
        /// Oldest first, one per distinct key, `bucketCount` of them.
        let buckets: [Bucket]
        /// Oldest first. The run starts are the thresholds PostgreSQL's
        /// `width_bucket` sorts rows between.
        let runs: [Run]
        var start: Date { runs.first?.start ?? buckets.first?.start ?? Date() }
    }

    /// The last `bucketCount` wall-clock hours or days up to `now`.
    ///
    /// Key changes happen only at local unit boundaries (constant offset) and
    /// at offset transitions, so those instants are the only candidates.
    /// Between them the key is constant, which makes the result exact for any
    /// zone and offset, including 30- and 45-minute ones.
    func window(now: Date, in timeZone: TimeZone) -> Window {
        let unit = unitSeconds
        var lookback = Int64(bucketCount + 2) * unit
        while true {
            let nowSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
            let lower = nowSeconds - lookback

            // Candidate boundaries in [lower, now], ascending.
            var candidates: [Int64] = [lower]
            var segmentStart = lower
            while segmentStart <= nowSeconds {
                let transition = timeZone
                    .nextDaylightSavingTimeTransition(after: Date(timeIntervalSince1970: Double(segmentStart)))
                    .map { Int64($0.timeIntervalSince1970.rounded(.up)) }
                let segmentEnd = min(transition ?? Int64.max, nowSeconds + 1)
                let offset = Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(segmentStart))))
                var boundary = (floorDivide(segmentStart + offset, unit) + 1) * unit - offset
                while boundary < segmentEnd {
                    candidates.append(boundary)
                    boundary += unit
                }
                guard let transition, transition <= nowSeconds, transition > segmentStart else { break }
                candidates.append(transition)
                segmentStart = transition
            }

            // Maximal runs of equal key.
            var runs: [(start: Int64, key: Int64)] = []
            for candidate in candidates {
                let key = bucketKey(for: Date(timeIntervalSince1970: Double(candidate)), in: timeZone)
                if runs.last?.key != key { runs.append((candidate, key)) }
            }

            // Newest first, keep runs until a new key would exceed the count.
            var keys: Set<Int64> = []
            var firstIncluded = runs.count
            for index in runs.indices.reversed() {
                let key = runs[index].key
                if !keys.contains(key) {
                    guard keys.count < bucketCount else { break }
                    keys.insert(key)
                }
                firstIncluded = index
            }

            // The oldest run may be cut off at `lower`; widen and retry
            // rather than show a partial first bar.
            if firstIncluded == 0 && lookback < Int64(bucketCount + 2) * unit * 4 {
                lookback *= 2
                continue
            }

            let included = runs[firstIncluded...]
            let sortedKeys = keys.sorted()
            let position = Dictionary(uniqueKeysWithValues: sortedKeys.enumerated().map { ($1, $0) })
            var bucketStarts: [Int64: Int64] = [:]
            for run in included where bucketStarts[run.key] == nil {
                bucketStarts[run.key] = run.start
            }
            return Window(
                buckets: sortedKeys.map { .init(key: $0, start: Date(timeIntervalSince1970: Double(bucketStarts[$0]!))) },
                runs: included.map { .init(start: Date(timeIntervalSince1970: Double($0.start)), bucket: position[$0.key]!) }
            )
        }
    }
}

/// Division rounding toward negative infinity, so instants before 1970 and
/// negative offsets still land in the right bucket.
private func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
    let quotient = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
}
