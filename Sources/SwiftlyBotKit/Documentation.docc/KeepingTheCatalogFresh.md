# Keeping the catalog fresh

Regenerate the built-in agent catalog every quarter or so, and review what the generator could not classify.

## Overview

New AI agents appear constantly. An agent the catalog does not know is not recorded wrongly: it is not recorded at all, which makes the drift easy to miss. Regenerating the catalog roughly once a quarter keeps it current.

The catalog is generated from the community-maintained [ai.robots.txt](https://github.com/ai-robots-txt/ai.robots.txt) list, which is MIT licensed. It is compiled into the package, so there is no network access at runtime.

### Regenerating

From the package root:

```bash
python3 Scripts/generate-ai-agent-catalog.py
```

The script uses only the Python standard library. It downloads the current upstream list and rewrites `Sources/SwiftlyBotKit/Catalog/AIAgentCatalogData.swift`. Do not edit that file by hand; the next regeneration overwrites it.

Before writing, it cleans upstream's robots.txt names up for matching against user-agent headers:

- **Versions are stripped.** `MistralAI-User/1.0` becomes `MistralAI-User`, so an agent does not change purpose when it bumps its version.
- **Case variants are merged.** `meta-externalagent` and `Meta-ExternalAgent` are one agent. The spelling in the hand-audited table wins, and known operator and robots.txt values fill in unknown ones.
- **Generic words are dropped.** A few upstream entries, such as `Spider` and `Code`, are valid in robots.txt but, as words in a user-agent header, match ordinary software (Sogou's `web spider`, VS Code's `Code/1.93`). The `NOT_IN_USER_AGENTS` table in the script lists them with the reason.

It prints a summary, including every row the clean-up changed:

```
wrote Sources/SwiftlyBotKit/Catalog/AIAgentCatalogData.swift: 167 agents
  version stripped       : MistralAI-User/1.0 -> MistralAI-User
  case duplicate merged  : meta-externalagent + Meta-ExternalAgent
  dropped, too generic   : Spider: ...
  hand-audited overrides : ...
  upstream taxonomy      : ...
  keyword guess          : ...
  unclassified fallback  : ...  <- review these
```

### How each agent's purpose is decided

Upstream describes what each agent does in free text: around 70 distinct values across some 175 upstream entries, and the most important entries are prose rather than a category label. So ``AIAgent/purpose`` is this package's own classification, decided in this order:

1. **Hand-audited overrides.** A table in the script for the agents whose numbers people quote: `GPTBot`, `ClaudeBot`, `ChatGPT-User`, `Claude-User`, `PerplexityBot` and the rest of the major operators' agents. These are never left to a guess.
2. **Upstream taxonomy.** Entries that use one of upstream's newer category labels are mapped directly.
3. **Keyword guess.** The remaining descriptions are searched for telling words.
4. **Fallback.** Anything still unclassified becomes ``AIAgentPurpose/scraper``.

To change only the overrides or the clean-up rules without pulling in new upstream data, run the script with `--from-existing`. It re-applies them to the rows already in `AIAgentCatalogData.swift` and fetches nothing.

### After regenerating

1. Read the "unclassified fallback" count. Look up each agent that fell through and, if it matters, add it to the override table in the script and run it again.
2. Diff `AIAgentCatalogData.swift` to see which agents were added, removed or reclassified.
3. Run `swift test`. The catalog tests check that the major agents still match the purposes the dashboard relies on.

If an app needs a fix before the next release, it does not have to wait for one: a custom agent with the same token overrides the built-in entry. See <doc:CustomAgents>.

### Adding a purpose

``AIAgentPurpose`` raw values are also PostgreSQL enum labels and the catalog's purpose column. A new case therefore needs a migration that adds the label to the `ai_agent_purpose` type, and then a catalog regeneration, in that order.
