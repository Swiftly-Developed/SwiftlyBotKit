import Foundation
import Vapor
import Fluent

/// One recorded request: either an AI agent fetching a page, or a human
/// arriving from an AI assistant's answer.
///
/// Two shapes in one table, told apart by which column is populated:
/// `agentName` for a bot, `referrerPlatform` for a referral. They are separate
/// questions ("who is reading us to build answers" and "who arrives from those
/// answers") but they share every other column, every filter and every date
/// bucket, and splitting them would mean two of each query for no gain.
///
/// Ordinary human traffic is *not* recorded here. Nothing is written unless the
/// request matches the catalog or carries an assistant referer, which keeps this
/// table small and keeps the kit out of the business of general analytics.
final class AIBotVisit: Model, Content, @unchecked Sendable {
    static let schema = "ai_bot_visits"

    @ID(key: .id)
    var id: UUID?

    /// What `BotKitConfiguration.siteKey` returned for the request, so the
    /// dashboard's site filter splits traffic the way the app's router does.
    @Field(key: "site_key")
    var siteKey: String

    /// Path only, query string dropped: it keeps the top-pages list readable
    /// and avoids storing whatever a crawler appended.
    @Field(key: "path")
    var path: String

    @Field(key: "method")
    var method: String

    @Field(key: "status_code")
    var statusCode: Int

    /// The catalog token that matched, e.g. `ChatGPT-User`. `nil` on a referral row.
    @OptionalField(key: "agent_name")
    var agentName: String?

    @OptionalField(key: "agent_operator")
    var agentOperator: String?

    @OptionalEnum(key: "purpose")
    var purpose: AIAgentPurpose?

    @Enum(key: "verification")
    var verification: BotVerification

    /// What the operator says about robots.txt. `false` is documented refusal,
    /// not an inference from behaviour: we never test whether it obeyed.
    @OptionalField(key: "respects_robots_txt")
    var respectsRobotsTxt: Bool?

    /// `ChatGPT`, `Claude`, … on a referral row; `nil` on a bot row.
    @OptionalField(key: "referrer_platform")
    var referrerPlatform: String?

    /// Keyed hash of the client IP, same construction as the comment kit's:
    /// enough to count distinct visitors, never the address itself.
    @Field(key: "ip_hash")
    var ipHash: String

    /// Truncated raw header. Kept because when the catalog misses a new agent,
    /// this column is the only way to find out what it was.
    @OptionalField(key: "user_agent")
    var userAgent: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        siteKey: String,
        path: String,
        method: String,
        statusCode: Int,
        agentName: String? = nil,
        agentOperator: String? = nil,
        purpose: AIAgentPurpose? = nil,
        verification: BotVerification,
        respectsRobotsTxt: Bool? = nil,
        referrerPlatform: String? = nil,
        ipHash: String,
        userAgent: String? = nil
    ) {
        self.siteKey = siteKey
        self.path = path
        self.method = method
        self.statusCode = statusCode
        self.agentName = agentName
        self.agentOperator = agentOperator
        self.purpose = purpose
        self.verification = verification
        self.respectsRobotsTxt = respectsRobotsTxt
        self.referrerPlatform = referrerPlatform
        self.ipHash = ipHash
        self.userAgent = userAgent
    }
}
