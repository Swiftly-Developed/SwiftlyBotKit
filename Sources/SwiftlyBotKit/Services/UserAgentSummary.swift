import Foundation
import Vapor

/// Device type, browser and operating system, read from the user agent and
/// the low-entropy client hints every Chromium browser sends by default.
///
/// Families come from closed lists and versions are a major number at most,
/// so the result adds no fingerprinting detail. High-entropy hints
/// (`Sec-CH-UA-Platform-Version`, `Sec-CH-UA-Model`, ...) are never asked
/// for with `Accept-CH`, and are ignored if a browser sends them anyway.
///
/// The rules are ordered: most browsers claim to be several others (Edge's
/// user agent says Chrome and Safari too), so the most specific token wins.
struct UserAgentSummary: Equatable {

    enum Device: String, CaseIterable {
        case mobile, tablet, desktop
    }

    static let otherFamily = "Other"

    let device: Device
    let browser: String
    let browserVersion: String
    let os: String
    let osVersion: String

    init(headers: HTTPHeaders) {
        self.init(
            userAgent: headers.first(name: .userAgent) ?? "",
            clientHintBrands: headers.first(name: "Sec-CH-UA"),
            clientHintMobile: headers.first(name: "Sec-CH-UA-Mobile")
        )
    }

    init(userAgent: String, clientHintBrands: String? = nil, clientHintMobile: String? = nil) {
        let ua = userAgent.lowercased()
        let (browser, major) = Self.browser(in: ua, brands: clientHintBrands?.lowercased())
        self.browser = browser
        self.browserVersion = major.map { "\(browser) \($0)" } ?? browser
        let (os, osMajor) = Self.os(in: ua)
        self.os = os
        self.osVersion = osMajor.map { "\(os) \($0)" } ?? os
        self.device = Self.device(in: ua, os: os, mobileHint: clientHintMobile)
    }

    // MARK: Browser

    /// (marker in the lowercased user agent, family, version marker or nil)
    /// in the order they are tried.
    private static let browserRules: [(marker: String, family: String, version: String?)] = [
        ("edg/", "Edge", "edg/"),
        ("edga/", "Edge", "edga/"),
        ("edgios/", "Edge", "edgios/"),
        ("opr/", "Opera", "opr/"),
        ("opios/", "Opera", "opios/"),
        ("opera", "Opera", "version/"),
        ("samsungbrowser/", "Samsung Internet", "samsungbrowser/"),
        ("yabrowser/", "Yandex", "yabrowser/"),
        ("vivaldi/", "Vivaldi", "vivaldi/"),
        ("ucbrowser/", "UC Browser", "ucbrowser/"),
        ("duckduckgo/", "DuckDuckGo", "duckduckgo/"),
        ("ddg/", "DuckDuckGo", "ddg/"),
        ("fban/", "Facebook", nil),
        ("fbav/", "Facebook", nil),
        ("instagram", "Instagram", nil),
        ("linkedinapp", "LinkedIn", nil),
        ("fxios/", "Firefox", "fxios/"),
        ("firefox/", "Firefox", "firefox/"),
        ("crios/", "Chrome", "crios/"),
        ("chromium/", "Chromium", "chromium/"),
        ("chrome/", "Chrome", "chrome/"),
        ("trident/", "Internet Explorer", nil),
        ("msie ", "Internet Explorer", "msie "),
    ]

    private static func browser(in ua: String, brands: String?) -> (String, Int?) {
        // Brave hides in its user agent but names itself in the brand list.
        if let brands, brands.contains("\"brave\"") {
            return ("Brave", brandVersion(in: brands, brand: "\"brave\""))
        }
        for rule in browserRules where ua.contains(rule.marker) {
            return (rule.family, rule.version.flatMap { majorVersion(in: ua, after: $0) })
        }
        if ua.contains("safari/") && ua.contains("version/") {
            return ("Safari", majorVersion(in: ua, after: "version/"))
        }
        // An app's embedded web view on iOS: WebKit, no Safari token.
        if ua.contains("applewebkit/") && (ua.contains("iphone") || ua.contains("ipad")) {
            return ("iOS web view", nil)
        }
        if ua.contains("; wv)") {
            return ("Android web view", nil)
        }
        return (otherFamily, nil)
    }

    /// The major version in `"brave";v="128"`.
    private static func brandVersion(in brands: String, brand: String) -> Int? {
        guard let range = brands.range(of: brand) else { return nil }
        return majorVersion(in: String(brands[range.upperBound...]), after: "v=\"")
    }

    /// The integer right after `marker`, up to the first non-digit, capped at
    /// four digits so a garbage token cannot become a large number.
    static func majorVersion(in text: String, after marker: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        return Int(digits)
    }

    // MARK: Operating system

    private static func os(in ua: String) -> (String, Int?) {
        if ua.contains("ipad") {
            return ("iPadOS", majorVersion(in: ua, after: "cpu os "))
        }
        if ua.contains("iphone") || ua.contains("ipod") {
            return ("iOS", majorVersion(in: ua, after: "iphone os "))
        }
        if ua.contains("android") {
            // Chrome's reduced user agent reports every phone as
            // `Android 10; K`, so that version means nothing.
            if ua.contains("android 10; k)") { return ("Android", nil) }
            return ("Android", majorVersion(in: ua, after: "android "))
        }
        if ua.contains("windows phone") { return ("Windows Phone", nil) }
        // Windows 10 and 11 both say `Windows NT 10.0`; macOS has said
        // `10_15_7` since 2020. Neither version is worth storing.
        if ua.contains("windows") { return ("Windows", nil) }
        if ua.contains("cros ") { return ("ChromeOS", nil) }
        if ua.contains("mac os x") || ua.contains("macintosh") { return ("macOS", nil) }
        if ua.contains("linux") || ua.contains("x11") { return ("Linux", nil) }
        return (otherFamily, nil)
    }

    // MARK: Device

    private static func device(in ua: String, os: String, mobileHint: String?) -> Device {
        if mobileHint == "?1" { return .mobile }
        if os == "iPadOS" || ua.contains("tablet") || ua.contains("kindle") || ua.contains("silk/") {
            return .tablet
        }
        // Android phones say `Mobile`; Android tablets do not.
        if os == "Android" { return ua.contains("mobile") ? .mobile : .tablet }
        if os == "iOS" || os == "Windows Phone" || ua.contains("mobi") { return .mobile }
        return .desktop
    }
}
