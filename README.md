# QuotaBar

[![Release](https://img.shields.io/github/v/release/sebas-rom/quota-bar)](https://github.com/sebas-rom/quota-bar/releases/latest)
[![License](https://img.shields.io/github/license/sebas-rom/quota-bar)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](https://github.com/sebas-rom/quota-bar)
[![Swift](https://img.shields.io/badge/swift-5.9-orange)](https://github.com/sebas-rom/quota-bar)

Minimal macOS menu-bar for **opencode-go + Codex quotas**. Native SwiftUI,
local-first, accessible. No browser scraping, no keychain scraping.

Menu shows e.g. `Go 85% · Cx 20%`. Click for two provider cards with per-window
percentages, progress bars, reset countdowns, and a compact footer.

## Install

Download [**QuotaBar.zip**](https://github.com/sebas-rom/quota-bar/releases/latest),
unzip, drag `QuotaBar.app` to `/Applications`, launch. Toggle **Launch at login**
in the ⋯ menu. No setup needed if your keys are already on disk (see below).

## Data sources (read-only, except the key you choose to save)

| Slot | Source | Call |
|---|---|---|
| opencode-go | Keychain (entered in-app) → `~/.config/quota-bar/opencode-go.json` `{"apiKey"}` → `$OPENCODE_GO_API_KEY` → opencode `auth.json` `opencode-go` entry | `GET https://opencode.ai/zen/go/v1/usage` |
| Codex | `~/.codex/auth.json` → `tokens.access_token` (+ `account_id`) | `GET https://chatgpt.com/backend-api/wham/usage` |

No working Go key anywhere? The menu offers **Enter API key…**: paste your
opencode Personal API key, it validates against `/usage` immediately, and on
success stores it in **macOS Keychain**. Remove it anytime via
**Remove Saved Go Key…** (with confirmation — your OpenCode/Codex credentials
are untouched). Nothing is ever logged; only presence/source is shown.

Go states are explicit: ready (5h/7d/30d + resets), no key, rejected 401,
no-subscription 403, rate-limited 429, provider 5xx, offline, unexpected.
The headline always shows the most-consumed window (e.g. `Go 85% · 5h`);
`rate-limited` counts as real quota, missing windows are never shown as 0%.

## Privacy

Local-only. QuotaBar talks directly to the two provider APIs above using tokens
already on your machine. No third-party servers, no analytics, no tracking.

## Build / test

Requires macOS 13+, Xcode 15+ / Swift 5.9+.

```sh
swift test   # mocked parser + taxonomy tests
make app     # -> QuotaBar.app (LSUIElement, menu-bar only)
make run     # launch
make zip     # -> QuotaBar.zip (shareable)
```

Auto-refresh every 5 min + `R`. VoiceOver labels on every quota row.

## Collaborate

All changes via pull request — `main` is protected, @sebas-rom reviews everything.
See [CONTRIBUTING.md](CONTRIBUTING.md) (scope guardrails included),
[SECURITY.md](SECURITY.md) for private vulnerability reports.

## Limits

- Codex uses the ChatGPT OAuth token; API-key-only setups need an external usage endpoint (out of scope for v1).
- No Sparkle auto-update — re-download the zip.
- Beta releases are unsigned (labeled as such); public distribution will add Developer ID + notarization first.
