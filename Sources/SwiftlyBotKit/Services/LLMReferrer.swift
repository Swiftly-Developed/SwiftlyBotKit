import Foundation

/// A human who arrived from an AI assistant's answer.
///
/// The conversion-side counterpart to `AIAgentPurpose.aiSearch`: the search
/// crawler indexing a page and a reader clicking through from the answer it
/// produced are the two halves of the same story, and the dashboard shows them
/// side by side. Browser analytics can in principle see these visits, but it
/// is often consent-gated, so a good share of them never reach it.
public enum LLMReferrer {

    /// One AI assistant, recognised by the host of the `Referer` it sends.
    public struct Platform: Sendable, Equatable {
        /// Matched against the referrer's host exactly or as a dot-separated
        /// suffix, so `perplexity.ai` also covers `www.perplexity.ai` but not
        /// `notperplexity.ai`. Compared case-insensitively.
        public var hostSuffix: String
        /// The name stored and shown on the dashboard, e.g. `ChatGPT`.
        public var name: String

        /// Creates a platform entry.
        public init(hostSuffix: String, name: String) {
            self.hostSuffix = hostSuffix
            self.name = name
        }
    }

    /// The assistants recognised out of the box.
    public static let builtInPlatforms: [Platform] = [
        .init(hostSuffix: "chatgpt.com", name: "ChatGPT"),
        .init(hostSuffix: "chat.openai.com", name: "ChatGPT"),
        .init(hostSuffix: "openai.com", name: "ChatGPT"),
        .init(hostSuffix: "claude.ai", name: "Claude"),
        .init(hostSuffix: "claude.com", name: "Claude"),
        .init(hostSuffix: "perplexity.ai", name: "Perplexity"),
        .init(hostSuffix: "gemini.google.com", name: "Gemini"),
        .init(hostSuffix: "bard.google.com", name: "Gemini"),
        .init(hostSuffix: "copilot.microsoft.com", name: "Copilot"),
        .init(hostSuffix: "m365.cloud.microsoft", name: "Copilot"),
        .init(hostSuffix: "grok.com", name: "Grok"),
        .init(hostSuffix: "x.ai", name: "Grok"),
        .init(hostSuffix: "chat.mistral.ai", name: "Le Chat"),
        .init(hostSuffix: "you.com", name: "You.com"),
        .init(hostSuffix: "poe.com", name: "Poe"),
        .init(hostSuffix: "phind.com", name: "Phind"),
    ]

    /// The built-in assistant this `Referer` came from, or `nil` for the
    /// ordinary web.
    public static func platform(forReferer referer: String?) -> String? {
        platform(forReferer: referer, in: builtInPlatforms)
    }

    /// The assistant in `platforms` this `Referer` came from, or `nil`. The
    /// first matching entry wins.
    public static func platform(forReferer referer: String?, in platforms: [Platform]) -> String? {
        guard let referer, let host = host(of: referer)?.lowercased() else { return nil }
        for platform in platforms {
            let suffix = platform.hostSuffix.lowercased()
            if host == suffix || host.hasSuffix("." + suffix) { return platform.name }
        }
        return nil
    }

    /// The built-in list (when `includesBuiltIn`) with `custom` entries added,
    /// custom first so they win, and replacing any built-in entry with the
    /// same host suffix.
    static func platforms(includesBuiltIn: Bool, custom: [Platform]) -> [Platform] {
        let overridden = Set(custom.map { $0.hostSuffix.lowercased() })
        let builtIn = includesBuiltIn
            ? builtInPlatforms.filter { !overridden.contains($0.hostSuffix.lowercased()) }
            : []
        return custom + builtIn
    }

    /// `URL(string:)` rather than a regex, and tolerant of a bare host: some
    /// clients send a `Referer` with no scheme, which `URL` gives no host for.
    private static func host(of referer: String) -> String? {
        if let host = URL(string: referer)?.host { return host }
        let trimmed = referer.split(separator: "/").first.map(String.init) ?? referer
        return trimmed.contains(".") ? trimmed : nil
    }
}
