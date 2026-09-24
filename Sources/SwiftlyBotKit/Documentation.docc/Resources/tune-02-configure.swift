import SwiftlyBotKit
import Vapor

func botKitConfiguration(for environment: Environment) -> BotKitConfiguration {
    var config = BotKitConfiguration()

    // A CDN in front of a load balancer: two proxies each append an entry,
    // so the client is the second entry from the right.
    config.clientIP = .forwardedFor(trustedProxies: 2)

    return config
}
