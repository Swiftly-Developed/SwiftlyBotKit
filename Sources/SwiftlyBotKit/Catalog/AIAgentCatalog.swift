import Foundation

/// One known AI agent, as the catalog describes it.
///
/// Build your own to recognise an agent the generated catalog does not know,
/// or to reclassify one it does, and pass it in
/// ``BotKitConfiguration/Detection/customAgents``.
public struct AIAgent: Sendable, Equatable {
    /// The distinctive substring to look for in a user-agent header, e.g.
    /// `ChatGPT-User`. Compared case-insensitively.
    public let token: String
    /// What the agent is doing when it fetches a page.
    public let purpose: AIAgentPurpose
    /// `OpenAI`, `Anthropic`, and so on, or `Unknown` where nobody has said.
    public let operatorName: String
    /// `nil` where the operator has never said. `false` is a documented
    /// refusal (`Perplexity-User` and `Bytespider` both sit there), which the
    /// dashboard flags, because those hits happen whatever robots.txt says.
    public let respectsRobotsTxt: Bool?

    /// Creates an agent entry.
    public init(
        token: String,
        purpose: AIAgentPurpose,
        operatorName: String = "Unknown",
        respectsRobotsTxt: Bool? = nil
    ) {
        self.token = token
        self.purpose = purpose
        self.operatorName = operatorName
        self.respectsRobotsTxt = respectsRobotsTxt
    }
}

/// The lookup from a user-agent header to a known AI agent.
///
/// Backed by `AIAgentCatalogData`, generated from the community
/// `ai-robots-txt/ai.robots.txt` list by
/// `Scripts/generate-ai-agent-catalog.py`. Regenerate it every quarter or so:
/// new agents appear constantly, and an unrecognised agent is simply invisible
/// here rather than wrong, which makes the drift easy to miss.
///
/// Upstream's own `function` field is free text (about 70 distinct values
/// across 175 agents), and the entries that matter most (`GPTBot`, `ClaudeBot`,
/// `PerplexityBot`, `CCBot`, `Google-Extended`) are all prose rather than one of
/// its newer taxonomy labels. So `purpose` here is this package's own
/// classification, decided by the generator script's hand-audited override
/// table, and the script prints how many rows fell through to a keyword guess
/// so the audit stays honest.
///
/// This is the built-in catalog only. An app's own additions and overrides
/// (``BotKitConfiguration/Detection``) are applied on top of it at
/// configuration time.
public enum AIAgentCatalog {

    /// Every built-in agent, longest token first. See ``match(userAgent:)``.
    public static let all: [AIAgent] = parse(AIAgentCatalogData.tsv)

    /// The built-in agent whose token appears in this user-agent string, if
    /// any.
    ///
    /// Longest token wins, which is the whole reason `all` is sorted that way:
    /// `Applebot-Extended` contains `Applebot`, and `CCBot-User` contains
    /// `CCBot`. First match on a shortest-first list would file every
    /// `Applebot-Extended` training fetch under AI search.
    public static func match(userAgent: String?) -> AIAgent? {
        builtInMatcher.match(userAgent: userAgent)
    }

    private static let builtInMatcher = AIAgentMatcher(agents: all)

    // MARK: - Parsing

    private static func parse(_ tsv: String) -> [AIAgent] {
        let agents: [AIAgent] = tsv.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 4,
                  let purpose = AIAgentPurpose(rawValue: String(columns[1]))
            else { return nil }
            let respects: Bool?
            switch columns[3] {
            case "yes": respects = true
            case "no": respects = false
            default: respects = nil
            }
            return AIAgent(
                token: String(columns[0]),
                purpose: purpose,
                operatorName: String(columns[2]),
                respectsRobotsTxt: respects
            )
        }
        return agents.sorted { $0.token.count > $1.token.count }
    }
}

/// Longest-token-first matching over any agent list, with the lowercased
/// tokens computed once rather than on every request.
struct AIAgentMatcher: Sendable {
    private let entries: [(token: String, agent: AIAgent)]

    /// The agents, longest token first.
    var agents: [AIAgent] { entries.map(\.agent) }

    init(agents: [AIAgent]) {
        self.entries = agents
            .filter { !$0.token.isEmpty }
            .sorted { $0.token.count > $1.token.count }
            .map { ($0.token.lowercased(), $0) }
    }

    /// The built-in catalog (when `includesBuiltIn`), with `custom` entries
    /// added and replacing any built-in entry with the same token.
    init(includesBuiltIn: Bool, custom: [AIAgent]) {
        let overridden = Set(custom.map { $0.token.lowercased() })
        let builtIn = includesBuiltIn
            ? AIAgentCatalog.all.filter { !overridden.contains($0.token.lowercased()) }
            : []
        self.init(agents: builtIn + custom)
    }

    func match(userAgent: String?) -> AIAgent? {
        guard let userAgent, !userAgent.isEmpty else { return nil }
        let haystack = userAgent.lowercased()
        return entries.first { haystack.contains($0.token) }?.agent
    }
}
