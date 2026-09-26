import Foundation

/// RFC 4180 CSV, the way spreadsheets read it: comma separated, CRLF line
/// ends, UTF-8, a header line first.
enum BotExportCSV {

    /// Header of a raw export. People lines are quarter-hour counters: `time`
    /// is the quarter-hour's start and `count` its views, and the request
    /// columns are empty. AI lines are one request each, `count` 1.
    static let rawColumns = [
        "time", "audience", "site", "path", "method", "status_code",
        "agent", "operator", "purpose", "verification", "respects_robots_txt",
        "referrer_platform", "count",
    ]

    /// Header of a grouped export: the period, the audience, one or two
    /// columns per chosen dimension, the count.
    static func groupedColumns(_ dimensions: [BotExportDimension]) -> [String] {
        ["period", "period_start", "period_end", "audience"] + dimensions.flatMap(\.columns) + ["count"]
    }

    /// One line, CRLF included.
    static func line(_ fields: [String?]) -> String {
        fields.map(field).joined(separator: ",") + "\r\n"
    }

    /// One field. `nil` is an empty field.
    ///
    /// Paths and agent names come from requests, so a value a spreadsheet
    /// would run as a formula (leading `=`, `+`, `-`, `@`, tab or CR) gets a
    /// leading `'`, which spreadsheets show as text. Values that need it are
    /// then quoted, with quotes doubled.
    static func field(_ value: String?) -> String {
        guard var value, !value.isEmpty else { return "" }
        if let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
            value = "'" + value
        }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                || value.first == " " || value.last == " "
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `2026-09-26T14:00:00+02:00`: local wall-clock time with its offset,
    /// unambiguous across a DST change and readable as local time.
    /// `DateFormatter`, never `Date.formatted`, which is incomplete on Linux.
    static func timestampFormatter(in timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter
    }

    /// `2026-09-26` in `timeZone`.
    static func dayFormatter(in timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
