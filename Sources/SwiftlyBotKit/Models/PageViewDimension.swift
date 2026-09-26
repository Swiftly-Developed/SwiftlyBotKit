import Foundation

/// One way a page view can be broken down, beyond its site, path and time.
///
/// Every value is coarse by construction: a country code, a browser family, a
/// referring host, a campaign token. Each one is shared by many readers, and
/// none is kept together with more than one other (see ``pairs``), so a stored
/// count never describes a single person.
///
/// The raw values are the `dimension` column of `page_view_dimension_counts`
/// and `page_view_pair_counts`, so they are frozen once released. Declaration
/// order is the order pairs are stored in: the first of a pair is always the
/// one declared first.
public enum PageViewDimension: String, CaseIterable, Sendable, Codable, Comparable {
    /// ISO 3166-1 alpha-2 country, from the IP address, `ZZ` when unknown.
    case country
    /// The referring host, `(direct)` or `(internal)`.
    case referrer
    /// The page on the same site the reader came from, `(none)` otherwise.
    case previousPage = "previous_page"
    /// `utm_source`, `(none)` when absent.
    case campaignSource = "utm_source"
    /// `utm_medium`, `(none)` when absent.
    case campaignMedium = "utm_medium"
    /// `utm_campaign`, `(none)` when absent.
    case campaignName = "utm_campaign"
    /// `utm_content`, `(none)` when absent.
    case campaignContent = "utm_content"
    /// `mobile`, `tablet` or `desktop`.
    case device
    /// Browser family, such as `Safari`.
    case browser
    /// Browser family and major version, such as `Safari 18`.
    case browserVersion = "browser_version"
    /// Operating system family, such as `iOS`.
    case os
    /// Operating system and major version where the user agent tells it
    /// honestly, such as `iOS 18`; the family alone otherwise.
    case osVersion = "os_version"
    /// Primary language subtag of the first `Accept-Language` entry, such as
    /// `nl`.
    case language

    /// A short name for the dashboard and exports.
    public var label: String {
        switch self {
        case .country: return "Country"
        case .referrer: return "Referrer"
        case .previousPage: return "Previous page"
        case .campaignSource: return "Campaign source"
        case .campaignMedium: return "Campaign medium"
        case .campaignName: return "Campaign name"
        case .campaignContent: return "Campaign content"
        case .device: return "Device type"
        case .browser: return "Browser"
        case .browserVersion: return "Browser version"
        case .os: return "Operating system"
        case .osVersion: return "OS version"
        case .language: return "Language"
        }
    }

    /// Whether this dimension is crossed with the others in
    /// `page_view_pair_counts`. The previous page is not: it is a path, and
    /// is only ever stored against the page it led to.
    public var isPairable: Bool { self != .previousPage }

    /// Every pair stored in `page_view_pair_counts`, first before second in
    /// declaration order.
    ///
    /// A version is not paired with its own family (`Safari 18` already says
    /// Safari), and the previous page is left out (``isPairable``). No row
    /// ever holds three of these dimensions.
    public static let pairs: [(PageViewDimension, PageViewDimension)] = {
        let pairable = allCases.filter(\.isPairable)
        var pairs: [(PageViewDimension, PageViewDimension)] = []
        for (index, first) in pairable.enumerated() {
            for second in pairable[(index + 1)...] where !isRedundant(first, second) {
                pairs.append((first, second))
            }
        }
        return pairs
    }()

    private static func isRedundant(_ first: PageViewDimension, _ second: PageViewDimension) -> Bool {
        switch (first, second) {
        case (.browser, .browserVersion), (.os, .osVersion): return true
        default: return false
        }
    }

    /// Whether `first` and `second` are stored together, in either order.
    public static func isPair(_ first: PageViewDimension, _ second: PageViewDimension) -> Bool {
        let (a, b) = first < second ? (first, second) : (second, first)
        return pairs.contains { $0 == a && $1 == b }
    }

    public static func < (lhs: PageViewDimension, rhs: PageViewDimension) -> Bool {
        order[lhs]! < order[rhs]!
    }

    private static let order: [PageViewDimension: Int] = Dictionary(
        uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) }
    )

    /// The value stored when a dimension has nothing to say about a view:
    /// no campaign, no previous page, no language.
    public static let none = "(none)"
    /// The value stored for something present but not storable: a campaign
    /// token with characters outside the allowed set, an IP-address referrer.
    public static let other = "(other)"
}
