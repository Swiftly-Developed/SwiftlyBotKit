// Regenerates Sources/SwiftlyBotKit/Configuration/BotKitTimeZone.swift from
// the IANA tz database: one enum case per canonical zone, one deprecated
// alias per legacy name.
//
// Usage, from the package root:
//
//     swift Scripts/generate-time-zones.swift [path/to/zoneinfo]
//
// The zoneinfo directory defaults to /usr/share/zoneinfo, which on macOS
// ships both files this script reads:
//
// - `zone.tab`: the canonical zones, one line per country region. This is
//   the case list. It holds `Asia/Kolkata`, `Europe/Kyiv` and `America/Nuuk`,
//   never their legacy spellings, and it keeps a name such as
//   `Europe/Amsterdam` that tzdata now implements as a link, because it is
//   still the name people look for.
// - `tzdata.zi`: the compiled source. Its `L target name` lines are the links,
//   used to map legacy names (`Asia/Calcutta`, `US/Eastern`) to the case they
//   now mean.
//
// Why not `TimeZone.knownTimeZoneIdentifiers`: it mixes canonical and legacy
// names, and Debian-based PostgreSQL images, like other slimmed-down tz
// installs, drop the legacy ones.
//
// Case names are derived from the identifier alone, so a case never changes
// name between runs. A legacy name that was once a case stays as a
// deprecated static alias; removing one is a source-breaking change.

import Foundation

let zoneinfo = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/usr/share/zoneinfo"

func read(_ name: String) -> String {
    let path = (zoneinfo as NSString).appendingPathComponent(name)
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fatalError("Cannot read \(path). Pass the zoneinfo directory as the first argument.")
    }
    return text
}

/// `America/Port-au-Prince` becomes `americaPortAuPrince`.
func caseName(for identifier: String) -> String {
    let words = identifier
        .split(whereSeparator: { "/_-".contains($0) })
        .map(String.init)
    return words.enumerated().map { index, word in
        index == 0
            ? word.prefix(1).lowercased() + word.dropFirst()
            : word.prefix(1).uppercased() + word.dropFirst()
    }.joined()
}

// MARK: - Canonical zones

let zoneTab = read("zone.tab")
let identifiers = Set(
    zoneTab.split(separator: "\n")
        .filter { !$0.hasPrefix("#") }
        .compactMap { line -> String? in
            let columns = line.split(separator: "\t")
            return columns.count >= 3 ? String(columns[2]) : nil
        }
).sorted()

guard identifiers.count > 300 else {
    fatalError("zone.tab lists only \(identifiers.count) zones; is \(zoneinfo) complete?")
}

let tzdataVersion = read("tzdata.zi")
    .split(separator: "\n").first
    .map { $0.replacingOccurrences(of: "# version ", with: "") } ?? "unknown"

var seen: [String: String] = [:]
for identifier in identifiers {
    let name = caseName(for: identifier)
    if let clash = seen[name] {
        fatalError("\(identifier) and \(clash) both map to .\(name)")
    }
    seen[name] = identifier
}

// MARK: - Legacy names

var links: [String: String] = [:]
for line in read("tzdata.zi").split(separator: "\n") where line.hasPrefix("L ") {
    let parts = line.split(separator: " ")
    guard parts.count == 3 else { continue }
    links[String(parts[2])] = String(parts[1])
}

/// Renames the `backward` file spells out but `tzdata.zi` flattens into links
/// to a same-rules zone in another country: `Pacific/Ponape` is a link to
/// `Pacific/Guadalcanal` there, yet it is the old spelling of the
/// `Pacific/Pohnpei` case. The rules are identical either way; this only
/// keeps the alias pointing at the name a reader expects.
let renamedInBackward: [String: String] = [
    "Africa/Asmera": "Africa/Asmara",
    "America/Coral_Harbour": "America/Atikokan",
    "Antarctica/South_Pole": "Antarctica/McMurdo",
    "Atlantic/Jan_Mayen": "Arctic/Longyearbyen",
    "Iceland": "Atlantic/Reykjavik",
    "Pacific/Ponape": "Pacific/Pohnpei",
    "Pacific/Truk": "Pacific/Chuuk",
    "Pacific/Yap": "Pacific/Chuuk",
]

/// Follows links until a canonical zone, `UTC`, or nothing.
func canonical(for name: String) -> String? {
    if let renamed = renamedInBackward[name], identifiers.contains(renamed) { return renamed }
    var current = name
    for _ in 0..<8 {
        if identifiers.contains(current) { return current }
        if ["Etc/UTC", "Etc/GMT", "UTC", "GMT"].contains(current) { return "UTC" }
        guard let next = links[current] else { return nil }
        current = next
    }
    return nil
}

/// Every link that is not itself a case, mapped to the case it means, plus
/// the two zones `.utc` stands for.
let legacy: [(name: String, target: String)] = (Array(links.keys) + ["Etc/UTC", "Etc/GMT"])
    .filter { !identifiers.contains($0) }
    .compactMap { name in canonical(for: name).map { (name, $0) } }
    .sorted { $0.name < $1.name }

