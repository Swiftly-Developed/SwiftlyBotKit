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

    // Count humans arriving from an assistant the built-in list does not cover.
    config.detection.customReferrers = [
        LLMReferrer.Platform(hostSuffix: "chat.deepseek.com", name: "DeepSeek"),
    ]

    // Acme publishes its crawler ranges, so AcmeResearchBot can be verified too.
    config.verification.feeds = CrawlerRangeFeed.defaults + [
        CrawlerRangeFeed(url: "https://acme.example/crawler-ranges.json", agentTokens: ["AcmeResearchBot"]),
    ]
    config.verification.refreshInterval = 6 * 60 * 60

    // Local development: never fetch the vendor feeds, store every agent as unverified.
    if environment == .development {
        config.verification.isEnabled = false
    }

    return config
}
