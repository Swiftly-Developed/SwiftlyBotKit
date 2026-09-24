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
        /// `notperplexity.ai`. Compared case-insensitively. Leading and
        /// trailing dots are ignored, so `.example.com` means the same as
        /// `example.com`; an empty suffix matches nothing.
        ///
        /// For an Android app referrer (`android-app://com.openai.chatgpt/`)
        /// the app's package name takes the host's place and must match this
        /// exactly, so an entry like `com.openai.chatgpt` recognises the app.
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
    ///
    /// Only hosts where people read assistant answers. `openai.com`,
    /// `claude.com` and `x.ai` are deliberately absent: they are company and
    /// developer-documentation sites (`platform.openai.com`,
    /// `docs.claude.com`), and a link followed from API docs is not an
    /// assistant referral. Grok inside X is not listed either: its referrer
    /// is plain `x.com`, indistinguishable from any other X link.
    public static let builtInPlatforms: [Platform] = [
        .init(hostSuffix: "chatgpt.com", name: "ChatGPT"),
        .init(hostSuffix: "chat.openai.com", name: "ChatGPT"),
        .init(hostSuffix: "claude.ai", name: "Claude"),
        .init(hostSuffix: "perplexity.ai", name: "Perplexity"),
        .init(hostSuffix: "gemini.google.com", name: "Gemini"),
        .init(hostSuffix: "bard.google.com", name: "Gemini"),
        .init(hostSuffix: "copilot.microsoft.com", name: "Copilot"),
        .init(hostSuffix: "m365.cloud.microsoft", name: "Copilot"),
        .init(hostSuffix: "grok.com", name: "Grok"),
        .init(hostSuffix: "chat.mistral.ai", name: "Le Chat"),
        .init(hostSuffix: "you.com", name: "You.com"),
        .init(hostSuffix: "poe.com", name: "Poe"),
        .init(hostSuffix: "phind.com", name: "Phind"),
        // Android apps, which send `android-app://<package>/` as the referrer.
        .init(hostSuffix: "com.openai.chatgpt", name: "ChatGPT"),
        .init(hostSuffix: "com.anthropic.claude", name: "Claude"),
        .init(hostSuffix: "ai.perplexity.app.android", name: "Perplexity"),
        .init(hostSuffix: "com.google.android.apps.bard", name: "Gemini"),
        .init(hostSuffix: "com.microsoft.copilot", name: "Copilot"),
        .init(hostSuffix: "ai.x.grok", name: "Grok"),
    ]

    /// The built-in assistant this `Referer` came from, or `nil` for the
    /// ordinary web.
    public static func platform(forReferer referer: String?) -> String? {
        platform(forReferer: referer, in: builtInPlatforms)
    }

    /// The assistant in `platforms` this `Referer` came from, or `nil`. The
    /// first matching entry wins.
    public static func platform(forReferer referer: String?, in platforms: [Platform]) -> String? {
        guard let referer, !referer.isEmpty, let origin = origin(of: referer) else { return nil }
        for platform in platforms {
            let suffix = normalizedSuffix(platform.hostSuffix)
            guard !suffix.isEmpty else { continue }
            switch origin {
            case .web(let host):
                if isHost(host, onSuffix: suffix) { return platform.name }
            case .androidApp(let package):
                if package == suffix { return platform.name }
            }
        }
        return nil
    }

    /// The built-in list (when `includesBuiltIn`) with `custom` entries added,
    /// custom first so they win, and replacing any built-in entry with the
    /// same host suffix.
    static func platforms(includesBuiltIn: Bool, custom: [Platform]) -> [Platform] {
        let custom = custom
            .map { Platform(hostSuffix: normalizedSuffix($0.hostSuffix), name: $0.name) }
            .filter { !$0.hostSuffix.isEmpty }
        let overridden = Set(custom.map(\.hostSuffix))
        let builtIn = includesBuiltIn
            ? builtInPlatforms.filter { !overridden.contains($0.hostSuffix) }
            : []
        return custom + builtIn
    }

    // MARK: - Parsing

    private enum Origin {
        /// A lowercased host with no trailing dot.
        case web(String)
        /// A lowercased Android package name.
        case androidApp(String)
    }

    /// `URL(string:)` rather than a regex, and tolerant of a bare host: some
    /// clients send a `Referer` with no scheme, which `URL` gives no host for.
    private static func origin(of referer: String) -> Origin? {
        let url = URL(string: referer)
        if let url, url.scheme?.lowercased() == "android-app" {
            guard let package = url.host?.lowercased(), !package.isEmpty else { return nil }
            return .androidApp(package)
        }
        if let host = url?.host, !host.isEmpty {
            return trimmedHost(host).map(Origin.web)
        }
        if url?.scheme != nil, referer.contains("://") {
            // A scheme with no host (`https:///x`): nothing to match.
            return nil
        }
        // Scheme-less: the host runs up to the first character that ends an
        // authority, so `evil.com?x=.chatgpt.com` is `evil.com`.
        let authorityEnd = referer.firstIndex { "/?#\\".contains($0) } ?? referer.endIndex
        var authority = referer[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        let host = authority.prefix { $0 != ":" }
        guard host.contains(".") else { return nil }
        return trimmedHost(String(host)).map(Origin.web)
    }

    /// `host` is `suffix` or ends in `.` + `suffix`. Byte-wise, as both are
    /// already lowercased.
    private static func isHost(_ host: String, onSuffix suffix: String) -> Bool {
        let host = host.utf8, suffix = suffix.utf8
        guard host.count >= suffix.count, host.suffix(suffix.count).elementsEqual(suffix) else { return false }
        return host.count == suffix.count || host.dropLast(suffix.count).last == UInt8(ascii: ".")
    }

    /// Lowercased, with the trailing dot of a fully qualified name removed:
    /// `chatgpt.com.` is the same host as `chatgpt.com`.
    private static func trimmedHost(_ host: String) -> String? {
        var host = Substring(host.lowercased())
        while host.hasSuffix(".") { host = host.dropLast() }
        return host.isEmpty ? nil : String(host)
    }

    /// Lowercased, without leading or trailing dots. Allocates only when the
    /// suffix actually needs changing, since this runs per request.
    private static func normalizedSuffix(_ suffix: String) -> String {
        let needsWork = suffix.utf8.contains { $0 &- 0x41 < 26 }
            || suffix.hasPrefix(".") || suffix.hasSuffix(".")
        guard needsWork else { return suffix }
        let trimmed = suffix.lowercased().drop { $0 == "." }
        return String(trimmed.reversed().drop { $0 == "." }.reversed())
    }
}
