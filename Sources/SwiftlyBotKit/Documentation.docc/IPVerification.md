# IP verification

How SwiftlyBotKit checks that an agent is who it claims to be, and why some agents can only ever be unverified.

## Overview

A user-agent header is free text. Reporting from the large CDNs puts roughly one in twenty requests claiming to be a well-known AI crawler as forged, and `ChatGPT-User` is the most impersonated of all. That is also the most valuable bucket, so without a check it would be the least trustworthy number on the dashboard.

Several operators publish the IP ranges their agents fetch from. SwiftlyBotKit downloads those lists and checks each claimed agent's client IP against them, storing one of four ``BotVerification`` values:

- ``BotVerification/verified``: The client IP is inside the ranges the operator publishes for that agent.

- ``BotVerification/unverified``: The operator publishes no list SwiftlyBotKit checks, so the user agent is taken at its word. Most of the long tail lands here.

- ``BotVerification/spoofed``: The agent's operator does publish ranges, and the client IP is not in them (or there is no client IP). These rows are kept, not dropped: impersonation is a security signal in its own right.

- ``BotVerification/notApplicable``: An AI referral row. A human arrived from an assistant, and there is nothing to verify.

The dashboard's verified share is verified divided by verified plus spoofed. Unverified visits are left out, because they could not have been checked either way.

### The built-in feeds

``CrawlerRangeFeed/defaults`` covers OpenAI, Anthropic and Perplexity:

| Feed | Agents it vouches for |
|---|---|
| `openai.com/gptbot.json` | `GPTBot` |
| `openai.com/searchbot.json` | `OAI-SearchBot` |
| `openai.com/chatgpt-user.json` | `ChatGPT-User` |
| `claude.com/crawling/bots.json` | `ClaudeBot`, `Claude-User`, `Claude-SearchBot` |
| `perplexity.ai/perplexitybot.json` | `PerplexityBot` |
| `perplexity.ai/perplexity-user.json` | `Perplexity-User` |

### Not all verified badges are equal

OpenAI publishes a separate list per agent, so a verified `ChatGPT-User` hit was checked against the ChatGPT-User ranges specifically. Anthropic publishes one list for all three Claude agents, so a verified Claude hit proves the request genuinely came from Anthropic, and the user agent is what says which of the three it was. Both are far better than taking the header at its word, but they are not equally strong. Keep that in mind when a verified `Claude-User` count matters to a decision.

### Why Google and Common Crawl stay unverified

Google and Common Crawl ask site owners to verify their crawlers with forward-confirmed reverse DNS rather than a published range list. That is a DNS round trip per request. SwiftlyBotKit does not do it, so `Google-Extended`, `CCBot` and the other agents without a feed are always ``BotVerification/unverified``, never spoofed. That is a statement about what was checked, not a failure.

### How and when feeds are fetched

- The first agent visit after the process starts waits for the fetch, so the first minutes of traffic are not quietly mislabelled as unverified.
- After that, ranges are answered from memory. Once ``BotKitConfiguration/Verification/refreshInterval`` (12 hours by default) has passed, the next lookup starts a refresh in the background and does not wait for it.
- A feed that fails keeps the ranges already held for it. A total failure never wipes the cache, because that would turn every verified visit into a spoof.
- Each feed's body is decoded as JSON whatever `Content-Type` it is served with. Vendors do not agree on the header: one serves its list as `application/octet-stream`.

A feed that cannot be refreshed logs a warning that starts `Could not refresh AI crawler ranges from`. If you see it repeatedly, the agents that feed covers have fallen back to unverified.

Verification runs in the detached task that writes the row, so a feed fetch never delays a response.

### The client IP has to be right

Verification checks whatever address ``BotKitConfiguration/clientIP`` returns. If that address is one the client can choose, a spoofer can claim an operator's address and earn a verified badge. Read <doc:ClientIPAndProxies> before relying on these numbers.

### Adding your own feed

Any operator that publishes the same JSON shape can be added:

```json
{"prefixes": [{"ipv4Prefix": "192.0.2.0/24"}, {"ipv6Prefix": "2001:db8::/32"}]}
```

```swift
config.verification.feeds = CrawlerRangeFeed.defaults + [
    CrawlerRangeFeed(url: "https://acme.example/crawler-ranges.json", agentTokens: ["AcmeResearchBot"]),
]
```

``IPRange`` is the CIDR matcher behind the check. It handles IPv4, IPv6, and IPv4-mapped IPv6 addresses, which some dual-stack proxies pass along.

### Turning it off

With ``BotKitConfiguration/Verification/isEnabled`` set to `false`, no feed is ever fetched and every agent visit is stored as unverified. Rows already written keep the status they were given.
