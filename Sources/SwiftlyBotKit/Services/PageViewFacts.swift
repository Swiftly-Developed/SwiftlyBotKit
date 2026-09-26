import Foundation
import Vapor

/// The coarse facts about one page view that ``PageViewDimension`` breaks
/// counts down by.
///
/// Built by ``derive(headers:query:host:clientIP:countries:)``, the only code
/// that reads the IP address, `Referer`, user agent, `Accept-Language` and
/// query string for page views. What comes out is a value per dimension drawn
/// from a closed list (country codes, device classes, browser families) or
/// normalised and capped (hosts, campaign tokens), and nothing else: the raw
/// headers and the address are never stored in it, so they go out of scope
/// with the request.
struct PageViewFacts: Sendable, Equatable {

    /// One value per recorded dimension, in ``PageViewDimension`` declaration
    /// order. The country is absent when no country database is loaded.
    private(set) var values: [(dimension: PageViewDimension, value: String)]

    init(_ values: [(PageViewDimension, String)]) {
        self.values = values
            .sorted { $0.0 < $1.0 }
            .map { (dimension: $0.0, value: $0.1) }
    }

    subscript(dimension: PageViewDimension) -> String? {
        values.first { $0.dimension == dimension }?.value
    }

    /// Replaces one value, used to cap campaign tokens.
    mutating func set(_ dimension: PageViewDimension, to value: String) {
        guard let index = values.firstIndex(where: { $0.dimension == dimension }) else { return }
        values[index].value = value
    }

    static func == (lhs: PageViewFacts, rhs: PageViewFacts) -> Bool {
        lhs.values.elementsEqual(rhs.values) { $0.dimension == $1.dimension && $0.value == $1.value }
    }

    /// The facts for one request.
    ///
    /// - Parameters:
    ///   - headers: the request headers.
    ///   - query: the raw query string, if any.
    ///   - host: the `Host` the request was made to, to tell a link from
    ///     another page of the same site from an outside referrer.
    ///   - clientIP: the client address under the configured
    ///     ``ClientIPStrategy``. Only looked up, never kept.
    ///   - countries: the country table, or `nil` to leave the country out.
    static func derive(
        headers: HTTPHeaders,
        query: String?,
        host: String?,
        clientIP: String?,
        countries: CountryLookup?
    ) -> PageViewFacts {
        var values: [(PageViewDimension, String)] = []
        values.reserveCapacity(PageViewDimension.allCases.count)
        if let countries {
            values.append((.country, countries.country(for: clientIP)))
        }
        let referrer = ReferrerSummary(referer: headers.first(name: .referer), host: host)
        values.append((.referrer, referrer.referrer))
        values.append((.previousPage, referrer.previousPage))
        let campaign = CampaignSummary(query: query)
        values.append((.campaignSource, campaign.source))
        values.append((.campaignMedium, campaign.medium))
        values.append((.campaignName, campaign.name))
        values.append((.campaignContent, campaign.content))
        let agent = UserAgentSummary(headers: headers)
        values.append((.device, agent.device.rawValue))
        values.append((.browser, agent.browser))
        values.append((.browserVersion, agent.browserVersion))
        values.append((.os, agent.os))
        values.append((.osVersion, agent.osVersion))
        values.append((.language, LanguageSummary.language(acceptLanguage: headers.first(name: .acceptLanguage))))
        return PageViewFacts(values)
    }
}

// MARK: - Referrer

/// Where a reader came from: a host, another page of the same site, or
/// nowhere.
///
/// Only the host of an outside referrer is kept, never its path or query,
/// which can carry search terms, emails or session tokens. An address given
/// as an IP literal is stored as ``PageViewDimension/other``, since it can
/// be someone's own machine.
struct ReferrerSummary: Equatable {
    static let direct = "(direct)"
    static let `internal` = "(internal)"
    /// Longest previous-page path kept; a longer one is cut.
    static let maximumPathLength = 200
    /// Longest referring host kept; a longer one is stored as `(other)`.
    static let maximumHostLength = 100

    let referrer: String
    let previousPage: String

