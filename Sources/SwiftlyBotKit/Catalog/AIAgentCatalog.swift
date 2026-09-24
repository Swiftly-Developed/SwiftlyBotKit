import Foundation

/// One known AI agent, as the catalog describes it.
///
/// Build your own to recognise an agent the generated catalog does not know,
/// or to reclassify one it does, and pass it in
/// ``BotKitConfiguration/Detection/customAgents``.
public struct AIAgent: Sendable, Equatable {
    /// The distinctive word to look for in a user-agent header, e.g.
    /// `ChatGPT-User`. ASCII letters are compared case-insensitively, and the
    /// token has to appear as a whole word: the characters either side of it
    /// must not be letters or digits, so `Spider` does not match
    /// `Baiduspider`. See <doc:CustomAgents> for the full matching rules.
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
/// across some 175 upstream entries), and the entries that matter most (`GPTBot`, `ClaudeBot`,
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

    /// Every built-in agent, longest token first, then alphabetically. See
    /// ``match(userAgent:)``.
    public static let all: [AIAgent] = parse(AIAgentCatalogData.tsv)

    /// The built-in agent whose token appears, as a whole word, in this
    /// user-agent string, if any.
    ///
    /// Longest token wins, which is why `all` is sorted that way:
    /// `Applebot-Extended` contains `Applebot`, and `CCBot-User` contains
    /// `CCBot`. First match on a shortest-first list would file every
    /// `Applebot-Extended` training fetch under AI search. Between equally
    /// long tokens, the one that appears earliest in the header wins, so the
    /// real GPTBot header (`GPTBot/1.2; +https://openai.com/gptbot`) is
    /// `GPTBot`, not `OpenAI`.
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
        // Longest first, then alphabetical, so the order is deterministic.
        return agents.sorted {
            let (a, b) = (AIAgentMatcher.asciiLowercased($0.token), AIAgentMatcher.asciiLowercased($1.token))
            return a.count != b.count ? a.count > b.count : a.lexicographicallyPrecedes(b)
        }
    }
}

/// The per-request lookup from a user-agent header to an agent, over any agent
/// list: the built-in catalog, the app's custom agents, or both.
///
/// Runs synchronously on every request, human or not, so it is built once and
/// matches in a single pass over the header's UTF-8 bytes with an Aho-Corasick
/// automaton: cost is linear in the header length and independent of how many
/// tokens there are. An ordinary browser user agent costs a few microseconds,
/// and NIO's 80 KB cap on a single header bounds the worst case.
///
/// The rules, in order:
///
/// 1. A token matches only as a whole word: the characters either side of it
///    in the header must not be ASCII letters or digits. `Spider` does not
///    match inside `Baiduspider`, and `GPTBot` does not match inside
///    `NotGPTBotAtAll`. Punctuation, spaces, `/`, `-` and non-ASCII characters
///    all count as boundaries, so `Applebot` still appears inside
///    `Applebot-Extended/0.1`.
/// 2. Of the tokens that match, the longest wins (in UTF-8 bytes), so
///    `Applebot-Extended` beats `Applebot`.
/// 3. Between equally long tokens, a custom agent beats a built-in one, so a
///    custom `GPTBot` still wins over the built-in `OpenAI` in the real GPTBot
///    header (`...GPTBot/1.2; +https://openai.com/gptbot`).
/// 4. Then the token that appears earliest in the header wins. User agents put
///    the product token first and the contact URL after it, which is exactly
///    the GPTBot case again.
/// 5. Anything still tied (only possible for the same token, which is
///    deduplicated) falls back to the token's alphabetical order, so the result
///    never depends on the order the agents were supplied in.
///
/// ASCII letters are compared case-insensitively. Non-ASCII bytes in a custom
/// token must match exactly.
struct AIAgentMatcher: Sendable {
    private struct Entry: Sendable {
        let agent: AIAgent
        /// The token as ASCII-lowercased UTF-8.
        let key: [UInt8]
        let isCustom: Bool
    }

