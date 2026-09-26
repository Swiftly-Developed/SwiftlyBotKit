import Foundation
import Elementary

/// The sign-in page for the dashboard.
///
/// One account, configured through `BotKitConfiguration.Dashboard.username`
/// and `password` (by default the `BOT_DASHBOARD_USER` and
/// `BOT_DASHBOARD_PASSWORD` environment variables), never stored in the
/// database.
enum LoginPage {

    static func render(error: String?, options: BotKitConfiguration.Dashboard = .default) -> String {
        let page = html(.lang("en")) {
            head {
                meta(.charset(.utf8))
                meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
                meta(.name("robots"), .content("noindex, nofollow"))
                Elementary.title { "Sign in \u{00B7} \(options.title)" }
                style { HTMLRaw(DashboardTheme.css + Self.css + Self.colorCSS(options.signInPage)) }
            }
            body {
                main(.class("login")) {
                    logo(options)
                    div(.class("card")) {
                        h1 { options.title }
                        p(.class("sub")) { "Sign in to view crawler and assistant activity." }
                        if let error {
                            p(.class("error")) { error }
                        }
                        form(.method(.post), .action("\(options.basePath)/login")) {
                            Elementary.label(.for("username")) { "Username" }
                            input(
                                .type(.text), .name("username"), .id("username"), .required,
                                .custom(name: "autocomplete", value: "username"),
                                .custom(name: "autocapitalize", value: "none")
                            )
                            Elementary.label(.for("password")) { "Password" }
                            input(
                                .type(.password), .name("password"), .id("password"), .required,
                                .custom(name: "autocomplete", value: "current-password")
                            )
                            button(.type(.submit), .class("primary")) { "Sign in" }
                        }
                    }
                }
            }
        }
        return "<!DOCTYPE html>" + page.render()
    }

    @HTMLBuilder
    private static func logo(_ options: BotKitConfiguration.Dashboard) -> some HTML {
        switch options.signInPage.logo {
        case .swiftlyBotKit:
            div(.class("brand")) { HTMLRaw(BotKitLogo.inline(label: "SwiftlyBotKit")) }
        case .image(let url, let altText):
            div(.class("brand")) { img(.src(url), .alt(altText ?? options.title)) }
        case .none:
            EmptyHTML()
        }
    }

    /// The configured colours as variable overrides, after the theme so they
    /// win. Without ``BotKitConfiguration/SignInPage/darkColors`` the same
    /// colours are also set inside the theme's dark-mode rule, which would
    /// otherwise outrank them.
    static func colorCSS(_ page: BotKitConfiguration.SignInPage) -> String {
        let dark = page.darkColors ?? page.colors
        var css = ""
        if !page.colors.isEmpty { css += ":root{\(page.colors.css)}" }
        if !dark.isEmpty {
            css += "@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){\(dark.css)}}"
        }
        return css
    }

    private static let css = """
    main.login{max-width:380px;margin:0 auto;padding:12vh 20px}
    main.login h1{font-size:19px;margin:0}
    main.login label{display:block;font-size:13px;font-weight:600;margin:14px 0 4px}
    main.login input{width:100%;padding:10px 12px;border:1px solid var(--border);border-radius:8px;
      font:inherit;background:var(--page);color:var(--text-primary)}
    main.login .brand{display:flex;justify-content:center;margin:0 0 18px}
    main.login .brand svg,main.login .brand img{height:64px;width:auto;max-width:100%;display:block}
    main.login .primary{width:100%;margin-top:18px;padding:10px;border-radius:8px;
      border:1px solid var(--signin-button,var(--text-primary));
      background:var(--signin-button,var(--text-primary));color:var(--signin-button-text,var(--surface-1));
      font:inherit;font-weight:650;cursor:pointer}
    main.login .error{background:var(--page);border:1px solid var(--critical);color:var(--critical);
      padding:9px 12px;border-radius:8px;font-size:13px;margin-top:14px}
    """
}
