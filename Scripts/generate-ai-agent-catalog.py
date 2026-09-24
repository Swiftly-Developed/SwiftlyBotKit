#!/usr/bin/env python3
"""Regenerates SwiftlyBotKit's agent catalog from the upstream ai.robots.txt list.

    python3 Scripts/generate-ai-agent-catalog.py
    python3 Scripts/generate-ai-agent-catalog.py --from-existing

Run it from the package root (the output path is resolved relative to this
script, so any working directory works). Fetches
https://raw.githubusercontent.com/ai-robots-txt/ai.robots.txt/main/robots.json
and rewrites Sources/SwiftlyBotKit/Catalog/AIAgentCatalogData.swift.

`--from-existing` skips the fetch and re-runs only the clean-up below over the
rows already in AIAgentCatalogData.swift, so a change to the overrides or the
clean-up rules can land without pulling in new upstream data.

Upstream is a robots.txt list, and the matcher reads user-agent headers, so
every row is cleaned up before it is written:

- A trailing version (`MistralAI-User/1.0`, `Brightbot 1.0`) is stripped. The
  matcher wants the product name; the version changes and the purpose must not.
- Tokens are deduplicated case-insensitively (`meta-externalagent` and
  `Meta-ExternalAgent` are one agent). The hand-audited spelling wins, and
  known values (operator, robots.txt stance) fill in unknown ones.
- NOT_IN_USER_AGENTS drops tokens too generic to identify an AI agent in a
  user-agent header, even as a whole word (`Spider`, `Code`).

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
    "MistralAI-User": "userTriggered",  # Le Chat fetching a page a user asked about
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
    "meta-externalfetcher": "userTriggered",
}

# Valid robots.txt groups upstream, but as whole words in a user-agent header
# they match ordinary non-AI software, which would inflate every AI number.
NOT_IN_USER_AGENTS = {
    "Spider": "matches every search-engine crawler that calls itself a spider "
              "(Sogou web spider, Screaming Frog SEO Spider)",
    "Code": "matches VS Code and every other Electron app built on it (Code/1.93.1)",
}

# A trailing product version, as upstream sometimes lists the full product
# token rather than the name: `MistralAI-User/1.0`, `Brightbot 1.0`.
VERSION_SUFFIX = re.compile(r"[/ ]v?\d+(\.\d+)*$")

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


def normalize(records):
    """Strips versions, drops generic tokens and merges case-insensitive duplicates.

    `records` is a list of dicts with name, purpose, operator, respect, how.
    """
    dropped, merged, stripped = [], [], []
    by_key = {}
    override_keys = {name.lower(): name for name in PURPOSE_OVERRIDES}
    for record in records:
        name = record["name"]
        bare = VERSION_SUFFIX.sub("", name)
        if bare != name:
            stripped.append(f"{name} -> {bare}")
            record = dict(record, name=bare)
            name = bare
        if name in NOT_IN_USER_AGENTS:
            dropped.append(f"{name}: {NOT_IN_USER_AGENTS[name]}")
            continue
        key = name.lower()
        if key in by_key:
            merged.append(f"{by_key[key]['name']} + {name}")
            by_key[key] = merge(by_key[key], record, override_keys.get(key))
        else:
            by_key[key] = record

    rows = []
    for record in by_key.values():
        # Exact spelling, as in purpose_for: an override is applied only to
        # the row it was written for.
        if record["name"] in PURPOSE_OVERRIDES:
            record = dict(record, purpose=PURPOSE_OVERRIDES[record["name"]], how="override")
        rows.append(record)
    rows.sort(key=lambda r: (r["name"].lower(), r["name"]))
    return rows, dropped, merged, stripped


def merge(a, b, audited_name):
    """Two spellings of one agent. The hand-audited spelling's row leads; the
    other only fills in what the leader does not know."""
    if audited_name and b["name"] == audited_name and a["name"] != audited_name:
        a, b = b, a
    elif not audited_name and (b["name"].lower(), b["name"]) < (a["name"].lower(), a["name"]):
        a, b = b, a
    result = dict(a)
    if result["operator"] == "Unknown" and b["operator"] != "Unknown":
        result["operator"] = b["operator"]
    if result["respect"] == "unknown" and b["respect"] != "unknown":
        result["respect"] = b["respect"]
    return result


def fetch_records():
    with urllib.request.urlopen(SOURCE) as response:
        agents = json.load(response)
    records = []
    for name in agents:
        entry = agents[name]
        # Tabs and newlines would break the TSV; no upstream value has them today.
        if "\t" in name or "\n" in name:
            print(f"skipping {name!r}: contains a separator", file=sys.stderr)
            continue
        purpose, how = purpose_for(name, entry)
        records.append({"name": name, "purpose": purpose, "how": how,
                        "operator": clean_operator(entry.get("operator")),
                        "respect": clean_respect(entry.get("respect"))})
    return records


def existing_records():
    with open(OUTPUT) as handle:
        text = handle.read()
    body = text.split('static let tsv = """\n', 1)[1].rsplit('\n"""', 1)[0]
    records = []
    for line in body.split("\n"):
        columns = line.split("\t")
        if len(columns) != 4:
            continue
        name, purpose, operator, respect = columns
        records.append({"name": name, "purpose": purpose, "how": "existing",
                        "operator": operator, "respect": respect})
    return records


def main():
    from_existing = "--from-existing" in sys.argv[1:]
    records = existing_records() if from_existing else fetch_records()
    rows, dropped, merged, stripped = normalize(records)

    stats = {"override": 0, "taxonomy": 0, "keyword": 0, "fallback": 0, "existing": 0}
    for row in rows:
        stats[row["how"]] += 1
    body = "\n".join("\t".join([r["name"], r["purpose"], r["operator"], r["respect"]]) for r in rows)
    swift = f'''// Generated by Scripts/generate-ai-agent-catalog.py. Do not edit by hand.
//
// Source: {SOURCE}
// Upstream is MIT licensed. Agents: {len(rows)}.
//
// Columns, tab separated: user-agent token, purpose, operator, respects robots.txt.
// Purpose is OUR classification, not upstream's: see the script for how each row
// was decided and which agents are hand-audited. Versions are stripped, case
// variants merged and user-agent-generic tokens dropped: see the script.

enum AIAgentCatalogData {{
    /// One agent per line. Parsed once, lazily, by `AIAgentCatalog`.
    static let tsv = """
{body}
"""
}}
'''
    with open(OUTPUT, "w") as handle:
        handle.write(swift)

    print(f"wrote {OUTPUT_RELATIVE}: {len(rows)} agents"
          + (" (re-cleaned from the existing file, nothing fetched)" if from_existing else ""))
    for line in stripped:
        print(f"  version stripped       : {line}")
    for line in merged:
        print(f"  case duplicate merged  : {line}")
    for line in dropped:
        print(f"  dropped, too generic   : {line}")
    print(f"  hand-audited overrides : {stats['override']}")
    if from_existing:
        print(f"  kept as already classified: {stats['existing']}")
    else:
        print(f"  upstream taxonomy      : {stats['taxonomy']}")
        print(f"  keyword guess          : {stats['keyword']}")
        print(f"  unclassified fallback  : {stats['fallback']}  <- review these")


if __name__ == "__main__":
    main()
