#!/usr/bin/env python3
"""Regenerates SwiftlyBotKit's agent catalog from the upstream ai.robots.txt list.

    python3 Scripts/generate-ai-agent-catalog.py

Run it from the package root (the output path is resolved relative to this
script, so any working directory works). Fetches
https://raw.githubusercontent.com/ai-robots-txt/ai.robots.txt/main/robots.json
and rewrites Sources/SwiftlyBotKit/Catalog/AIAgentCatalogData.swift.

Upstream's `function` field is free text: around 70 distinct values across 175
agents, and the agents that matter most (GPTBot, ClaudeBot, PerplexityBot,
CCBot, Google-Extended) are all prose rather than one of the taxonomy labels.
So PURPOSE_OVERRIDES below is the hand-maintained truth for the agents we
actually report on, TAXONOMY maps upstream's newer labels, and KEYWORDS is a
last-resort guess for the long tail. Review the "unclassified" warnings this
prints after every regeneration.
"""
import json
import os
import re
import sys
import urllib.request

SOURCE = "https://raw.githubusercontent.com/ai-robots-txt/ai.robots.txt/main/robots.json"
PACKAGE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_RELATIVE = "Sources/SwiftlyBotKit/Catalog/AIAgentCatalogData.swift"
OUTPUT = os.path.join(PACKAGE_ROOT, OUTPUT_RELATIVE)

# Hand-audited. These are the agents whose numbers we quote, so they are never
# left to the keyword guesser.
PURPOSE_OVERRIDES = {
    # Training crawls: content feeds a model, no attribution, ever.
    "GPTBot": "training",
    "ClaudeBot": "training",
    "anthropic-ai": "training",
    "Google-Extended": "training",
    "CCBot": "training",
    "Bytespider": "training",
    "meta-externalagent": "training",
    "FacebookBot": "training",
    "Applebot-Extended": "training",
    "Diffbot": "training",
    "omgili": "training",
    "Kangaroo Bot": "training",
    "PanguBot": "training",
    "Baiduspider-ERNIE": "training",
    "Qwenbot": "training",
    "YandexAdditional": "training",
    "AI2Bot": "training",
    "Ai2Bot-Dolma": "training",
    # AI search indexing: you can be cited from this.
    "OAI-SearchBot": "aiSearch",
    "Claude-SearchBot": "aiSearch",
    "PerplexityBot": "aiSearch",
    "Amazonbot": "aiSearch",
    "Applebot": "aiSearch",
    "MistralAI-User": "aiSearch",
    "YouBot": "aiSearch",
    "phindbot": "aiSearch",
    "Devin": "agent",
    # User-triggered: a person asked a question and the assistant fetched
    # this page to answer it, live. The most valuable bucket we record.
    "ChatGPT-User": "userTriggered",
    "Claude-User": "userTriggered",
    "Perplexity-User": "userTriggered",
    "cohere-ai": "userTriggered",
    "CCBot-User": "userTriggered",
    "DuckAssistBot": "userTriggered",
    "Gemini-Deep-Research": "userTriggered",
    "Google-CloudVertexBot": "training",
}

# Upstream's newer, consistent labels.
TAXONOMY = {
    "AI Assistants": "userTriggered",
    "AI Search Crawlers": "aiSearch",
    "AI Agents": "agent",
    "AI Coding Agents": "agent",
    "Undocumented AI Agents": "agent",
    "AI Data Scrapers": "scraper",
    "AI Data Providers": "scraper",
}

# Last resort for the prose entries we have not audited. Order matters.
KEYWORDS = [
    ("user-initiated", "userTriggered"),
    ("user prompt", "userTriggered"),
    ("user queries", "userTriggered"),
    ("assistant", "userTriggered"),
    ("search", "aiSearch"),
    ("train", "training"),
    ("llm training", "training"),
    ("machine learning", "training"),
]


def purpose_for(name, entry):
    if name in PURPOSE_OVERRIDES:
        return PURPOSE_OVERRIDES[name], "override"
    function = (entry.get("function") or "").strip()
    if function in TAXONOMY:
        return TAXONOMY[function], "taxonomy"
    haystack = (function + " " + (entry.get("description") or "")).lower()
    for needle, purpose in KEYWORDS:
        if needle in haystack:
            return purpose, "keyword"
    return "scraper", "fallback"


def clean_operator(raw):
    """Upstream mixes bare names and markdown links: `Google` vs `[OpenAI](url)`."""
    if not raw:
        return "Unknown"
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", raw).strip()
    if text.lower().startswith("unclear"):
        return "Unknown"
    return text


def clean_respect(raw):
    """`Yes`, `No`, `[Yes](url)`, `Unclear at this time.` -> yes/no/unknown."""
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", raw or "").strip().lower()
    if text.startswith("yes"):
        return "yes"
    if text.startswith("no"):
        return "no"
    return "unknown"


def main():
    with urllib.request.urlopen(SOURCE) as response:
        agents = json.load(response)

    rows, stats = [], {"override": 0, "taxonomy": 0, "keyword": 0, "fallback": 0}
    for name in sorted(agents, key=str.lower):
        entry = agents[name]
        # Tabs and newlines would break the TSV; no upstream value has them today.
        if "\t" in name or "\n" in name:
            print(f"skipping {name!r}: contains a separator", file=sys.stderr)
            continue
        purpose, how = purpose_for(name, entry)
        stats[how] += 1
        rows.append("\t".join([name, purpose, clean_operator(entry.get("operator")),
                               clean_respect(entry.get("respect"))]))

    body = "\n".join(rows)
    swift = f'''// Generated by Scripts/generate-ai-agent-catalog.py. Do not edit by hand.
//
// Source: {SOURCE}
// Upstream is MIT licensed. Agents: {len(rows)}.
//
// Columns, tab separated: user-agent token, purpose, operator, respects robots.txt.
// Purpose is OUR classification, not upstream's: see the script for how each row
// was decided and which agents are hand-audited.

enum AIAgentCatalogData {{
    /// One agent per line. Parsed once, lazily, by `AIAgentCatalog`.
    static let tsv = """
{body}
"""
}}
'''
    with open(OUTPUT, "w") as handle:
        handle.write(swift)

    print(f"wrote {OUTPUT_RELATIVE}: {len(rows)} agents")
    print(f"  hand-audited overrides : {stats['override']}")
    print(f"  upstream taxonomy      : {stats['taxonomy']}")
    print(f"  keyword guess          : {stats['keyword']}")
    print(f"  unclassified fallback  : {stats['fallback']}  <- review these")


if __name__ == "__main__":
    main()
