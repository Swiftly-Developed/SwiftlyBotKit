import Foundation
import Vapor
import Fluent
import SQLKit

/// The dashboard, behind a password. With the default path:
///
/// - `GET  /admin/ai-bots/`: the dashboard, or the sign-in page
/// - `GET  /admin/ai-bots/pages/`: the page views tab, only when
///   ``BotKitConfiguration/PageViews`` is on
/// - `POST /admin/ai-bots/login`
/// - `POST /admin/ai-bots/logout`
///
/// Mounted on every host the app answers for, so a multi-site app has one
/// dashboard across all its sites, with the site switcher doing the
/// filtering. Every response sends `X-Robots-Tag: noindex`, `no-store` and
/// the hardening headers in ``securityHeaders``.
struct BotDashboardController: RouteCollection {
    let config: BotKitConfiguration
    let runtime: BotKitRuntime
    let username: String
    let password: String
    /// Bound into every session token, so a credential change signs every
    /// existing session out.
    let sessionBinding: String
    /// The `Content-Security-Policy` value, computed once.
    let contentSecurityPolicy: String

    private var options: BotKitConfiguration.Dashboard { config.dashboard }

    init(config: BotKitConfiguration, runtime: BotKitRuntime, username: String, password: String) {
        self.config = config
        self.runtime = runtime
        self.username = username
        self.password = password
        self.sessionBinding = runtime.signer.credentialBinding(username: username, password: password)
        self.contentSecurityPolicy = Self.contentSecurityPolicy(logoPaths: config.sites.compactMap(\.logoPath))
    }

    func boot(routes: RoutesBuilder) throws {
        // Registered without a trailing slash. Vapor's router treats
        // `/admin/ai-bots` and `/admin/ai-bots/` as the same route.
        // `.constant`, never `PathComponent(stringLiteral:)`, which would read
        // a leading `:` or `*` as route syntax. The path is validated by
        // `BotKitConfiguration.validate()` before this runs.
        let dashboard = routes.grouped(options.pathComponents.map { PathComponent.constant($0) })
        dashboard.get { try await self.index($0) }
        if config.pageViews.isEnabled {
            dashboard.get("pages") { try await self.pageViews($0) }
        }
        dashboard.post("login") { try await self.login($0) }
        dashboard.post("logout") { try await self.logout($0) }
    }

    // MARK: - Dashboard

    private func index(_ req: Request) async throws -> Response {
        guard isSignedIn(req) else {
            return html(LoginPage.render(error: nil, options: options))
        }
        guard let sql = database(req) else { return unavailable(req) }
        let (range, site) = filters(req)
        let data = try await BotDashboardQueries(database: sql, timeZone: options.timeZone.foundationTimeZone)
            .load(range: range, siteKey: site?.key)

        return html(DashboardPage.render(
            data: data,
            range: range,
            sites: config.sites,
            selectedSite: site,
            generatedAt: Date(),
            options: options,
            knownAgentCount: runtime.classifier.agents.agents.count,
            showsPageViews: config.pageViews.isEnabled
        ))
    }

    private func pageViews(_ req: Request) async throws -> Response {
        guard isSignedIn(req) else {
            return html(LoginPage.render(error: nil, options: options))
        }
        guard let sql = database(req) else { return unavailable(req) }
        let (range, site) = filters(req)
        let data = try await PageViewQueries(database: sql, timeZone: options.timeZone.foundationTimeZone)
            .load(range: range, siteKey: site?.key)

        return html(PageViewsPage.render(
            data: data,
            range: range,
            sites: config.sites,
            selectedSite: site,
            generatedAt: Date(),
            options: options
        ))
    }

    /// The configured database, or `nil` when none is registered under its
    /// ID or it cannot run SQL.
    ///
    /// `req.db` is a fatal error when no database is registered under the
    /// ID, so check the registry first and answer 503 instead of crashing.
    /// (`Databases.configuration(for: nil)` would itself trap without a
    /// default, hence `ids()`.)
    private func database(_ req: Request) -> (any SQLDatabase)? {
        let registered = req.application.databases.ids()
        let hasDatabase = config.database.map { registered.contains($0) } ?? !registered.isEmpty
        guard hasDatabase else { return nil }
        return req.db(config.database) as? SQLDatabase
    }

    private func unavailable(_ req: Request) -> Response {
        req.logger.error("The AI bot dashboard needs a registered PostgreSQL database.")
        return html(
            Self.plainPage(title: "Unavailable", message: "The dashboard needs a PostgreSQL database."),
            status: .serviceUnavailable
        )
    }

