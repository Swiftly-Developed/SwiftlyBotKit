# AI referrals

Count the people who arrive from an AI assistant's answer, not just the agents that read your pages.

## Overview

An AI search crawler indexing a page and a person clicking through from the answer it produced are two halves of the same story. SwiftlyBotKit records both, and the dashboard shows them side by side.

A request is an AI referral when its `Referer` header points at a known AI assistant, such as `https://chatgpt.com/c/...` or `https://claude.ai/chat/...`. Browser analytics can in principle see these visits too, but analytics is often consent-gated, and a good share of visitors never accept. SwiftlyBotKit records them server-side, from a header the browser already sends, and stores no address: only a keyed hash of it.

### How a referral is stored

Referrals go into the same `ai_bot_visits` table as agent visits and share every filter and date bucket. They are told apart by which columns are set:

| Column | Agent visit | AI referral |
|---|---|---|
| `agent_name` | the matched token, such as `ChatGPT-User` | `NULL` |
| `purpose` | the agent's ``AIAgentPurpose`` | `NULL` |
| `referrer_platform` | `NULL` | the assistant, such as `ChatGPT` |
| `verification` | verified, unverified or spoofed | ``BotVerification/notApplicable`` |

When a request matches both an agent and an assistant referrer, it is recorded once, as an agent visit.

### Recognised assistants

``LLMReferrer/builtInPlatforms`` covers ChatGPT, Claude, Perplexity, Gemini, Copilot, Grok, Le Chat, You.com, Poe and Phind, including their older domains. Several hosts map to one name, so `chat.openai.com` and `chatgpt.com` both count as `ChatGPT`.

The list is limited to the hosts where people read assistant answers. `openai.com`, `claude.com` and `x.ai` are deliberately absent: they host company pages and developer documentation (`platform.openai.com`, `docs.claude.com`, `docs.x.ai`), and a reader following a link from API docs was not referred by an answer. Grok inside X is not listed either, because its referrer is plain `x.com`, indistinguishable from any other link on X.

The Android apps of ChatGPT (`com.openai.chatgpt`), Claude (`com.anthropic.claude`), Perplexity (`ai.perplexity.app.android`), Gemini (`com.google.android.apps.bard`), Copilot (`com.microsoft.copilot`) and Grok (`ai.x.grok`) send `android-app://<package>/` as the referrer, and are recognised by that package name.

A ``LLMReferrer/Platform/hostSuffix`` matches the referrer's host exactly or as a dot-separated suffix: `perplexity.ai` covers `www.perplexity.ai` but not `notperplexity.ai`, and `chatgpt.com` does not match `chatgpt.com.evil.test`. Case, a trailing dot on the host (`chatgpt.com.`) and leading dots on the suffix (`.example.com`) make no difference, and an empty suffix matches nothing. For an `android-app://` referrer the package name must equal the suffix exactly.

A `Referer` without a scheme is accepted too. Its host runs up to the first `/`, `?`, `#` or `:` (after any `user@`), so `evil.com?x=.chatgpt.com` is read as `evil.com`.

### Adding an assistant

```swift
config.detection.customReferrers = [
    LLMReferrer.Platform(hostSuffix: "chat.deepseek.com", name: "DeepSeek"),
    LLMReferrer.Platform(hostSuffix: "kagi.com", name: "Kagi"),
]
```

A custom entry with the same host suffix as a built-in one replaces it, which is how you rename a platform. Custom entries are checked first. To match only your own list, set ``BotKitConfiguration/Detection/includesBuiltInReferrers`` to `false`.

You can use the same matching outside the middleware with ``LLMReferrer/platform(forReferer:)`` and ``LLMReferrer/platform(forReferer:in:)``.

### Limits

- Many assistants strip or shorten the referrer, and some open links with no `Referer` at all. The count is a floor, not a total.
- Only the page a visitor lands on is recorded. Later pages in the same visit carry your own domain as the referrer.

### Turning it off

```swift
config.recording.recordsReferrals = false
```
