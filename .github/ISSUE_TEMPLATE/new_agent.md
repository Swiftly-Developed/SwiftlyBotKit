---
name: New AI agent
about: Report an AI agent the catalog does not recognise or classifies wrongly
title: "Agent: "
labels: catalog
assignees: ""
---

<!--
The built-in catalog is generated from ai-robots-txt/ai.robots.txt.
If the agent is missing there too, consider reporting it upstream as well:
https://github.com/ai-robots-txt/ai.robots.txt
Until it is added, you can recognise it yourself with
BotKitConfiguration.detection.customAgents.
-->

## Agent

- User agent token (the distinctive substring, for example `ChatGPT-User`):
- Full user-agent string seen in your logs:
- Operator (company or project):

## Missing or misclassified?

- [ ] Missing: SwiftlyBotKit does not recognise it
- [ ] Misclassified: it is recognised with the wrong purpose or operator

## Purpose

Which fits best?

- [ ] `training`: collecting content to train a model
- [ ] `aiSearch`: indexing pages to cite in AI answers
- [ ] `userTriggered`: fetching a page because a person asked an assistant
- [ ] `agent`: an autonomous or coding agent working on a task
- [ ] `scraper`: harvesting for datasets, resale or image corpora

## Sources

<!-- Links to the operator's documentation for the agent, and to published IP ranges if there are any. -->

- Documentation:
- Published IP ranges (JSON feed URL, if any):
- Does it respect robots.txt, according to the operator?
