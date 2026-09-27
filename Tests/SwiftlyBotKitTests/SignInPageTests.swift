import XCTest
import XCTVapor
@testable import SwiftlyBotKit

final class SignInPageTests: XCTestCase {

    private func page(_ signIn: BotKitConfiguration.SignInPage) -> String {
        var options = BotKitConfiguration.Dashboard.default
        options.signInPage = signIn
        return LoginPage.render(error: nil, options: options)
    }

    func testDefaultIsTheSwiftlyBotKitLogoAndTheDashboardColours() {
        XCTAssertEqual(BotKitConfiguration.Dashboard.default.signInPage, .default)
        XCTAssertEqual(BotKitConfiguration.SignInPage.default.logo, .swiftlyBotKit)
        let html = page(.default)
        XCTAssertTrue(html.contains("aria-label=\"SwiftlyBotKit\""))
        XCTAssertTrue(html.contains("id=\"botkit-logo-c-bg\""))
        XCTAssertTrue(html.contains("url(#botkit-logo-c-bg)"))
        XCTAssertFalse(html.contains("id=\"c-bg\""), "ids are namespaced")
        XCTAssertFalse(html.contains("--signin-button:"), "no colour overrides by default")
        // The logo sits above the form.
        let logo = html.range(of: "botkit-logo-c-bg")!.lowerBound
        let form = html.range(of: "<form")!.lowerBound
        XCTAssertLessThan(logo, form)
    }

    /// The embedded drawing is the published logo, not a copy that drifted.
    func testEmbeddedLogoMatchesThePublishedFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/assets/logo.svg")
        let published = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(
            BotKitLogo.svg.trimmingCharacters(in: .whitespacesAndNewlines),
            published.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testCustomLogoAndNoLogo() {
        let custom = page(.init(logo: .image(url: "/images/acme.png", altText: "Acme")))
        XCTAssertTrue(custom.contains("<img src=\"/images/acme.png\" alt=\"Acme\">"))
        XCTAssertFalse(custom.contains("botkit-logo"))
        let untitled = page(.init(logo: .image(url: "/images/acme.png")))
        XCTAssertTrue(untitled.contains("alt=\"Analytics\""), "alt falls back to the title")
        let none = page(.init(logo: .none))
        XCTAssertFalse(none.contains("class=\"brand\""))
    }

    func testColoursOverrideOnlyWhatIsSetAndApplyInDarkModeToo() {
        let html = page(.init(colors: .init(background: "#0B1020", button: "#6366F1", buttonText: "white")))
        let css = ":root{--page:#0B1020;--signin-button:#6366F1;--signin-button-text:white}"
        XCTAssertTrue(html.contains(css))
        XCTAssertTrue(html.contains("@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){--page:#0B1020;--signin-button:#6366F1;--signin-button-text:white}}"))
        let overrides = LoginPage.colorCSS(.init(colors: .init(background: "#0B1020", button: "#6366F1", buttonText: "white")))
        XCTAssertFalse(overrides.contains("--surface-1"), "unset colours keep the theme")
    }

    func testSeparateDarkColours() {
        let css = LoginPage.colorCSS(.init(colors: .init(background: "#ffffff"), darkColors: .init(background: "#000000")))
        XCTAssertEqual(css, ":root{--page:#ffffff}@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){--page:#000000}}")
        let darkOnly = LoginPage.colorCSS(.init(darkColors: .init(card: "rgb(10 10 10 / 90%)")))
        XCTAssertEqual(darkOnly, "@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){--surface-1:rgb(10 10 10 / 90%)}}")
    }

    /// Colours go into a stylesheet and the logo URL into an attribute, so
    /// anything that could escape either is refused at install.
    func testUnsafeValuesAreRefused() {
        for bad in ["red;}body{display:none", "</style><script>", "url(https://evil.example/x)", "", "red /* x */", String(repeating: "a", count: 65)] {
            let signIn = BotKitConfiguration.SignInPage(colors: .init(button: bad))
            XCTAssertThrowsError(try signIn.validate(), bad) { error in
                guard case BotKitConfigurationError.invalidSignInColor("button", _) = error else {
                    return XCTFail("unexpected \(error)")
                }
            }
        }
        for good in ["#6366F1", "#fff", "white", "rgb(99 102 241)", "hsl(239, 84%, 67%)", "oklch(0.6 0.2 270 / 50%)"] {
            XCTAssertNoThrow(try BotKitConfiguration.SignInPage(colors: .init(button: good)).validate(), good)
        }
        for bad in ["javascript:alert(1)", "//evil.example/x.png", "/a\" onerror=\"x", "logo.png", "ftp://x/y.png", "/a b.png"] {
            XCTAssertThrowsError(try BotKitConfiguration.SignInPage(logo: .image(url: bad)).validate(), bad)
        }
        for good in ["/images/logo.png", "https://cdn.example.com/logo.svg", "data:image/png;base64,AAAA"] {
            XCTAssertNoThrow(try BotKitConfiguration.SignInPage(logo: .image(url: good)).validate(), good)
        }
    }

    func testInstallRefusesAnUnsafeColourAndAllowsTheLogoOrigin() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        var config = BotKitConfiguration(signingSecret: "test-secret")
        config.recording = .init(recordsAgents: false, recordsReferrals: false)
        config.verification.isEnabled = false
        config.dashboard.username = "owner"
        config.dashboard.password = "correct horse"
        config.dashboard.signInPage.colors.card = "red;}"
        XCTAssertThrowsError(try BotKit.configureRoutes(for: app, config: config))

        config.dashboard.signInPage = .init(logo: .image(url: "https://cdn.example.com/brand/logo.svg"))
        try BotKit.configureRoutes(for: app, config: config)
        try await app.test(.GET, "/admin/ai-bots/") { res async in
            let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
            XCTAssertTrue(csp.contains("img-src 'self' data: https://cdn.example.com;"), csp)
            XCTAssertTrue(res.body.string.contains("<img src=\"https://cdn.example.com/brand/logo.svg\""))
        }
    }

