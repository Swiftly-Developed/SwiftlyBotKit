import Foundation
import Vapor

/// Every secret-derived value this package needs, from one HMAC key
/// (`BotKitConfiguration.signingSecret`).
///
/// Stateless, so a login survives a restart and holds across app instances,
/// which an in-memory session store would not. Each use signs its own
/// prefixed message (`bot-dashboard:`, `credential:`, `ip:`, ...), so a value
/// produced for one purpose is never valid for another.
struct BotSigner: Sendable {
    private let key: SymmetricKey

    /// Secrets shorter than this many bytes are logged as weak: a captured
    /// session cookie is a known message plus its HMAC, so a short key can be
    /// brute-forced offline.
    static let recommendedSecretLength = 32

    init(secret: String) {
        self.key = SymmetricKey(data: Data(secret.utf8))
    }

    // MARK: Dashboard session cookie

    /// A fingerprint of the dashboard credentials, bound into every session
    /// token so that changing the username or password (or the secret)
    /// invalidates every session issued before the change.
    ///
    /// Length-prefixed so that no two (username, password) pairs share a
    /// message, and an HMAC so the token reveals nothing about either value.
    func credentialBinding(username: String, password: String) -> String {
        sign("session-binding:\(username.utf8.count):\(username):\(password)")
    }

    /// `<expiry unix seconds>.<hmac>`. The expiry and the credential binding
    /// are inside the signed payload, so editing the cookie to extend a
    /// session invalidates it, and so does a password change.
    func sessionToken(expiresAt: Date, binding: String = "") -> String {
        let seconds = Self.expirySeconds(expiresAt)
        return "\(seconds).\(sign(Self.sessionMessage(seconds: seconds, binding: binding)))"
    }

    /// Accepts only the exact encoding ``sessionToken(expiresAt:binding:)``
    /// produces: a run of ASCII digits with no sign and no leading zero, a
    /// dot, and 64 lowercase hex digits. One signature therefore validates
    /// exactly one cookie string.
    func isValidSessionToken(_ token: String?, binding: String = "", now: Date = Date()) -> Bool {
        guard let token, token.utf8.count <= 96 else { return false }
        let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return false }
        let digits = parts[0].utf8
        guard (1...12).contains(digits.count),
              digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              digits.first != 0x30,
              let seconds = Int(parts[0])
        else { return false }
        guard constantTimeEquals(parts[1], sign(Self.sessionMessage(seconds: seconds, binding: binding)))
        else { return false }
        return now.timeIntervalSince1970 < TimeInterval(seconds)
    }

    /// The largest expiry a token carries, and the most digits the parser
    /// accepts: twelve digits, far beyond any real session.
    static let maximumExpirySeconds = 999_999_999_999

    /// Whole seconds, clamped so that an infinite or absurd expiry can
    /// never trap in `Int(_:)`.
    private static func expirySeconds(_ date: Date) -> Int {
        let raw = date.timeIntervalSince1970
        guard raw.isFinite else { return raw > 0 ? maximumExpirySeconds : 0 }
        return Int(min(max(raw, 0), Double(maximumExpirySeconds)))
    }

    private static func sessionMessage(seconds: Int, binding: String) -> String {
        binding.isEmpty ? "bot-dashboard:\(seconds)" : "bot-dashboard:\(seconds):\(binding)"
    }

    // MARK: Credentials

    /// Compared as HMACs rather than as strings, so neither the value nor its
    /// length leaks through timing.
    func matches(_ candidate: String, expected: String) -> Bool {
        constantTimeEquals(sign("credential:\(candidate)"), sign("credential:\(expected)"))
    }

    // MARK: IP hashing

    /// Keyed hash of the client IP: enough to count distinct crawlers, and not
    /// reversible by brute-forcing the IPv4 space without the secret.
    func hashIP(_ ip: String) -> String {
        String(sign("ip:\(ip)").prefix(32))
    }

    // MARK: Primitives

    private func sign(_ message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
