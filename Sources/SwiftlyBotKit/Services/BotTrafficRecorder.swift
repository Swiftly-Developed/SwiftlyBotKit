import Foundation
import Vapor
import Fluent

/// Everything the recorder needs from a request, lifted out of `Request` (which
/// is not `Sendable`) so the write can happen off the request's back.
struct BotVisitCandidate: Sendable {
    let siteKey: String
    let path: String
    let method: String
    let statusCode: Int
    let userAgent: String?
    let referer: String?
    let clientIP: String?
}

/// Decides, per request, whether it is an AI agent, an AI-assistant referral,
/// or neither. Built once from the configuration.
struct BotRequestClassifier: Sendable {
    let agents: AIAgentMatcher
    let referrers: [LLMReferrer.Platform]
    let recording: BotKitConfiguration.Recording
    /// Always excluded from recording, whether or not the dashboard is mounted.
    let dashboardPath: String

    init(configuration: BotKitConfiguration) {
        self.agents = AIAgentMatcher(
            includesBuiltIn: configuration.detection.includesBuiltInAgents,
            custom: configuration.detection.customAgents
        )
        self.referrers = LLMReferrer.platforms(
            includesBuiltIn: configuration.detection.includesBuiltInReferrers,
            custom: configuration.detection.customReferrers
        )
        self.recording = configuration.recording
        self.dashboardPath = configuration.dashboard.normalizedPath
    }

    /// The agent this request claims to be, when agent recording is on.
    func agent(userAgent: String?) -> AIAgent? {
        guard recording.recordsAgents else { return nil }
        return agents.match(userAgent: userAgent)
    }

    /// The assistant this request was referred from, when referral recording
    /// is on.
    func referrerPlatform(referer: String?) -> String? {
        guard recording.recordsReferrals else { return nil }
        return LLMReferrer.platform(forReferer: referer, in: referrers)
    }

    /// Cheap, synchronous, and runs on every single request, so it does the
    /// least work that can rule a request out, and never touches the database.
    func isWorthRecording(path: String, userAgent: String?, referer: String?) -> Bool {
        if let ext = Self.fileExtension(of: path), recording.ignoredFileExtensions.contains(ext) {
            return false
        }
        if dashboardPath != "/", path.hasPrefix(dashboardPath) { return false }
        if recording.excludedPathPrefixes.contains(where: { !$0.isEmpty && path.hasPrefix($0) }) {
            return false
        }
        return agent(userAgent: userAgent) != nil || referrerPlatform(referer: referer) != nil
    }

    private static func fileExtension(of path: String) -> String? {
        guard let lastComponent = path.split(separator: "/").last,
              let dot = lastComponent.lastIndex(of: "."),
              dot != lastComponent.startIndex
        else { return nil }
        return String(lastComponent[lastComponent.index(after: dot)...]).lowercased()
    }
}

/// Turns a candidate into a row, or decides there is nothing worth storing.
///
/// Writes happen in a detached task: verification can involve a vendor fetch on
/// the first request after boot, and no reader should ever wait behind the
/// analytics. The trade is that a process killed mid-write loses a row or two,
/// which for traffic statistics is a fine trade.
struct BotTrafficRecorder: Sendable {
    let database: any Database
    let classifier: BotRequestClassifier
    /// `nil` when verification is turned off: every agent is `.unverified`.
    let directory: CrawlerIPDirectory?
    let signer: BotSigner
    let logger: Logger

    func record(_ candidate: BotVisitCandidate) async {
        let visit: AIBotVisit
        if let agent = classifier.agent(userAgent: candidate.userAgent) {
            let verification = await directory?.verify(
                agentToken: agent.token,
                clientIP: candidate.clientIP
            ) ?? .unverified
            visit = AIBotVisit(
                siteKey: candidate.siteKey,
                path: candidate.path,
                method: candidate.method,
                statusCode: candidate.statusCode,
                agentName: agent.token,
                agentOperator: agent.operatorName,
                purpose: agent.purpose,
                verification: verification,
                respectsRobotsTxt: agent.respectsRobotsTxt,
                ipHash: hashedIP(candidate.clientIP),
                userAgent: candidate.userAgent.map { String($0.prefix(512)) }
            )
        } else if let platform = classifier.referrerPlatform(referer: candidate.referer) {
            visit = AIBotVisit(
                siteKey: candidate.siteKey,
                path: candidate.path,
                method: candidate.method,
                statusCode: candidate.statusCode,
                verification: .notApplicable,
                referrerPlatform: platform,
                ipHash: hashedIP(candidate.clientIP),
                userAgent: candidate.userAgent.map { String($0.prefix(512)) }
            )
        } else {
            return
        }

        do {
            try await visit.save(on: database)
        } catch {
            // A failed write must never surface to the reader: the response
            // they care about went out long before this ran.
            logger.warning("Could not record AI bot visit: \(error)")
        }
    }

    private func hashedIP(_ ip: String?) -> String {
        guard let ip else { return "unknown" }
        return signer.hashIP(ip)
    }
}
