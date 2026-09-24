import Foundation
import Vapor

/// Every secret-derived value this package needs, from one HMAC key
/// (`BotKitConfiguration.signingSecret`).
///
/// Stateless, so a login survives a restart and holds across app instances,
/// which an in-memory session store would not.
struct BotSigner: Sendable {
    private let key: SymmetricKey

    init(secret: String) {
        self.key = SymmetricKey(data: Data(secret.utf8))
    }

    // MARK: Dashboard session cookie

    /// `<expiry unix seconds>.<hmac>`. The expiry is inside the signed payload,
    /// so editing the cookie to extend a session invalidates it.
    func sessionToken(expiresAt: Date) -> String {
        let seconds = Int(expiresAt.timeIntervalSince1970)
        return "\(seconds).\(sign("bot-dashboard:\(seconds)"))"
    }

    func isValidSessionToken(_ token: String?, now: Date = Date()) -> Bool {
        guard let token else { return false }
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let seconds = Int(parts[0]),
              constantTimeEquals(parts[1], sign("bot-dashboard:\(seconds)"))
        else { return false }
        return now.timeIntervalSince1970 < TimeInterval(seconds)
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