    /// In priority order: longest first, custom before built-in, then
    /// alphabetical. The automaton's pattern indices point into this.
    private let entries: [Entry]
    private let automaton: TokenAutomaton

    /// The agents, longest token first.
    var agents: [AIAgent] { entries.map(\.agent) }

    init(agents: [AIAgent]) {
        self.init(builtIn: [], custom: agents, customIsBuiltIn: true)
    }

    /// The built-in catalog (when `includesBuiltIn`), with `custom` entries
    /// added and replacing any built-in entry with the same token, compared
    /// case-insensitively.
    init(includesBuiltIn: Bool, custom: [AIAgent]) {
        self.init(builtIn: includesBuiltIn ? AIAgentCatalog.all : [], custom: custom, customIsBuiltIn: false)
    }

    private init(builtIn: [AIAgent], custom: [AIAgent], customIsBuiltIn: Bool) {
        var seen = Set<[UInt8]>()
        var entries: [Entry] = []
        // Custom first, so a custom entry claims its token before the
        // built-in one with the same token is considered. Within a list, the
        // first entry for a token wins.
        for (agent, isCustom) in custom.map({ ($0, !customIsBuiltIn) }) + builtIn.map({ ($0, false) }) {
            let key = Self.asciiLowercased(agent.token)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            entries.append(Entry(agent: agent, key: key, isCustom: isCustom))
        }
        entries.sort { a, b in
            if a.key.count != b.key.count { return a.key.count > b.key.count }
            if a.isCustom != b.isCustom { return a.isCustom }
            return a.key.lexicographicallyPrecedes(b.key)
        }
        self.entries = entries
        self.automaton = TokenAutomaton(patterns: entries.map(\.key))
    }

    func match(userAgent: String?) -> AIAgent? {
        guard var userAgent, !userAgent.isEmpty, !entries.isEmpty else { return nil }
        let entries = self.entries
        let found = userAgent.withUTF8 { bytes in
            automaton.bestMatch(in: bytes) { candidate, candidateStart, best, bestStart in
                let c = entries[candidate], b = entries[best]
                if c.key.count != b.key.count { return c.key.count > b.key.count }
                if c.isCustom != b.isCustom { return c.isCustom }
                if candidateStart != bestStart { return candidateStart < bestStart }
                return candidate < best
            }
        }
        return found.map { entries[$0].agent }
    }

    static func asciiLowercased(_ string: String) -> [UInt8] {
        string.utf8.map { $0 &- 0x41 < 26 ? $0 | 0x20 : $0 }
    }
}

/// A byte-level Aho-Corasick automaton over ASCII-lowercased patterns, with
/// whole-word boundary checks on the matches it reports.
///
/// Bytes are first mapped to a small class alphabet (every distinct byte that
/// appears in some pattern gets a class, everything else shares class 0), so
/// the full transition table stays small: a few hundred kilobytes for the
/// whole built-in catalog. ASCII capitals map to the same class as their
/// lowercase letter, which is how matching is case-insensitive without
/// lowercasing (or copying) the header.
struct TokenAutomaton: Sendable {
    private let byteClass: [UInt16]
    private let classCount: Int
    /// `transitions[state * classCount + class]`: the next state.
    private let transitions: [Int32]
    /// The pattern that ends exactly at this state, or -1.
    private let terminal: [Int32]
    /// The nearest state along the failure chain that ends a pattern, or -1.
    private let outputLink: [Int32]
    private let patternLength: [Int]
    /// Whether the pattern's first/last byte is a word character, and so needs
    /// a non-word neighbour on that side.
    private let checksLeft: [Bool]
    private let checksRight: [Bool]

