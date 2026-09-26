import Foundation

/// What the Page views chart is coloured by, from `?color=`.
///
/// ``none`` draws one colour per bar, as the tab always has. Anything else
/// stacks each bar by the chosen breakdown: the page or site section, read
/// from the quarter-hour counters and so available at any bucket size, or a
/// ``PageViewDimension``, stored per day.
enum PageViewColorBy: Equatable, Hashable, Sendable {
    case none
    case page
    case section
    case dimension(PageViewDimension)

    init(query raw: String?) {
        switch raw {
        case "page": self = .page
        case "section": self = .section
        case let raw?:
            if let dimension = PageViewDimension(rawValue: raw) {
                self = .dimension(dimension)
            } else {
                self = .none
            }
        case nil: self = .none
        }
    }

    /// The `?color=` value, `nil` for ``none``.
    var queryValue: String? {
        switch self {
        case .none: return nil
        case .page: return "page"
        case .section: return "section"
        case .dimension(let dimension): return dimension.rawValue
        }
    }

    var label: String {
        switch self {
        case .none: return "None"
        case .page: return "Page"
        case .section: return "Section"
        case .dimension(let dimension): return dimension.label
        }
    }

    /// Whether the breakdown is stored per day rather than per quarter-hour.
    var isDaily: Bool {
        if case .dimension = self { return true }
        return false
    }

    /// The choices offered, in menu order: none, the page breakdowns, then
    /// every dimension when they are recorded.
    static func options(dimensionsEnabled: Bool) -> [PageViewColorBy] {
        [.none, .page, .section] + (dimensionsEnabled ? PageViewDimension.allCases.map { .dimension($0) } : [])
    }
}

/// A Page views series split by a ``PageViewColorBy`` breakdown.
struct PageViewBreakdown: Sendable, Equatable {

    /// One value of the breakdown, with its share of the whole window.
    struct Series: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// A value of its own: a page, a country.
            case value
            /// Every value beyond the top ones or below the small-cell
            /// threshold, and every view with no value at all (counted
            /// before the dimensions were recorded, or without a country
            /// table), together.
            case other
        }

        let label: String
        let kind: Kind
        let total: Int
        /// One count per bucket.
        let counts: [Int]
    }

    let colorBy: PageViewColorBy
    /// The start of every bucket, oldest first.
    let buckets: [Date]
    /// Whether these buckets are days though the range is hourly, because
    /// the breakdown is only stored per day.
    let isDailyFallback: Bool
    /// Largest value first, then Other. Empty series are left out.
    let series: [Series]
    /// Counts below this are shown as `<N` (dimensions only).
    let smallCellThreshold: Int?
    /// For each of the most-read pages, its views split the same way: one
    /// count per entry of ``series``, in the same order. Over the chart's
    /// buckets, so yesterday and today when ``isDailyFallback``.
    var pageSplits: [String: [Int]] = [:]
    /// The zone the buckets are days in, for a dimension: the zone the days
    /// were stored in, which the chart then draws in whatever the viewer's
    /// own zone. `nil` for the page breakdowns, drawn in the viewer's zone.
    var dayTimeZone: TimeZone?

    var total: Int { series.reduce(0) { $0 + $1.total } }

    /// How many values get a series of their own; one colour is kept for
    /// Other.
    static let maximumValues = DashboardTheme.categoryCount - 1

    /// Builds the series from raw `(bucket index, value, count)` rows.
    ///
    /// Values are ranked by their total over the window. The top
    /// ``maximumValues`` keep their own series; the rest, and any value whose
    /// total is under `smallCellThreshold`, are added to Other. `bucketTotals`,
    /// when given, is the page view count per bucket: whatever it holds beyond
    /// the breakdown's own sum is added to Other.
    static func build(
        colorBy: PageViewColorBy,
        buckets: [Date],
        isDailyFallback: Bool,
        rows: [(bucket: Int, value: String, count: Int)],
        bucketTotals: [Int]?,
        smallCellThreshold: Int?
    ) -> PageViewBreakdown {
        var perValue: [String: [Int]] = [:]
        for row in rows where buckets.indices.contains(row.bucket) {
            perValue[row.value, default: Array(repeating: 0, count: buckets.count)][row.bucket] += row.count
        }
        // Spelled out: Swift 6.0 on Linux gives up type-checking the
        // one-expression map and sort.
        struct Ranked {
            let label: String
            let counts: [Int]
            let total: Int
        }
        var ranked: [Ranked] = []
        for (label, counts) in perValue {
            ranked.append(Ranked(label: label, counts: counts, total: counts.reduce(0, +)))
        }
        ranked.sort { (a: Ranked, b: Ranked) -> Bool in
            if a.total != b.total { return a.total > b.total }
            return a.label < b.label
        }
        var series: [Series] = []
        var other = Array(repeating: 0, count: buckets.count)
        for entry in ranked {
            let isSmall = smallCellThreshold.map { entry.total < $0 } ?? false
            if series.count < maximumValues, !isSmall, entry.label != PageViewDimension.other {
                series.append(.init(label: entry.label, kind: .value, total: entry.total, counts: entry.counts))
            } else {
                for index in other.indices { other[index] += entry.counts[index] }
            }
        }
        if let bucketTotals, bucketTotals.count == buckets.count {
            for index in bucketTotals.indices {
                var accounted = other[index]
                for entry in series { accounted += entry.counts[index] }
                other[index] += max(0, bucketTotals[index] - accounted)
            }
        }
        let otherTotal = other.reduce(0, +)
        if otherTotal > 0 {
            series.append(.init(label: "Other", kind: .other, total: otherTotal, counts: other))
        }
        return PageViewBreakdown(colorBy: colorBy, buckets: buckets, isDailyFallback: isDailyFallback,
                                 series: series, smallCellThreshold: smallCellThreshold)
    }

    /// Index of the series a value is drawn in: its own, or Other.
    func seriesIndex(for value: String) -> Int? {
        series.firstIndex { $0.kind == .value && $0.label == value }
            ?? series.firstIndex { $0.kind == .other }
    }

    /// Splits for pages whose every view has a single value, the page itself
    /// or its section, read straight off ``series``.
    mutating func splitPagesByOwnValue(_ paths: [String], views: [String: Int], value: (String) -> String) {
        for path in paths {
            guard let index = seriesIndex(for: value(path)) else { continue }
            var counts = Array(repeating: 0, count: series.count)
            counts[index] = views[path] ?? 0
            pageSplits[path] = counts
        }
    }

    /// The colour of the series at `index`.
    func color(at index: Int) -> String {
        switch series[index].kind {
        case .value: return DashboardTheme.categoryColor(rank: index)
        case .other: return DashboardTheme.otherColor
        }
    }

    /// `count` as shown: grouped, or `<N` when under the threshold.
    func display(_ count: Int) -> String {
        if let threshold = smallCellThreshold, count > 0, count < threshold { return "<\(threshold)" }
        return BotCharts.grouped(count)
    }
}
