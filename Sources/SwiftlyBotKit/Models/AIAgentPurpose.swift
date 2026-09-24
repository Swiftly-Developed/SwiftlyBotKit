/// What an AI agent was doing when it asked for a page.
///
/// This is the distinction the dashboard is built around, and the reason the
/// kit exists at all: "4,000 AI bot hits" is a vanity number, while "Claude-User
/// fetched /services/application-management/ 30 times this week" is a sales
/// signal. The vendors expose the difference deliberately, through separate
/// user agents (OpenAI splits `GPTBot` / `OAI-SearchBot` / `ChatGPT-User`,
/// Anthropic splits `ClaudeBot` / `Claude-SearchBot` / `Claude-User`), so the
/// split is theirs, not a guess.
///
/// The raw values are also the PostgreSQL enum labels (`ai_agent_purpose`) and the
/// second column of `AIAgentCatalogData.tsv`. Adding a case means a migration
/// and a catalog regeneration, in that order.
public enum AIAgentPurpose: String, Codable, CaseIterable, Sendable {
    /// Content is being collected to train a model. You are never credited.
    case training
    /// Indexed so the page can be cited in an AI answer later.
    case aiSearch
    /// A person asked an assistant something and it fetched this page to
    /// answer them, live. The most commercially interesting bucket.
    case userTriggered
    /// An autonomous or coding agent acting on a task.
    case agent
    /// Harvesting for resale, datasets or image corpora.
    case scraper

    /// Dashboard ordering: most valuable first, so tiles and legends read
    /// top-down in the order a reader cares about. Also the chart's colour
    /// slot order.
    public static let displayOrder: [AIAgentPurpose] = [
        .userTriggered, .aiSearch, .agent, .training, .scraper,
    ]

    /// Human-readable name, e.g. "User-triggered".
    public var label: String {
        switch self {
        case .training: return "Model training"
        case .aiSearch: return "AI search index"
        case .userTriggered: return "User-triggered"
        case .agent: return "Autonomous agent"
        case .scraper: return "Scraper"
        }
    }

    /// One line of "so what", shown under the tiles.
    public var blurb: String {
        switch self {
        case .training:
            return "Your content is feeding a model. No attribution, ever."
        case .aiSearch:
            return "Indexed so your pages can be cited in AI answers."
        case .userTriggered:
            return "Someone asked an assistant a question and it read this page to answer."
        case .agent:
            return "An autonomous or coding agent working through a task."
        case .scraper:
            return "Harvested for datasets, resale or image corpora."
        }
    }
}