    /// The `?range=` and `?site=` filters.
    private func filters(_ req: Request) -> (BotDateRange, BotDashboardSite?) {
        let range = options.dateRange(forQuery: req.query[String.self, at: "range"])
        let site = config.site(
            forKey: req.query[String.self, at: "site"],
            hostSiteKey: config.siteKey(req)
        )
        return (range, site)
    }

    // MARK: - Session

    private struct Credentials: Content {
        var username: String?
        var password: String?
    }

    private func login(_ req: Request) async throws -> Response {
        guard !Self.isCrossSite(req.headers) else {
            req.logger.warning("Refused a cross-site AI bot dashboard sign-in.")
            return forbidden()
        }

        // Keyed by hashed IP so a failed-attempt count never stores an address.
        let client = runtime.signer.hashIP(LoginAttemptLimiter.bucket(for: Self.clientAddress(req, strategy: config.clientIP)))
        let limiter = runtime.loginAttempts
        let reservation: Date
        switch await limiter.reserve(client) {
        case .allowed(let at):
            reservation = at
        case .blocked:
            return tooManyAttempts()
        case .globallyBlocked:
            if await limiter.shouldReportGlobalTrip() {
                req.logger.critical(
                    "AI bot dashboard sign-in is locked for every client: \(limiter.globalMaximumFailures) failed attempts within \(Self.describe(limiter.window)). This looks like a distributed password-guessing attack. Sign-in resumes when the window passes.",
                    metadata: ["client": .string(client)]
                )
            }
            return tooManyAttempts()
        }

        let submitted = (try? req.content.decode(Credentials.self)) ?? Credentials()
        // Both compared, and always both: checking the username first and
        // returning early would leak which half was wrong.
        let userMatches = runtime.signer.matches(submitted.username ?? "", expected: username)
        let passwordMatches = runtime.signer.matches(submitted.password ?? "", expected: password)
        guard userMatches && passwordMatches else {
            // The reservation already counts as the failure.
            req.logger.warning("Rejected AI bot dashboard sign-in.", metadata: ["client": .string(client)])
            return html(
                LoginPage.render(error: "That username and password did not match.", options: options),
                status: .unauthorized
            )
        }

        await limiter.succeeded(client, reservation: reservation)
        req.logger.info("AI bot dashboard sign-in succeeded.", metadata: ["client": .string(client)])
        let expiry = Date().addingTimeInterval(Self.effectiveSessionLifetime(options.sessionLifetime))
        let response = redirectToDashboard(req)
        response.cookies[options.sessionCookieName] = sessionCookie(
            value: runtime.signer.sessionToken(expiresAt: expiry, binding: sessionBinding),
            expires: expiry,
            req: req
        )
        clearLegacyCookie(on: response, req: req)
        return response
    }

    /// Clears the cookie in the browser. The token itself is stateless and
    /// stays valid until it expires, or until the password or the signing
    /// secret changes; there is no server-side revocation list.
    private func logout(_ req: Request) async throws -> Response {
        guard !Self.isCrossSite(req.headers) else { return forbidden() }
        let response = redirectToDashboard(req)
        response.cookies[options.sessionCookieName] = sessionCookie(
            value: "",
            expires: Date(timeIntervalSince1970: 0),
            req: req
        )
        clearLegacyCookie(on: response, req: req)
        return response
    }

    /// Signed in when any cookie of the session cookie's name carries a valid
    /// token.
    ///
    /// Earlier versions set the cookie with `Path=/`; it is now scoped to the
    /// dashboard path. A browser holding both sends both under one name, and
    /// `req.cookies` would pick just one of them, possibly the stale one.
    private func isSignedIn(_ req: Request) -> Bool {
        Self.cookieValues(named: options.sessionCookieName, in: req.headers).contains {
            runtime.signer.isValidSessionToken($0, binding: sessionBinding)
        }
    }

    /// Every value sent under `name` across all `Cookie` headers, in order.
    static func cookieValues(named name: String, in headers: HTTPHeaders) -> [String] {
        headers[.cookie]
            .flatMap { $0.split(separator: ";") }
            .compactMap { pair -> String? in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == name
                else { return nil }
                var value = parts[1].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                return value
            }
    }

