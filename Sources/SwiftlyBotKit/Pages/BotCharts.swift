import Foundation

/// The chart marks, built as SVG and HTML strings.
///
/// Strings rather than Elementary elements because Elementary has no SVG
/// vocabulary (`AGENTS.md` keeps `HTMLRaw` for exactly this), and because the
/// geometry reads better as arithmetic than as nested builders. Everything that
/// comes from the database goes through `escape` on the way in: agent names and
/// request paths are attacker-influenced text.
///
/// `Double` throughout, never `CGFloat`: CoreGraphics does not exist on
/// Linux.
enum BotCharts {

    // MARK: - Columns over time

    /// One coloured part of a column.
    struct ColumnSegment {
        let label: String
        let color: String
        let count: Int
    }

    /// One column per bucket, stacked by purpose, drawn bottom-up in
    /// `AIAgentPurpose.displayOrder` so touching segments are always adjacent
    /// palette slots: the pairing the palette is validated for.
    static func stackedColumns(
        series: [BotDashboardData.SeriesPoint],
        range: BotDateRange,
        timeZone: TimeZone
    ) -> String {
        columns(
            series.map { point in
                (point.bucket, AIAgentPurpose.displayOrder.compactMap { purpose -> ColumnSegment? in
                    let count = point.counts[purpose] ?? 0
                    return count > 0
                        ? ColumnSegment(label: purpose.label, color: DashboardTheme.seriesColor(for: purpose), count: count)
                        : nil
                })
            },
            range: range,
            timeZone: timeZone,
            ariaLabel: "AI agent visits per \(range.isHourly ? "hour" : "day"), stacked by purpose"
        )
    }

    /// One single-colour column per bucket, for a series with one measure.
    static func singleColumns(
        series: [(bucket: Date, count: Int)],
        range: BotDateRange,
        timeZone: TimeZone,
        label: String,
        color: String
    ) -> String {
        columns(
            series.map { point in
                (point.bucket, point.count > 0 ? [ColumnSegment(label: label, color: color, count: point.count)] : [])
            },
            range: range,
            timeZone: timeZone,
            ariaLabel: "\(label) per \(range.isHourly ? "hour" : "day")"
        )
    }

    /// The column chart both of the above draw: segments stacked bottom-up in
    /// the order given. Adjacent segments should use adjacent palette slots.
    static func columns(
        _ stacks: [(bucket: Date, segments: [ColumnSegment])],
        range: BotDateRange,
        timeZone: TimeZone,
        ariaLabel: String
    ) -> String {
        let width = 760.0, height = 232.0
        let left = 44.0, right = 10.0, top = 14.0, bottom = 26.0
        let plotWidth = width - left - right
        let plotHeight = height - top - bottom
        let baseline = top + plotHeight

        let peak = stacks.map { $0.segments.reduce(0) { $0 + $1.count } }.max() ?? 0
        let scaleMax = niceMax(peak)
        let band = stacks.isEmpty ? plotWidth : plotWidth / Double(stacks.count)
        // Capped at 24px; the band's leftover is deliberately left as air.
        let barWidth = min(24.0, max(3.0, band - 6.0))

        var svg = "<svg viewBox=\"0 0 \(fmt(width)) \(fmt(height))\" role=\"img\" aria-label=\"\(escape(ariaLabel))\">"

        // Gridlines and y ticks: hairline, solid, recessive.
        for step in 0...4 {
            let value = Double(scaleMax) * Double(step) / 4
            let y = baseline - (value / Double(scaleMax)) * plotHeight
            svg += "<line x1=\"\(fmt(left))\" y1=\"\(fmt(y))\" x2=\"\(fmt(left + plotWidth))\" y2=\"\(fmt(y))\""
            svg += " stroke=\"var(--\(step == 0 ? "baseline" : "grid"))\" stroke-width=\"1\"/>"
            svg += "<text class=\"axis\" x=\"\(fmt(left - 8))\" y=\"\(fmt(y + 3.5))\" text-anchor=\"end\">\(grouped(Int(value)))</text>"
        }

        // Columns.
        let labelStep = max(1, Int((Double(stacks.count) / 8.0).rounded(.up)))
        for (index, stack) in stacks.enumerated() {
            let x = left + band * Double(index) + (band - barWidth) / 2
            let segments = stack.segments.filter { $0.count > 0 }
            var cursor = baseline
            for (position, segment) in segments.enumerated() {
                let full = Double(segment.count) / Double(scaleMax) * plotHeight
                let isTop = position == segments.count - 1
                // 2px of surface between touching segments. The topmost segment
                // keeps its full height; the gap always sits below the next one.
                let drawn = max(1.5, isTop ? full : full - 2)
                let y = cursor - full
                let title = "<title>\(escape(range.axisLabel(for: stack.bucket, in: timeZone))) · \(escape(segment.label)): \(grouped(segment.count))</title>"
                if isTop {
                    let radius = min(4.0, drawn, barWidth / 2)
                    svg += "<path d=\"\(roundedTopPath(x: x, y: y, width: barWidth, height: drawn, radius: radius))\" fill=\"\(segment.color)\">\(title)</path>"
                } else {
                    svg += "<rect x=\"\(fmt(x))\" y=\"\(fmt(y + (full - drawn)))\" width=\"\(fmt(barWidth))\" height=\"\(fmt(drawn))\" fill=\"\(segment.color)\">\(title)</rect>"
                }
                cursor = y
            }

            // Counted back from the newest bucket, so the latest one is always
            // labelled and no label is ever squeezed in beside another.
            if (stacks.count - 1 - index) % labelStep == 0 {
                let centre = x + barWidth / 2
                svg += "<text class=\"axis\" x=\"\(fmt(centre))\" y=\"\(fmt(baseline + 16))\" text-anchor=\"middle\">\(escape(range.axisLabel(for: stack.bucket, in: timeZone)))</text>"
            }
        }

        svg += "</svg>"
        return svg
    }

