## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

## How it was tested

<!-- Tests added or updated, and any manual check (for example the dashboard in Examples/QuickStart). -->

## Checklist

- [ ] `swift build` and `swift test` pass
- [ ] New or changed `public` API has `///` doc comments, and the README and DocC are updated to match
- [ ] Linux-compatible: no `Date.formatted`, no `CGFloat`, no Apple-only frameworks
- [ ] Text from the database is escaped before it reaches markup
- [ ] `AIAgentCatalogData.swift` was regenerated with the script, not edited by hand (if touched), and the "unclassified fallback" count was reviewed
- [ ] `CHANGELOG.md` has a line under Unreleased for user-visible changes

<!--
SwiftlyBotKit is mirrored from a monorepo. Accepted pull requests are applied
upstream and arrive here with the next mirror push, so this pull request may be
closed rather than merged. Your authorship is kept.
-->