    /// Expires a same-named cookie left at `Path=/` by earlier versions, which
    /// would otherwise ride along on every request to the whole site.
    ///
    /// Written as a raw header, since `response.cookies` holds one cookie per
    /// name, and placed before the scoped cookie so that anything reading the
    /// headers as one cookie per name (the last one winning) sees the real
    /// session. Browsers keep both apart by path either way.
    private func clearLegacyCookie(on response: Response, req: Request) {
        guard options.basePath != "" else { return }
        var legacy = "\(options.sessionCookieName)=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; HttpOnly; SameSite=Lax"
        if Self.isSecure(policy: options.secureCookies, headers: req.headers, scheme: req.url.scheme) {
            legacy += "; Secure"
        }
        let existing = response.headers[.setCookie]
        response.headers.remove(name: .setCookie)
        response.headers.add(name: .setCookie, value: legacy)
        for value in existing { response.headers.add(name: .setCookie, value: value) }
    }

    /// `HttpOnly`, `SameSite=Lax`, `Path` set to the dashboard path.
    ///
    /// Lax rather than Strict: with Strict, following a link to the dashboard
    /// from another site (a bookmark in a mail client, a chat message) arrives
    /// without the cookie and shows the sign-in page. Lax already keeps the
    /// cookie off cross-site POSTs, and both POST endpoints also refuse
    /// cross-site requests outright (``isCrossSite(_:)``), while the GET is
    /// read-only.
    private func sessionCookie(value: String, expires: Date, req: Request) -> HTTPCookies.Value {
        var cookie = HTTPCookies.Value(string: value)
        cookie.path = options.basePath.isEmpty ? "/" : options.basePath
        cookie.expires = expires
        cookie.isHTTPOnly = true
        cookie.sameSite = .lax
        cookie.isSecure = Self.isSecure(policy: options.secureCookies, headers: req.headers, scheme: req.url.scheme)
        return cookie
    }

    /// Whether the session cookie gets `Secure`.
    ///
    /// Under `.automatic`, `X-Forwarded-Proto` comes first: when TLS is
    /// terminated at a proxy, the app sees plain HTTP and that header is the
    /// only honest signal, so relying on the URL scheme alone would never mark
    /// the cookie secure in production.
    static func isSecure(
        policy: BotKitConfiguration.SecureCookiePolicy,
        headers: HTTPHeaders,
        scheme: String?
    ) -> Bool {
        switch policy {
        case .always: return true
        case .never: return false
        case .automatic:
            return headers.first(name: "X-Forwarded-Proto")?.lowercased() == "https"
                || scheme?.lowercased() == "https"
        }
    }

    // MARK: - Request checks

    /// The throttle key's source: the configured client IP, else the socket
    /// peer, and only when neither exists a shared `unknown` bucket.
    static func clientAddress(_ req: Request, strategy: ClientIPStrategy) -> String {
        strategy.clientIP(for: req) ?? req.remoteAddress?.ipAddress ?? "unknown"
    }

    /// Whether a state-changing POST came from another site.
    ///
    /// When the browser sends `Sec-Fetch-Site` (every current browser does,
    /// and a page cannot set or forge it), that decides: only `same-origin`
    /// and `none` (the user acting directly) are allowed, so `same-site` and
    /// `cross-site` are refused. The `Origin` header is not consulted then,
    /// because a browser may legitimately send `Origin: null` for a
    /// same-origin form, for example under a `no-referrer` policy.
    ///
    /// Without `Sec-Fetch-Site`: refused when an `Origin`
    /// header is present and its host does not match the request's `Host`
    /// (or an `X-Forwarded-Host` entry, for proxies that rewrite `Host`; a
    /// browser cannot set that header on a forged request). An opaque
    /// `Origin: null` never matches. A request with neither header, such as
    /// one from `curl` or an older browser, is allowed: the attack being
    /// stopped here needs a victim's browser, which sends at least one.
    static func isCrossSite(_ headers: HTTPHeaders) -> Bool {
        if let site = headers.first(name: "Sec-Fetch-Site")?.trimmingCharacters(in: .whitespaces).lowercased() {
            return site != "same-origin" && site != "none"
        }
        guard let origin = headers.first(name: .origin) else { return false }
        guard let originAuthority = authority(ofOrigin: origin) else { return true }
        var allowed = headers[.host].map { normalizedAuthority($0) }
        allowed += headers["X-Forwarded-Host"]
            .flatMap { $0.split(separator: ",") }
            .map { normalizedAuthority(String($0)) }
        return !allowed.contains(originAuthority)
    }

