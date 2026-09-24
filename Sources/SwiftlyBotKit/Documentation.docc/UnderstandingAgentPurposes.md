# Understanding agent purposes

Why a training crawl, an AI search crawl and a user-triggered fetch are different numbers, and how to read each one.

## Overview

"4,000 AI bot hits this week" says little. "Claude-User fetched your pricing page 30 times this week" says that people are asking an assistant about your pricing right now. The difference is the ``AIAgentPurpose`` of each visit, and it is the distinction the dashboard is built around.

The split is not a guess. The large operators run separate user agents for separate jobs, precisely so that site owners can tell them apart and allow or block each one on its own:

| Operator | Training | AI search | User-triggered |
|---|---|---|---|
| OpenAI | `GPTBot` | `OAI-SearchBot` | `ChatGPT-User` |
| Anthropic | `ClaudeBot` | `Claude-SearchBot` | `Claude-User` |
| Perplexity | | `PerplexityBot` | `Perplexity-User` |

### The five purposes

- ``AIAgentPurpose/userTriggered``: A person asked an assistant something, and it fetched this page live to answer them. This is the most commercially interesting bucket: a hit here is someone researching the topic of that page at that moment. `ChatGPT-User`, `Claude-User`, `Perplexity-User`.

- ``AIAgentPurpose/aiSearch``: The page is being indexed so it can be cited in an AI answer later. This is the AI equivalent of a search engine crawl, and being in the index is what makes a later citation possible. `OAI-SearchBot`, `Claude-SearchBot`, `PerplexityBot`.

- ``AIAgentPurpose/agent``: An autonomous or coding agent working through a task. `Devin`.

- ``AIAgentPurpose/training``: Content is being collected to train a model. You get no attribution, ever. `GPTBot`, `ClaudeBot`, `CCBot`, `Google-Extended`. (`Google-Extended` and `Applebot-Extended` are robots.txt tokens only: Google and Apple fetch as `Googlebot` and `Applebot`, so blocking them in robots.txt matters, but they rarely appear in a user-agent header.)

- ``AIAgentPurpose/scraper``: Harvesting for datasets, resale or image corpora. `Brightbot`, `FirecrawlAgent`.

``AIAgentPurpose/displayOrder`` lists them most valuable first. The dashboard's tiles, legend and stacked chart all follow that order.

### Where the classification comes from

The catalog is generated from the community ai.robots.txt list, but that list's own description field is free text: around 70 distinct values across some 175 upstream entries, and the most important entries are prose rather than a category. So the purpose attached to each agent here is this package's own classification. The generator keeps a hand-audited table for the agents that matter most, maps the upstream taxonomy labels where they exist, and falls back to a keyword guess for the long tail. See <doc:KeepingTheCatalogFresh>.

If you disagree with a classification, override it with a custom agent of the same token. See <doc:CustomAgents>.

### Reading the numbers

- A rising **user-triggered** line means assistants are sending people's questions to your pages. Look at the most-read pages to see which ones.
- **AI search** without **user-triggered** means you are indexed but not yet cited, or not for the questions people ask.
- **Training** volume says nothing about visibility. It is the bucket to look at when you decide what `robots.txt` should allow.
- An agent flagged as ignoring `robots.txt` has an operator who documents that it does not honour it (``AIAgent/respectsRobotsTxt`` is `false`). Its hits happen whatever your `robots.txt` says.

Every purpose count is only as trustworthy as the user agent behind it. Read it alongside the verification status: see <doc:IPVerification>.
