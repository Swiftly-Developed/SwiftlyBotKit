# Custom agents

Recognise an agent the built-in catalog does not know, reclassify one it does, or replace the catalog entirely.

## Overview

Every request's `User-Agent` is matched against the built-in ``AIAgentCatalog`` and your own ``BotKitConfiguration/Detection/customAgents``. An ``AIAgent`` has four fields:

- ``AIAgent/token``: the distinctive substring to look for in the header, such as `ChatGPT-User`. Matched case-insensitively, anywhere in the header.
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

The longest token that appears in the header wins. That matters because tokens overlap: `Applebot-Extended` contains `Applebot`, and the two mean different things. A shortest-first match would file every `Applebot-Extended` training fetch under AI search. Your custom agents take part in the same longest-first ordering as the built-in ones.

Pick a token that is specific enough not to appear inside ordinary browser user agents, and long enough not to be swallowed by a longer built-in token.

``AIAgentCatalog/match(userAgent:)`` does the same lookup against the built-in catalog alone, which is handy in tests. ``AIAgentCatalog/all`` lists every built-in agent.

### Finding agents the catalog misses

The raw `User-Agent` is stored, truncated to 512 characters, on every recorded row. Only matched requests are recorded, though, so an agent that matches nothing leaves no trace. If you suspect one, search your access logs, then add it here. Consider reporting it upstream too, so the next catalog regeneration includes it: see <doc:KeepingTheCatalogFresh>.