    init(patterns: [[UInt8]]) {
        var byteClass = [UInt16](repeating: 0, count: 256)
        var next: UInt16 = 1
        for pattern in patterns {
            for byte in pattern where byteClass[Int(byte)] == 0 {
                byteClass[Int(byte)] = next
                next += 1
            }
        }
        for upper in UInt8(ascii: "A")...UInt8(ascii: "Z") {
            byteClass[Int(upper)] = byteClass[Int(upper | 0x20)]
        }
        let classCount = Int(next)

        // Trie.
        var transitions = [Int32](repeating: -1, count: classCount)
        var terminal: [Int32] = [-1]
        for (index, pattern) in patterns.enumerated() {
            var state = 0
            for byte in pattern {
                let slot = state * classCount + Int(byteClass[Int(byte)])
                if transitions[slot] < 0 {
                    transitions[slot] = Int32(terminal.count)
                    terminal.append(-1)
                    transitions.append(contentsOf: repeatElement(-1, count: classCount))
                }
                state = Int(transitions[slot])
            }
            if terminal[state] < 0 { terminal[state] = Int32(index) }
        }

        // Failure links, folded into a complete transition table, breadth
        // first so a state's failure target is always finished before it.
        let stateCount = terminal.count
        var failure = [Int32](repeating: 0, count: stateCount)
        var outputLink = [Int32](repeating: -1, count: stateCount)
        var queue: [Int] = []
        queue.reserveCapacity(stateCount)
        for c in 0..<classCount {
            let child = transitions[c]
            if child < 0 {
                transitions[c] = 0
            } else {
                failure[Int(child)] = 0
                queue.append(Int(child))
            }
        }
        var head = 0
        while head < queue.count {
            let state = queue[head]
            head += 1
            let fail = Int(failure[state])
            for c in 0..<classCount {
                let slot = state * classCount + c
                let child = transitions[slot]
                let fallback = transitions[fail * classCount + c]
                if child < 0 {
                    transitions[slot] = fallback
                } else {
                    failure[Int(child)] = fallback
                    outputLink[Int(child)] = terminal[Int(fallback)] >= 0 ? fallback : outputLink[Int(fallback)]
                    queue.append(Int(child))
                }
            }
        }
        // Class 0 matches nothing: from any state it goes back to the root.
        // (Already true by construction, as no pattern contains a class-0 byte.)

        self.byteClass = byteClass
        self.classCount = classCount
        self.transitions = transitions
        self.terminal = terminal
        self.outputLink = outputLink
        self.patternLength = patterns.map(\.count)
        self.checksLeft = patterns.map { $0.first.map(Self.isWordByte) ?? false }
        self.checksRight = patterns.map { $0.last.map(Self.isWordByte) ?? false }
    }

    @inline(__always)
    static func isWordByte(_ byte: UInt8) -> Bool {
        (byte | 0x20) &- 0x61 < 26 || byte &- 0x30 < 10
    }

    /// The best whole-word match in `bytes`, by `isBetter(candidate,
    /// candidateStart, best, bestStart)`, as a pattern index.
    func bestMatch(
        in bytes: UnsafeBufferPointer<UInt8>,
        isBetter: (Int, Int, Int, Int) -> Bool
    ) -> Int? {
        var best = -1
        var bestStart = 0
        byteClass.withUnsafeBufferPointer { byteClass in
        transitions.withUnsafeBufferPointer { transitions in
        terminal.withUnsafeBufferPointer { terminal in
        outputLink.withUnsafeBufferPointer { outputLink in
            var state = 0
            let count = bytes.count
            for end in 0..<count {
                state = Int(transitions[state &* classCount &+ Int(byteClass[Int(bytes[end])])])
                var hit = terminal[state] >= 0 ? state : Int(outputLink[state])
                while hit >= 0 {
                    let pattern = Int(terminal[hit])
                    let start = end - patternLength[pattern] + 1
                    let leftOK = !checksLeft[pattern] || start == 0 || !Self.isWordByte(bytes[start - 1])
                    let rightOK = !checksRight[pattern] || end + 1 == count || !Self.isWordByte(bytes[end + 1])
                    if leftOK, rightOK, best < 0 || isBetter(pattern, start, best, bestStart) {
                        best = pattern
                        bestStart = start
                    }
                    hit = Int(outputLink[hit])
                }
            }
        }
        }
        }
        }
        return best < 0 ? nil : best
    }
}
