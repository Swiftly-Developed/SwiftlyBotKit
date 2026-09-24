import Foundation
import Vapor
import Fluent
import SQLKit

/// The dashboard, behind a password. With the default path:
///
/// - `GET  /admin/ai-bots/`: the dashboard, or the sign-in page
/// - `POST /admin/ai-bots/login`
/// - `POST /admin/ai-bots/logout`
///
/// Mounted on every host the app answers for, so a multi-site app has one
/// dashboard across all its sites, with the site switcher doing the
/// filtering. Both pages send `X-Robots-Tag: noindex`.
struct BotDashboardController: RouteCollection {
    let config: BotKitConfiguration
    let runtime: BotKitRuntime
    let username: String
    let password: String

    private var options: BotKitConfiguration.Dashboard { config.dashboard }

    func boot(routes: RoutesBuilder) throws {
        // Registered without a trailing slash. Vapor's router treats
        // `/admin/ai-bots` and `/admin/ai-bots/` as the same route.
        let dashboard = routes.grouped(options.pathComponents.map { PathComponent(stringLiteral: $0) })
        dashboard.get { try await self.index($0) }
        dashboard.post("login") { try await self.login($0) }
        dashboard.post("logout") { try await self.logout($0) }
    }

    // MARK: - Dashboard

    private func index(_ req: Request) async throws -> Response {
        guard isSignedIn(req) else {
            return html(LoginPage.render(error: nil, options: options))
        }
        guard let sql = req.db(config.database) as? SQLDatabase else {
            throw Abort(.serviceUnavailable, reason: "The dashboard needs a PostgreSQL database.")
        }

        let range = options.dateRange(forQuery: req.query[String.self, at: "range"])
        let site = config.site(
            forKey: req.query[String.self, at: "site"],
            hostSiteKey: config.siteKey(req)
        )

        let data = try await BotDashboardQueries(database: sql, timeZone: options.timeZone.foundationTimeZone)
            .load(range: range, siteKey: site?.key)

        return html(DashboardPage.render(
            data: data,
            range: range,
            sites: config.sites,
            selectedSite: site,
            generatedAt: Date(),
            options: options,
            knownAgentCount: runtime.classifier.agents.agents.count
        ))
    }

    // MARK: - Session

    private struct Credentials: Content {
        var username: String?
        var password: String?
    }

    private func login(_ req: Request) async throws -> Response {
        // Keyed by hashed IP so a failed-attempt count never stores an address.
        let attemptKey = runtime.signer.hashIP(config.clientIP.clientIP(for: req) ?? "unknown")
        if await runtime.loginAttempts.isBlocked(attemptKey) {
            return html(
                LoginPage.render(
                    error: "Too many attempts. Try again in \(Self.describe(options.loginLimit.window)).",
                    options: options
                ),
                status: .tooManyRequests
            )
        }

        let submitted = try req.content.decode(Credentials.self)
        // Both compared, and always both: checking the username first and
        // returning early would leak which half was wrong.
        let userMatches = runtime.signer.matches(submitted.username ?? "", expected: username)
        let passwordMatches = runtime.signer.matches(submitted.password ?? "", expected: password)
        guard userMatches && passwordMatches else {
            await runtime.loginAttempts.recordFailure(attemptKey)
            req.logger.warning("Rejected AI bot dashboard sign-in.")
            return html(
                LoginPage.render(error: "That username and password did not match.", options: options),
                status: .unauthorized
            )
        }

        await runtime.loginAttempts.reset(attemptKey)
        let expiry = Date().addingTimeInterval(options.sessionLifetime)
        let response = req.redirect(to: "\(options.basePath)/")
        response.cookies[options.sessionCookieName] = sessionCookie(
            value: runtime.signer.sessionToken(expiresAt: expiry),
            expires: expiry,
            req: req
        )
        return response
    }

    private func logout(_ req: Request) async throws -> Response {
        let response = req.redirect(to: "\(options.basePath)/")
        response.cookies[options.sessionCookieName] = sessionCookie(
            value: "",
            expires: Date(timeIntervalSince1970: 0),
            req: req
        )
        return response
    }

    private func isSignedIn(_ req: Request) -> Bool {
        runtime.signer.isValidSessionToken(req.cookies[options.sessionCookieName]?.string)
    }

    private func sessionCookie(value: String, expires: Date, req: Request) -> HTTPCookies.Value {
        var cookie = HTTPCookies.Value(string: value)
        cookie.path = "/"
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

    /// "15 minutes", "1 hour", "90 seconds".
    static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
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
        Response(
            status: status,
            headers: [
                "content-type": "text/html; charset=utf-8",
                "cache-control": "no-store",
                "x-robots-tag": "noindex, nofollow",
            ],
            body: .init(string: body)
        )
    }
}