/// Legacy names Foundation lists as known zones get a deprecated static
/// alias, because they were cases before the list became canonical. Names
/// such as `US/Eastern` only resolve through `init(identifier:)`.
let foundationNames = Set(TimeZone.knownTimeZoneIdentifiers)
let aliases = legacy.filter { entry in
    entry.name.contains("/") && foundationNames.contains(entry.name) && entry.target != "UTC"
}
for alias in aliases {
    let name = caseName(for: alias.name)
    if let clash = seen[name] {
        fatalError("alias \(alias.name) and \(clash) both map to .\(name)")
    }
    seen[name] = alias.name
}

func reference(to identifier: String) -> String {
    identifier == "UTC" ? ".utc" : ".\(caseName(for: identifier))"
}

// MARK: - Output

let grouped = Dictionary(grouping: identifiers) { String($0.split(separator: "/")[0]) }

var out = """
// GENERATED by Scripts/generate-time-zones.swift from tzdata \(tzdataVersion). Do not hand-edit.
// \(identifiers.count) canonical zones, plus `.utc` and `.custom`; \(aliases.count) deprecated aliases.

import Foundation

/// The time zone the dashboard draws its hourly and daily buckets in.
///
/// One case per canonical IANA time zone (the `zone.tab` list), named after
/// its identifier, so the zone is picked from autocomplete instead of typed as
/// a string:
///
/// ```swift
/// config.dashboard.timeZone = .americaNewYork
/// config.dashboard.timeZone = .europeBrussels
/// config.dashboard.timeZone = .asiaTokyo
/// ```
///
/// Legacy spellings such as `.asiaCalcutta` or `.europeKiev` remain as
/// deprecated aliases of the canonical case (`.asiaKolkata`, `.europeKyiv`),
/// and ``init(identifier:)`` maps any legacy name to its canonical case.
///
/// All bucket arithmetic happens in Swift, with Foundation's rules for the
/// zone; PostgreSQL is never handed the zone name. So ``custom(_:)`` also
/// accepts a fixed-offset zone such as `TimeZone(secondsFromGMT: 3600)`: it
/// buckets correctly, it just never observes daylight saving time.
///
/// A zone newer than the host's tz database (for example `America/Coyhaique`
/// on an older Linux image) cannot be resolved by Foundation. Its
/// ``foundationTimeZone`` is then UTC, and ``isAvailable`` is `false`.
public enum BotKitTimeZone: Hashable, Sendable {

    /// Coordinated Universal Time. The package default.
    case utc

    /// Any Foundation time zone: a zone this list does not have yet, or a
    /// fixed offset such as `TimeZone(secondsFromGMT: 3600)`. Prefer a named
    /// case for a real place, so daylight saving time is followed.
    case custom(TimeZone)

"""

for region in grouped.keys.sorted() {
    out += "    // MARK: \(region)\n\n"
    for identifier in grouped[region]! {
        out += "    /// `\(identifier)`\n"
        out += "    case \(caseName(for: identifier))\n"
    }
    out += "\n"
}

out += "    // MARK: Deprecated aliases\n\n"
for alias in aliases {
    out += "    /// `\(alias.name)`, a legacy name for `\(alias.target)`.\n"
    out += "    @available(*, deprecated, renamed: \"\(caseName(for: alias.target))\")\n"
    out += "    public static let \(caseName(for: alias.name)): BotKitTimeZone = \(reference(to: alias.target))\n"
}
out += "\n"

out += """
    /// Every named case, `.utc` first, then alphabetically by identifier.
    /// ``custom(_:)`` and the deprecated aliases are not included.
    public static let allNamed: [BotKitTimeZone] = [
        .utc,

"""
for identifier in identifiers {
    out += "        .\(caseName(for: identifier)),\n"
}
out += """
    ]

    /// Legacy and backward-compatible names, mapped to the case they mean.
    static let legacyIdentifiers: [String: BotKitTimeZone] = [

"""
for entry in legacy {
    out += "        \"\(entry.name)\": \(reference(to: entry.target)),\n"
}
out += """
    ]

    /// The IANA identifier, for example `America/New_York`. For
    /// ``custom(_:)``, whatever Foundation calls the zone, e.g. `GMT+0100`.
    public var identifier: String {
        switch self {
        case .utc: return "UTC"
        case .custom(let timeZone): return timeZone.identifier

"""
for identifier in identifiers {
    out += "        case .\(caseName(for: identifier)): return \"\(identifier)\"\n"
}
out += """
        }
    }
}

"""

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let packageRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let target = packageRoot
    .appendingPathComponent("Sources/SwiftlyBotKit/Configuration/BotKitTimeZone.swift")
try out.write(to: target, atomically: true, encoding: .utf8)
print("Wrote \(identifiers.count) zones, \(aliases.count) deprecated aliases and \(legacy.count) legacy names (tzdata \(tzdataVersion)) to \(target.path)")
print("Aliases: " + aliases.map { "\($0.name) -> \($0.target)" }.joined(separator: ", "))