    init(referer: String?, host: String?) {
        guard let referer = referer?.trimmingCharacters(in: .whitespaces), !referer.isEmpty else {
            self.init(referrer: Self.direct, previousPage: PageViewDimension.none)
            return
        }
        let url = URL(string: referer)
        if let url, url.scheme?.lowercased() == "android-app" {
            let package = url.host.map(Self.cleanHost) ?? nil
            self.init(referrer: package.map { "android-app://\($0)" } ?? PageViewDimension.other,
                      previousPage: PageViewDimension.none)
            return
        }
        guard let rawHost = url?.host, !rawHost.isEmpty, let scheme = url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            self.init(referrer: PageViewDimension.other, previousPage: PageViewDimension.none)
            return
        }
        guard let refererHost = Self.cleanHost(rawHost) else {
            self.init(referrer: PageViewDimension.other, previousPage: PageViewDimension.none)
            return
        }
        if let host = host.flatMap(Self.requestHost), Self.withoutWWW(host) == Self.withoutWWW(refererHost) {
            self.init(referrer: Self.internal, previousPage: Self.path(of: referer))
            return
        }
        self.init(referrer: Self.shortened(refererHost), previousPage: PageViewDimension.none)
    }

    private init(referrer: String, previousPage: String) {
        self.referrer = referrer
        self.previousPage = previousPage
    }

    /// A lowercased hostname of letters, digits, dots and hyphens, or `nil`
    /// for an IP literal or anything else.
    static func cleanHost(_ host: String) -> String? {
        var host = Substring(host.lowercased())
        while host.hasSuffix(".") { host = host.dropLast() }
        guard !host.isEmpty, host.utf8.count <= maximumHostLength,
              host.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D }),
              !host.hasPrefix("."), !host.contains("..")
        else { return nil }
        // Digits and dots only is an IPv4 address (IPv6 never passes the
        // character check, it needs colons or brackets).
        if host.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }) { return nil }
        return String(host)
    }

    /// The request's `Host` without a port.
    static func requestHost(_ host: String) -> String? {
        let bare = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        return cleanHost(bare)
    }

    private static func withoutWWW(_ host: String) -> Substring {
        host.hasPrefix("www.") ? host.dropFirst(4) : Substring(host)
    }

    /// Mobile and link-shim subdomains that say nothing about the source:
    /// `m.facebook.com` and `l.facebook.com` are Facebook. Dropped only when
    /// what is left still has a dot, so `m.example` stays whole.
    private static let dropPrefixes = ["www.", "m.", "l.", "lm.", "mobile.", "amp."]

    static func shortened(_ host: String) -> String {
        var host = Substring(host)
        var changed = true
        while changed {
            changed = false
            for prefix in dropPrefixes where host.hasPrefix(prefix) {
                let rest = host.dropFirst(prefix.count)
                if rest.contains(".") {
                    host = rest
                    changed = true
                }
            }
        }
        return String(host)
    }

    /// The path of a same-site referrer: no query or fragment, repeated
    /// slashes collapsed, capped at ``maximumPathLength`` characters.
    /// `URLComponents` rather than `URL.path`, which drops the trailing slash
    /// every page on these sites ends with.
    private static func path(of referer: String) -> String {
        var path = URLComponents(string: referer)?.path ?? ""
        if path.isEmpty { path = "/" }
        path = BotRequestClassifier.collapsingRepeatedSlashes(path)
        guard path.hasPrefix("/") else { return PageViewDimension.other }
        return String(path.prefix(maximumPathLength))
    }
}

// MARK: - Campaign

/// The four `utm_` parameters that describe a campaign, sanitised.
///
/// A token is kept only when it is made of lowercase letters, digits, `.`,
/// `_` and `-` (spaces and `+` become `-`), is at most 64 characters, and has
/// no run of six or more digits, which is how phone numbers and account ids
/// look. Anything else is stored as ``PageViewDimension/other`` rather than
/// cleaned up, so an email address in a campaign link never survives in part.
/// `utm_term` is not read at all: for paid search it holds the visitor's own
/// query.
struct CampaignSummary: Equatable {
    static let maximumLength = 64

    let source: String
    let medium: String
    let name: String
    let content: String

    init(query: String?) {
        var found: [String: String] = [:]
        if let query, !query.isEmpty {
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = parts[0].lowercased()
                guard ["utm_source", "utm_medium", "utm_campaign", "utm_content"].contains(key),
                      found[key] == nil
                else { continue }
                let raw = parts.count > 1 ? String(parts[1]) : ""
                found[key] = Self.token(raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "\u{0}")
            }
        }
        source = found["utm_source"] ?? PageViewDimension.none
        medium = found["utm_medium"] ?? PageViewDimension.none
        name = found["utm_campaign"] ?? PageViewDimension.none
        content = found["utm_content"] ?? PageViewDimension.none
    }

    /// A storable campaign token, ``PageViewDimension/none`` for an empty
    /// value, or ``PageViewDimension/other``.
    static func token(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
        guard !value.isEmpty else { return PageViewDimension.none }
        guard value.utf8.count <= maximumLength else { return PageViewDimension.other }
        var digitRun = 0
        for byte in value.utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let allowed = isDigit || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2E || byte == 0x5F || byte == 0x2D
            guard allowed else { return PageViewDimension.other }
            digitRun = isDigit ? digitRun + 1 : 0
            if digitRun >= 6 { return PageViewDimension.other }
        }
        return value
    }
}

// MARK: - Language

/// The reader's preferred language, as a primary subtag.
enum LanguageSummary {
    /// The primary subtag of the first `Accept-Language` entry, lowercased:
    /// `nl-BE,nl;q=0.9,en;q=0.8` is `nl`. Two letters (ISO 639-1) only; a
    /// three-letter or malformed tag is ``PageViewDimension/other``, and a
    /// missing header or `*` is ``PageViewDimension/none``.
    static func language(acceptLanguage: String?) -> String {
        guard let first = acceptLanguage?.split(separator: ",").first else { return PageViewDimension.none }
        let tag = first.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !tag.isEmpty, tag != "*" else { return PageViewDimension.none }
        let primary = tag.split(separator: "-").first.map { $0.lowercased() } ?? ""
        guard primary.utf8.count == 2, primary.utf8.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else {
            return PageViewDimension.other
        }
        return primary
    }
}
