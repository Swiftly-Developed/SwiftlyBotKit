import Foundation

/// A configuration that `BotKit` refuses to install, thrown by
/// `BotKit.configureRoutes(for:config:)` and `BotKit.install(on:config:)`.
///
/// Each case describes itself in plain words, so logging the error or letting
/// it end the boot says what to fix.
public enum BotKitConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {

    /// ``BotKitConfiguration/Dashboard/path`` cannot be mounted as given.
    case invalidDashboardPath(String, reason: String)

    /// ``BotKitConfiguration/Dashboard/sessionCookieName`` is not an RFC 6265
    /// token, so the browser would not send the cookie back as set.
    case invalidSessionCookieName(String)

    /// A site in ``BotKitConfiguration/sites`` uses the key reserved for the
    /// all-sites view, ``BotKitConfiguration/reservedAllSitesKey``.
    case reservedSiteKey(String)

    /// `BotKit` was already installed on this application: `install` or
    /// `configureRoutes` called twice, or `configure` followed by `install`.
    /// Installing twice would register the migration twice (the second
    /// `CREATE TYPE` fails) or record every hit twice.
    case alreadyInstalled(String)

    /// A description of what is wrong and how to fix it.
    public var description: String {
        switch self {
        case .invalidDashboardPath(let path, let reason):
            return "Invalid BotKit dashboard path \(path.debugDescription): \(reason)"
        case .invalidSessionCookieName(let name):
            return "Invalid BotKit session cookie name \(name.debugDescription): use an RFC 6265 token (letters, digits and !#$%&'*+-.^_`|~), without spaces or ()<>@,;:\\\"/[]?={}."
        case .reservedSiteKey(let key):
            return "The BotKit site key \(key.debugDescription) is reserved for the dashboard's all-sites view. Give that site another key."
        case .alreadyInstalled(let detail):
            return "BotKit is already installed on this application: \(detail)"
        }
    }
}

extension BotKitConfiguration {

    /// Throws the first problem that would make the configuration misbehave
    /// at runtime rather than fail loudly now.
    func validate() throws {
        try dashboard.validatePath()
        try dashboard.validateCookieName()
        if let site = sites.first(where: { $0.key == Self.reservedAllSitesKey }) {
            throw BotKitConfigurationError.reservedSiteKey(site.key)
        }
    }

    /// The keys that appear more than once in ``sites``.
    var duplicateSiteKeys: [String] {
        var seen = Set<String>(), duplicates: [String] = []
        for site in sites where !seen.insert(site.key).inserted && !duplicates.contains(site.key) {
            duplicates.append(site.key)
        }
        return duplicates
    }
}

extension BotKitConfiguration.Dashboard {

    /// RFC 3986 unreserved characters: the only ones a segment may use, so
    /// the configured path, the router, the links and the browser all agree.
    private static let pathCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".unicodeScalars
    )

    func validatePath() throws {
        let components = pathComponents
        guard !components.isEmpty else {
            throw BotKitConfigurationError.invalidDashboardPath(
                path, reason: "the dashboard cannot be mounted at the root, where it would take over the app's own /, /login and /logout. Use a path such as /admin/ai-bots."
            )
        }
        for component in components {
            if component.hasPrefix(":") || component.hasPrefix("*") {
                throw BotKitConfigurationError.invalidDashboardPath(
                    path, reason: "the segment \(component.debugDescription) would read as route syntax (a parameter or wildcard). Use a literal segment."
                )
            }
            if component == "." || component == ".." {
                throw BotKitConfigurationError.invalidDashboardPath(
                    path, reason: "\".\" and \"..\" segments are resolved away by browsers, so the dashboard would be unreachable."
                )
            }
            if let bad = component.unicodeScalars.first(where: { !Self.pathCharacters.contains($0) }) {
                throw BotKitConfigurationError.invalidDashboardPath(
                    path, reason: "the character \(String(bad).debugDescription) is not allowed. Use only letters, digits, \"-\", \".\", \"_\" and \"~\" in each segment."
                )
            }
        }
    }

    /// RFC 6265 `cookie-name`, which is an RFC 2616 token.
    func validateCookieName() throws {
        let separators = Set("()<>@,;:\\\"/[]?={} \t".unicodeScalars)
        let valid = !sessionCookieName.isEmpty && sessionCookieName.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value < 0x7F && !separators.contains(scalar)
        }
        guard valid else { throw BotKitConfigurationError.invalidSessionCookieName(sessionCookieName) }
    }
}
