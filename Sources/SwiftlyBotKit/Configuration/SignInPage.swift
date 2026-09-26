import Foundation

extension BotKitConfiguration {

    /// How the dashboard's sign-in page looks: the logo above the form and
    /// its colours.
    ///
    /// ```swift
    /// config.dashboard.signInPage.logo = .image(url: "/images/logo.png", altText: "Acme")
    /// config.dashboard.signInPage.colors = .init(background: "#0B1020", button: "#6366F1")
    /// ```
    ///
    /// The dashboard is mounted on every host the app answers for, so a
    /// multi-site app can give each site its own logo, picked by the key
    /// ``BotKitConfiguration/siteKey`` returns for the sign-in request:
    ///
    /// ```swift
    /// config.dashboard.signInPage.siteLogos = [
    ///     "shop": .image(url: "/images/shop.png", darkURL: "/images/shop-dark.png"),
    ///     "docs": .image(url: "/images/docs.svg"),
    /// ]
    /// ```
    ///
    /// Colours and the logo URL are written into the page, so they are checked
    /// when BotKit is installed, and an unusable one makes
    /// `BotKit.configureRoutes(for:config:)` throw rather than render.
    public struct SignInPage: Sendable, Equatable {

        /// The SwiftlyBotKit logo, the dashboard's own colours.
        public static let `default` = SignInPage()

        /// The logo above the form, on any site without an entry in
        /// ``siteLogos``. Default ``SignInLogo/swiftlyBotKit``.
        public var logo: SignInLogo

        /// A logo per site, keyed by what ``BotKitConfiguration/siteKey``
        /// returns for the request, used in place of ``logo`` on that site.
        /// With ``BotKitConfiguration/sites`` configured, every key must be
        /// one of theirs. Default: none.
        public var siteLogos: [String: SignInLogo]

        /// Colours for the page. Every one left `nil` keeps the dashboard's
        /// own. Applied in light and dark mode alike, unless ``darkColors``
        /// is set. Default: none.
        public var colors: SignInColors

        /// Colours for dark mode only, when the visitor's system is dark.
        /// `nil` means ``colors`` is used in both modes. Default `nil`.
        public var darkColors: SignInColors?

        /// Creates a sign-in page configuration.
        public init(
            logo: SignInLogo = .swiftlyBotKit,
            siteLogos: [String: SignInLogo] = [:],
            colors: SignInColors = .init(),
            darkColors: SignInColors? = nil
        ) {
            self.logo = logo
            self.siteLogos = siteLogos
            self.colors = colors
            self.darkColors = darkColors
        }
    }
}

/// The logo shown above the sign-in form.
public enum SignInLogo: Sendable, Equatable {
    /// The SwiftlyBotKit logo, embedded in the page, so nothing has to be
    /// hosted. The default.
    case swiftlyBotKit
    /// Your own image: a root-relative path served by the app (such as
    /// `/images/logo.png`), an absolute `https` or `http` URL, or a
    /// `data:image/` URL. An absolute URL's origin is added to the page's
    /// `Content-Security-Policy`. Shown at most 64 points tall. `altText`
    /// defaults to the site's ``BotDashboardSite/name``, or the dashboard
    /// title. `darkURL`, in the same forms, replaces `url` when the
    /// visitor's system is in dark mode.
    case image(url: String, altText: String? = nil, darkURL: String? = nil)
    /// No logo.
    case none
}

/// Colours for the sign-in page. Each is a CSS colour, such as `#6366F1`,
/// `rgb(99 102 241)` or `white`; `nil` keeps the dashboard's own.
///
/// Only letters, digits, spaces and `# ( ) , . % / -` are accepted, which
/// covers hex, named and functional colours and rules out anything that could
/// break out of the stylesheet.
public struct SignInColors: Sendable, Equatable {
    /// The page behind the card.
    public var background: String?
    /// The card holding the form.
    public var card: String?
    /// Headings, labels and typed text.
    public var text: String?
    /// The line under the heading.
    public var secondaryText: String?
    /// The card's and the fields' outline.
    public var border: String?
    /// The sign-in button.
    public var button: String?
    /// The sign-in button's label.
    public var buttonText: String?

    /// Creates a colour set. Leave out what should stay as it is.
    public init(
        background: String? = nil,
        card: String? = nil,
        text: String? = nil,
        secondaryText: String? = nil,
        border: String? = nil,
        button: String? = nil,
        buttonText: String? = nil
    ) {
        self.background = background
        self.card = card
        self.text = text
        self.secondaryText = secondaryText
        self.border = border
        self.button = button
        self.buttonText = buttonText
    }

    /// Each set colour with the CSS variable it overrides, in a fixed order.
    var declarations: [(variable: String, value: String, name: String)] {
        [
            ("--page", background, "background"),
            ("--surface-1", card, "card"),
            ("--text-primary", text, "text"),
            ("--text-secondary", secondaryText, "secondaryText"),
            ("--border", border, "border"),
            ("--signin-button", button, "button"),
            ("--signin-button-text", buttonText, "buttonText"),
        ].compactMap { variable, value, name in
            value.map { (variable, $0.trimmingCharacters(in: .whitespacesAndNewlines), name) }
        }
    }

    var isEmpty: Bool { declarations.isEmpty }

    /// `--page:#fff;--surface-1:#eee`, for a rule body.
    var css: String {
        declarations.map { "\($0.variable):\($0.value)" }.joined(separator: ";")
    }
}

extension BotKitConfiguration.SignInPage {

    private static let colorCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#(),.%/- ".unicodeScalars
    )

    func validate() throws {
        for set in [colors] + (darkColors.map { [$0] } ?? []) {
            for declaration in set.declarations {
                let value = declaration.value
                guard !value.isEmpty, value.count <= 64,
                      value.unicodeScalars.allSatisfy({ Self.colorCharacters.contains($0) }),
                      !value.contains("/*")
                else {
                    throw BotKitConfigurationError.invalidSignInColor(declaration.name, value)
                }
            }
        }
        for logo in allLogos {
            guard case .image(let url, _, let darkURL) = logo else { continue }
            for url in [url] + (darkURL.map { [$0] } ?? []) where !Self.logoURLIsUsable(url) {
                throw BotKitConfigurationError.invalidSignInLogo(url)
            }
        }
    }

    /// The logo for a sign-in on the site with this key.
    func logo(forSite key: String?) -> SignInLogo {
        key.flatMap { siteLogos[$0] } ?? logo
    }

    /// ``logo`` and every site's, sites in key order.
    private var allLogos: [SignInLogo] {
        [logo] + siteLogos.sorted { $0.key < $1.key }.map(\.value)
    }

    /// A root-relative path, an absolute http(s) URL, or a `data:image/` URL,
    /// with nothing that could end the attribute it is written into.
    static func logoURLIsUsable(_ url: String) -> Bool {
        guard !url.isEmpty, url.count <= 100_000,
              !url.contains(where: { $0 == "\"" || $0 == "'" || $0 == "<" || $0 == ">" || $0 == "`" || $0.isWhitespace || $0 == "\\" })
        else { return false }
        if url.hasPrefix("data:image/") { return true }
        if url.hasPrefix("/") { return !url.hasPrefix("//") }
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    /// Every logo URL that is absolute, light and dark, for `img-src`.
    var absoluteLogoURLs: [String] {
        allLogos.flatMap { logo -> [String] in
            guard case .image(let url, _, let darkURL) = logo else { return [] }
            return ([url] + (darkURL.map { [$0] } ?? [])).filter { !$0.hasPrefix("/") && !$0.hasPrefix("data:") }
        }
    }
}
