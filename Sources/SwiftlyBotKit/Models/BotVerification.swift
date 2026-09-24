/// Whether the agent really was who its user-agent string claimed to be.
///
/// User-agent strings are free text. Reporting from the large CDNs puts roughly
/// one in twenty requests claiming to be a well-known AI crawler as forged,
/// with `ChatGPT-User` the most impersonated of all. That happens to be the
/// most valuable bucket, so an unverified count would be the least
/// trustworthy number on the page. Hence this column, and hence the dashboard
/// showing verified and claimed totals separately rather than one blended
/// figure.
///
/// Raw values are the PostgreSQL enum labels (`bot_verification`).
public enum BotVerification: String, Codable, CaseIterable, Sendable {
    /// Source IP falls inside the range list the operator publishes for that
    /// agent. As strong as it gets short of a request signature.
    case verified
    /// The operator publishes no list we can check, so the user agent is taken
    /// at its word. Most of the long tail lands here.
    case unverified
    /// Claimed an agent whose operator *does* publish ranges, and the source IP
    /// was not in them. Kept rather than dropped: it is a security signal.
    case spoofed
    /// Not a bot request at all: an AI referral row, where a human arrived
    /// from an AI assistant and there is nothing to verify.
    case notApplicable

    /// Human-readable name, e.g. "Verified".
    public var label: String {
        switch self {
        case .verified: return "Verified"
        case .unverified: return "Unverified"
        case .spoofed: return "Spoofed"
        case .notApplicable: return "N/A"
        }
    }
}