    /// `host[:port]` of a serialized origin, lowercased, default port dropped.
    private static func authority(ofOrigin origin: String) -> String? {
        let trimmed = origin.trimmingCharacters(in: .whitespaces)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return normalizedAuthority("\(host)\(port)")
    }

    private static func normalizedAuthority(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in [":80", ":443"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value
    }

    // MARK: - Responses

    /// The page needs no script and loads nothing from elsewhere, except site
    /// logos, which may be absolute URLs: their origins are added to
    /// `img-src`. Inline `<style>`, `style=` attributes and inline SVG need
    /// only `style-src 'unsafe-inline'`.
    static func contentSecurityPolicy(logoPaths: [String]) -> String {
        var imageSources = ["'self'", "data:"]
        for path in logoPaths {
            guard let components = URLComponents(string: path),
                  let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = components.host?.lowercased(), !host.isEmpty,
                  host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
                  host.allSatisfy(\.isASCII)
            else { continue }
            let source = "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
            if !imageSources.contains(source) { imageSources.append(source) }
        }
        return "default-src 'none'; style-src 'unsafe-inline'; img-src \(imageSources.joined(separator: " ")); "
            + "form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
    }

    /// Sent on every dashboard, sign-in and sign-out response.
    private var securityHeaders: [(String, String)] {
        [
            ("Cache-Control", "no-store"),
            ("X-Robots-Tag", "noindex, nofollow"),
            ("X-Frame-Options", "DENY"),
            ("X-Content-Type-Options", "nosniff"),
            // Not `no-referrer`: under it browsers send `Origin: null` on the
            // dashboard's own sign-in form, which the cross-site check has to
            // refuse for a browser without Fetch Metadata. `same-origin` still
            // sends nothing to any other site.
            ("Referrer-Policy", "same-origin"),
            ("Content-Security-Policy", contentSecurityPolicy),
        ]
    }

    private func harden(_ response: Response) -> Response {
        for (name, value) in securityHeaders {
            response.headers.replaceOrAdd(name: name, value: value)
        }
        return response
    }

    /// Always the fixed dashboard path, never anything from the request.
    private func redirectToDashboard(_ req: Request) -> Response {
        harden(req.redirect(to: "\(options.basePath)/"))
    }

    private func tooManyAttempts() -> Response {
        html(
            LoginPage.render(
                error: "Too many attempts. Try again in \(Self.describe(runtime.loginAttempts.window)).",
                options: options
            ),
            status: .tooManyRequests
        )
    }

    private func forbidden() -> Response {
        html(
            Self.plainPage(title: "Forbidden", message: "Cross-site requests to the dashboard are refused."),
            status: .forbidden
        )
    }

    private static func plainPage(title: String, message: String) -> String {
        "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>\(title)</title></head><body><p>\(message)</p></body></html>"
    }

    /// ``BotKitConfiguration/Dashboard/sessionLifetime``, made usable: a
    /// lifetime that is not positive would issue an already-expired cookie
    /// (a sign-in loop), so the default twelve hours is used instead, and a
    /// longer one than browsers keep (400 days) is capped there.
    static func effectiveSessionLifetime(_ lifetime: TimeInterval) -> TimeInterval {
        guard lifetime.isFinite else { return lifetime > 0 ? maximumSessionLifetime : defaultSessionLifetime }
        guard lifetime > 0 else { return defaultSessionLifetime }
        return min(lifetime, maximumSessionLifetime)
    }

    static let defaultSessionLifetime: TimeInterval = BotKitConfiguration.Dashboard.default.sessionLifetime
    static let maximumSessionLifetime: TimeInterval = 400 * 24 * 60 * 60

    /// "15 minutes", "1 hour", "90 seconds". Never traps: a value that is not
    /// finite or is negative is clamped first.
    static func describe(_ interval: TimeInterval) -> String {
        let clamped = interval.isFinite ? min(max(interval, 0), Double(Int32.max)) : Double(Int32.max)
        let seconds = Int(clamped.rounded())
        if seconds % 3600 == 0, seconds >= 3600 {
            let hours = seconds / 3600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if seconds % 60 == 0, seconds >= 60 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    private func html(_ body: String, status: HTTPStatus = .ok) -> Response {
        let response = Response(
            status: status,
            headers: ["content-type": "text/html; charset=utf-8"],
            body: .init(string: body)
        )
        return harden(response)
    }
}