    /// Square at the baseline, 4px rounded at the data end: the fixed bar spec.
    private static func roundedTopPath(x: Double, y: Double, width: Double, height: Double, radius: Double) -> String {
        let r = min(radius, width / 2, height)
        let bottom = y + height
        return "M\(fmt(x)) \(fmt(bottom)) L\(fmt(x)) \(fmt(y + r)) Q\(fmt(x)) \(fmt(y)) \(fmt(x + r)) \(fmt(y)) "
            + "L\(fmt(x + width - r)) \(fmt(y)) Q\(fmt(x + width)) \(fmt(y)) \(fmt(x + width)) \(fmt(y + r)) "
            + "L\(fmt(x + width)) \(fmt(bottom)) Z"
    }

    // MARK: - Horizontal bars

    struct BarRow {
        let name: String
        /// Small grey text after the name: operator, or a page's extra detail.
        let meta: String?
        let value: Int
        /// Right-hand annotation, e.g. "18 verified".
        let note: String?
        let color: String
        /// Rendered as a warning pill, e.g. an agent that ignores robots.txt.
        let flag: String?
        /// Part of `value` to draw in `highlightColor` at the baseline end, so
        /// the split is visible in the mark rather than only in the annotation
        /// beside it. Used for the user-triggered share of a page's traffic.
        let highlight: Int?
        let highlightColor: String?

        init(
            name: String,
            meta: String?,
            value: Int,
            note: String?,
            color: String,
            flag: String?,
            highlight: Int? = nil,
            highlightColor: String? = nil
        ) {
            self.name = name
            self.meta = meta
            self.value = value
            self.note = note
            self.color = color
            self.flag = flag
            self.highlight = highlight
            self.highlightColor = highlightColor
        }
    }

    /// A labelled bar per row, as HTML rather than SVG: it wraps, it stays
    /// readable at phone width, and the number beside every bar doubles as the
    /// table view the light palette's relief rule asks for.
    static func barRows(_ rows: [BarRow]) -> String {
        guard let peak = rows.map(\.value).max(), peak > 0 else { return "" }
        var html = "<div class=\"rows\">"
        for row in rows {
            let share = max(1.5, Double(row.value) / Double(peak) * 100)
            html += "<div class=\"row\"><div class=\"head\"><div class=\"name\">\(escape(row.name))"
            if let meta = row.meta { html += "<span class=\"meta\"> \(escape(meta))</span>" }
            if let flag = row.flag { html += "<span class=\"tag bad\">\(escape(flag))</span>" }
            html += "</div><div class=\"num\">\(grouped(row.value))"
            if let note = row.note { html += "<span class=\"meta\"> \(escape(note))</span>" }
            html += "</div></div>"
            html += "<div class=\"track\"><div class=\"fill\" style=\"width:\(fmt(share))%;background:\(row.color)\">"
            // Two shades of one hue rather than two hues: it is one measure
            // split in two, not two independent series.
            if let highlight = row.highlight, highlight > 0, let color = row.highlightColor {
                let portion = min(100, Double(highlight) / Double(max(row.value, 1)) * 100)
                let isWhole = portion >= 99.5
                html += "<div class=\"seg\(isWhole ? " whole" : "")\" style=\"width:\(fmt(portion))%;background:\(color)\"></div>"
            }
            html += "</div></div>"
            html += "</div>"
        }
        return html + "</div>"
    }

    // MARK: - Formatting

    /// 1,284: grouped by hand rather than through `NumberFormatter`, whose
    /// locale data differs between macOS and Linux.
    static func grouped(_ value: Int) -> String {
        let digits = Array(String(abs(value)))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (value < 0 ? "-" : "") + out
    }

    /// Compact form for the tiles: 1,284 · 12.9K · 1.4M.
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<10_000: return grouped(value)
        case ..<1_000_000: return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        default: return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }

    /// Axis ticks land on 1 / 2 / 5 × 10ⁿ so they read as round numbers.
    static func niceMax(_ peak: Int) -> Int {
        guard peak > 0 else { return 4 }
        if peak <= 4 { return 4 }
        let magnitude = pow(10.0, (log10(Double(peak))).rounded(.down))
        let normalized = Double(peak) / magnitude
        let step: Double
        switch normalized {
        case ..<1.5: step = 1.5
        case ..<2: step = 2
        case ..<4: step = 4
        case ..<5: step = 5
        case ..<8: step = 8
        default: step = 10
        }
        // Rounded up to a multiple of four so the four gridlines land on whole
        // numbers rather than on 3.75, 7.5, 11.25.
        let raw = Int((step * magnitude).rounded(.up))
        return ((raw + 3) / 4) * 4
    }

    /// Trims the trailing zeros SVG numbers do not need.
    private static func fmt(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.2f", rounded)
    }

    /// Everything from the database is escaped before it reaches the raw markup.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
