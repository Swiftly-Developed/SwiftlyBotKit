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
        let path = Self.collapsingRepeatedSlashes(path)
        // The router and FileMiddleware see the percent-decoded path, so
        // `/logo%2Epng` is an asset and `/admin%20bots/` is a dashboard at
        // `/admin bots`. The skip rules check both spellings.
        let decoded = path.contains("%")
            ? path.removingPercentEncoding.map(Self.collapsingRepeatedSlashes)
            : nil
        let decodedOrRaw = decoded ?? path
        if let ext = Self.fileExtension(of: decodedOrRaw), recording.ignoredFileExtensions.contains(ext) {
            return false
        }
        if isDashboardPath(path) || isDashboardPath(decodedOrRaw) { return false }
        // Documented as plain string prefixes: `/healthz` also covers
        // `/healthzcheck`. Checked against the slash-collapsed path, so
        // `//healthz` cannot slip past.
        if recording.excludedPathPrefixes.contains(where: { prefix in
            !prefix.isEmpty && (path.hasPrefix(prefix) || decodedOrRaw.hasPrefix(prefix))
        }) {
            return false
        }
        return agent(userAgent: userAgent) != nil || referrerPlatform(referer: referer) != nil
    }

    /// The dashboard's own path and everything below it, on a path-segment
    /// boundary: `/admin/ai-bots` and `/admin/ai-bots/login`, but not
    /// `/admin/ai-botsnet/`.
    private func isDashboardPath(_ path: String) -> Bool {
        guard dashboardPath != "/" else { return false }
        return path == dashboardPath || path.hasPrefix(dashboardPath + "/")
    }

    /// Vapor's router ignores empty path components, so `//admin/ai-bots/`
    /// reaches the same route as `/admin/ai-bots/`. The skip rules see the
    /// path the way the router does.
    static func collapsingRepeatedSlashes(_ path: String) -> String {
        guard path.contains("//") else { return path }
        var result = ""
        result.reserveCapacity(path.utf8.count)
        var previousWasSlash = false
        for character in path {
            let isSlash = character == "/"
            if !(isSlash && previousWasSlash) { result.append(character) }
            previousWasSlash = isSlash
        }
        return result
    }

    /// The last path component's extension, lowercased.
    static func fileExtension(of path: String) -> String? {
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
        let siteKey = Self.storable(candidate.siteKey)
        let path = Self.storable(candidate.path)
        let userAgent = candidate.userAgent.map { Self.storable($0) }
        let visit: AIBotVisit
        if let agent = classifier.agent(userAgent: candidate.userAgent) {
            let verification = await directory?.verify(
                agentToken: agent.token,
                clientIP: candidate.clientIP
            ) ?? .unverified
            visit = AIBotVisit(
                siteKey: siteKey,
                path: path,
                method: candidate.method,
                statusCode: candidate.statusCode,
                agentName: Self.storable(agent.token),
                agentOperator: Self.storable(agent.operatorName),
                purpose: agent.purpose,
                verification: verification,
                respectsRobotsTxt: agent.respectsRobotsTxt,
                ipHash: hashedIP(candidate.clientIP),
                userAgent: userAgent
            )
        } else if let platform = classifier.referrerPlatform(referer: candidate.referer) {
            visit = AIBotVisit(
                siteKey: siteKey,
                path: path,
                method: candidate.method,
                statusCode: candidate.statusCode,
                verification: .notApplicable,
                referrerPlatform: Self.storable(platform),
                ipHash: hashedIP(candidate.clientIP),
                userAgent: userAgent
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

    /// Fit for a PostgreSQL `text` column: NUL (U+0000) removed, since
    /// PostgreSQL rejects it and the whole row would be lost, and cut to at
    /// most `limit` Unicode scalars, the unit PostgreSQL counts in.
    ///
    /// The cut falls between whole `Character`s, so a flag or an emoji ZWJ
    /// sequence is never split and the result is always a prefix of the
    /// input. Counting `Character`s alone would not bound the length at all
    /// (one letter followed by thousands of combining marks is a single
    /// `Character`), so a `Character` that would cross the limit is left out.
    static func storable(_ value: String, limit: Int = 512) -> String {
        var value = value
        if value.utf8.contains(0) {
            value.unicodeScalars.removeAll { $0 == "\u{0}" }
        }
        // Fast path: every scalar is at least one UTF-8 byte.
        if value.utf8.count <= limit { return value }
        var scalarCount = 0
        var end = value.startIndex
        for index in value.indices {
            let width = value[index].unicodeScalars.count
            guard scalarCount + width <= limit else { break }
            scalarCount += width
            end = value.index(after: index)
        }
        return String(value[..<end])
    }

    private func hashedIP(_ ip: String?) -> String {
        guard let ip else { return "unknown" }
        return signer.hashIP(ip)
    }
}