    func testEachSiteGetsItsOwnLogo() {
        let signIn = BotKitConfiguration.SignInPage(
            logo: .image(url: "/images/fallback.png"),
            siteLogos: ["shop": .image(url: "/images/shop.png"), "docs": .none]
        )
        var options = BotKitConfiguration.Dashboard.default
        options.signInPage = signIn
        let shop = LoginPage.render(error: nil, options: options, siteKey: "shop", siteName: "Shop")
        XCTAssertTrue(shop.contains("<img src=\"/images/shop.png\" alt=\"Shop\">"), "alt falls back to the site name")
        let docs = LoginPage.render(error: nil, options: options, siteKey: "docs", siteName: "Docs")
        XCTAssertFalse(docs.contains("class=\"brand\""))
        let blog = LoginPage.render(error: nil, options: options, siteKey: "blog", siteName: "Blog")
        XCTAssertTrue(blog.contains("<img src=\"/images/fallback.png\" alt=\"Blog\">"), "no entry: the shared logo")
    }

    func testDarkVariant() {
        let html = page(.init(logo: .image(url: "/images/logo.png", altText: "Acme", darkURL: "/images/logo-dark.png")))
        XCTAssertTrue(html.contains(
            "<picture><source srcset=\"/images/logo-dark.png\" media=\"(prefers-color-scheme: dark)\"><img src=\"/images/logo.png\" alt=\"Acme\"></picture>"
        ), html)
        XCTAssertThrowsError(try BotKitConfiguration.SignInPage(
            siteLogos: ["shop": .image(url: "/ok.png", darkURL: "/a\" onerror=\"x")]
        ).validate())
    }

    func testSiteLogosAreCheckedAgainstTheSitesAndAllowedByTheCSP() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        var config = BotKitConfiguration(
            siteKey: { $0.headers.first(name: .host) == "shop.example" ? "shop" : "docs" },
            sites: [BotDashboardSite(key: "shop", name: "Shop"), BotDashboardSite(key: "docs", name: "Docs")],
            signingSecret: "test-secret"
        )
        config.recording = .init(recordsAgents: false, recordsReferrals: false)
        config.verification.isEnabled = false
        config.dashboard.username = "owner"
        config.dashboard.password = "correct horse"
        config.dashboard.signInPage.siteLogos = ["shpo": .image(url: "/shop.png")]
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? BotKitConfigurationError, .unknownSignInLogoSite("shpo"))
        }

        config.dashboard.signInPage.siteLogos = [
            "shop": .image(url: "/shop.png", darkURL: "https://cdn.example.com/shop-dark.png"),
            "docs": .image(url: "https://img.example.org/docs.svg"),
        ]
        try BotKit.configureRoutes(for: app, config: config)
        try await app.test(.GET, "/admin/ai-bots/", headers: ["Host": "shop.example"]) { res async in
            let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
            XCTAssertTrue(csp.contains("img-src 'self' data: https://img.example.org https://cdn.example.com;"), csp)
            XCTAssertTrue(res.body.string.contains("<img src=\"/shop.png\" alt=\"Shop\">"))
        }
        try await app.test(.GET, "/admin/ai-bots/", headers: ["Host": "docs.example"]) { res async in
            XCTAssertTrue(res.body.string.contains("<img src=\"https://img.example.org/docs.svg\" alt=\"Docs\">"))
        }
    }
}
