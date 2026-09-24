# Custom agents

Recognise an agent the built-in catalog does not know, reclassify one it does, or replace the catalog entirely.

## Overview

Every request's `User-Agent` is matched against the built-in ``AIAgentCatalog`` and your own ``BotKitConfiguration/Detection/customAgents``. An ``AIAgent`` has four fields:

- ``AIAgent/token``: the distinctive word to look for in the header, such as `ChatGPT-User`. Matched case-insensitively, as a whole word anywhere in the header. The rules are under "How matching works" below.
- ``AIAgent/purpose``: what the agent is doing. See <doc:UnderstandingAgentPurposes>.
- ``AIAgent/operatorName``: who runs it. Defaults to `Unknown`.
- ``AIAgent/respectsRobotsTxt``: `true` or `false` where the operator has said, `nil` where it has not. `false` is flagged on the dashboard.

### Adding an agent

```swift
config.detection.customAgents = [
    AIAgent(token: "AcmeResearchBot", purpose: .agent, operatorName: "Acme", respectsRobotsTxt: true),
]
```

If the operator publishes its IP ranges, add a ``CrawlerRangeFeed`` for it too, so its visits can be verified. See <doc:IPVerification>.

### Reclassifying a built-in agent

A custom agent whose token equals a built-in token, compared case-insensitively, replaces the built-in entry:

```swift
config.detection.customAgents = [
    AIAgent(token: "Amazonbot", purpose: .training, operatorName: "Amazon", respectsRobotsTxt: true),
]
```

New rows use the new purpose. Rows already written keep the purpose they were recorded with.

### Using only your own list

```swift
config.detection.includesBuiltInAgents = false
config.detection.customAgents = [
    AIAgent(token: "GPTBot", purpose: .training, operatorName: "OpenAI", respectsRobotsTxt: true),
    AIAgent(token: "ChatGPT-User", purpose: .userTriggered, operatorName: "OpenAI"),
]
```

### How matching works

A token matches only as a whole word: the character before it and the character after it in the header must not be an ASCII letter or digit. Spaces, punctuation (`/`, `;`, `(`, `+`, `-`, `_` and so on) and the start or end of the header all count as boundaries. So `Spider` does not match `Baiduspider/2.0`, and `GPTBot` does not match `NotGPTBotAtAll`, but `GPTBot/1.2;` and `(GPTBot)` both match. A token that itself starts or ends with punctuation is only checked on its letter or digit sides. ASCII letters are compared case-insensitively; any non-ASCII characters in a token must match exactly.

When several tokens match, the winner is decided in this order:

1. **Longest token.** Tokens overlap: `Applebot-Extended` contains `Applebot`, and since `-` is a boundary both match `Applebot-Extended/0.1`. The two mean different things, and a shortest-first match would file every `Applebot-Extended` training fetch under AI search.
2. **Custom before built-in**, between tokens of the same length.
3. **Earliest in the header.** User agents put the product token first and a contact URL after it. The real GPTBot header, `...GPTBot/1.2; +https://openai.com/gptbot`, contains both `GPTBot` and the built-in `OpenAI` token, equally long; `GPTBot` comes first. That holds when you reclassify `GPTBot` with a custom agent too.

The result never depends on the order of your ``BotKitConfiguration/Detection/customAgents`` list.

Pick a token that is specific enough not to be a word in ordinary user agents (`Spider` or `Code` would match every `... spider/1.0` search crawler and VS Code's `Code/1.93`, which is why the catalog leaves both out), and long enough not to be beaten by a longer built-in token.

``AIAgentCatalog/match(userAgent:)`` does the same lookup against the built-in catalog alone, which is handy in tests. ``AIAgentCatalog/all`` lists every built-in agent.

### Finding agents the catalog misses

The raw `User-Agent` is stored, truncated to 512 characters, on every recorded row. Only matched requests are recorded, though, so an agent that matches nothing leaves no trace. If you suspect one, search your access logs, then add it here. Consider reporting it upstream too, so the next catalog regeneration includes it: see <doc:KeepingTheCatalogFresh>.
