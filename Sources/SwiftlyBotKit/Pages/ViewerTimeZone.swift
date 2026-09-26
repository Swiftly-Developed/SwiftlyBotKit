import Foundation
import Vapor
import Elementary

/// Draws the dashboard in the time zone of the browser looking at it.
///
/// A browser does not send its time zone, so a few lines of script read it
/// (`Intl.DateTimeFormat().resolvedOptions().timeZone`) and store it in a
/// cookie scoped to the dashboard path, which the server reads on every
/// request. The sign-in page sets it too, so the first dashboard view after
/// signing in is already in the right zone. When the cookie changes on a
/// dashboard page, the page reloads once to redraw; it never loops, because it
/// reloads only when the cookie did not already hold the zone.
///
/// Without script, or with a zone this host's tz database does not know, the
/// configured ``BotKitConfiguration/Dashboard/timeZone`` is used, and the
/// chart caption names whichever zone was actually used.
///
/// The script is static, so the `Content-Security-Policy` allows exactly it by
/// hash; its inputs travel as `data-` attributes.
enum ViewerTimeZone {

    /// The cookie holding the browser's IANA zone name, beside the session cookie.
    static func cookieName(_ options: BotKitConfiguration.Dashboard) -> String {
        "\(options.sessionCookieName)_tz"
    }

    /// The zone to draw in: the browser's when the cookie names one this host
    /// knows, else the configured one.
    static func resolve(headers: HTTPHeaders, options: BotKitConfiguration.Dashboard) -> BotKitTimeZone {
        for raw in BotDashboardController.cookieValues(named: cookieName(options), in: headers).reversed() {
            let name = raw.removingPercentEncoding ?? raw
            guard name.count <= 64,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/_+-".contains($0)) }),
                  let zone = BotKitTimeZone(identifier: name), zone.isAvailable
            else { continue }
            return zone
        }
        return options.timeZone
    }

    /// `options` with ``BotKitConfiguration/Dashboard/timeZone`` set to the viewer's zone.
    static func options(for headers: HTTPHeaders, _ options: BotKitConfiguration.Dashboard) -> BotKitConfiguration.Dashboard {
        var resolved = options
        resolved.timeZone = resolve(headers: headers, options: options)
        return resolved
    }

    /// The `<script>` element. `reloads` is true on pages drawn in a zone.
    static func element(_ options: BotKitConfiguration.Dashboard, reloads: Bool) -> some HTML {
        script(
            .custom(name: "data-cookie", value: cookieName(options)),
            .custom(name: "data-path", value: options.basePath.isEmpty ? "/" : options.basePath),
            .custom(name: "data-zone", value: reloads ? options.timeZone.foundationTimeZone.identifier : "")
        ) {
            HTMLRaw(source)
        }
    }

    static let source = """
    (function(){try{var s=document.currentScript,d=s.dataset,z=Intl.DateTimeFormat().resolvedOptions().timeZone;\
    if(!z)return;var k=d.cookie+"=",m=document.cookie.split("; ").filter(function(c){return c.indexOf(k)===0;}).pop();\
    if(m&&decodeURIComponent(m.slice(k.length))===z)return;\
    document.cookie=d.cookie+"="+encodeURIComponent(z)+"; Path="+d.path+"; Max-Age=31536000; SameSite=Lax"+(location.protocol==="https:"?"; Secure":"");\
    if(d.zone&&d.zone!==z)location.reload();}catch(e){}})();
    """

    /// The CSP source allowing ``source`` and nothing else.
    static let cspSource: String = {
        let digest = SHA256.hash(data: Data(source.utf8))
        return "'sha256-\(Data(digest).base64EncodedString())'"
    }()
}
