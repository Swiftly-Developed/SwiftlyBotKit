import SwiftlyBotKit
import Vapor

func botKitConfiguration(for environment: Environment) -> BotKitConfiguration {
    var config = BotKitConfiguration()

    // A CDN in front of a load balancer: two proxies each append an entry,
    // so the client is the second entry from the right.
    config.clientIP = .forwardedFor(trustedProxies: 2)

    // Health checks and the internal API are never worth a row.
    config.recording.excludedPathPrefixes = ["/healthz", "/api/internal"]
    // Neither are web app manifests.
    config.recording.ignoredFileExtensions.insert("webmanifest")

    // Recognise an agent the catalog does not know yet, and reclassify one it does.
    config.detection.customAgents = [
        AIAgent(token: "AcmeResearchBot", purpose: .agent, operatorName: "Acme", respectsRobotsTxt: true),
        AIAgent(token: "Amazonbot", purpose: .training, operatorName: "Amazon", respectsRobotsTxt: true),
    ]

    return config
}
