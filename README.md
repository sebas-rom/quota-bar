# QuotaBar — minimal menu bar for opencode-go + Codex

MIT. Native SwiftUI, local-first. No browser scraping, no keychain scraping.

Menu shows e.g. `Go 85% · Cx 20%`. Click for two provider cards with per-window
percentages, progress bars, reset countdowns, and footer actions.

## Uninstalling old OpenCode Bar

```sh
pkill -x "OpenCode Bar"
# remove Login Item: System Settings > General > Login Items > OpenCode Bar > -
rm -rf "/Applications/OpenCode Bar.app"
rm -f ~/Library/Preferences/com.copilotmonitor.CopilotMonitor.plist
rm -rf ~/Library/Caches/com.copilotmonitor.* ~/Library/Application\ Support/CopilotMonitor
```

## Data sources (read-only, except the key you choose to save)

| Slot | Source | Call |
|---|---|---|
| opencode-go | Keychain (entered in-app) → `~/.config/quota-bar/opencode-go.json` `{"apiKey"}` → `$OPENCODE_GO_API_KEY` → opencode `auth.json` `opencode-go` entry | `GET https://opencode.ai/zen/go/v1/usage` |
| Codex | `~/.codex/auth.json` → `tokens.access_token` (+ `account_id`) | `GET https://chatgpt.com/backend-api/wham/usage` |

No working Go key anywhere? The menu offers **Enter API key…**: paste your
opencode Personal API key, it validates against `/usage` immediately, and on
success stores it in **macOS Keychain** (`com.quota.bar`). Forget it anytime
via **Forget saved API key**. Nothing is ever logged; only presence/source is shown.

Go states are explicit: ready (5h/7d/30d + resets), no key, rejected 401,
no-subscription 403, rate-limited 429, provider 5xx, offline, unexpected.
The headline always shows the most-consumed window (e.g. `Go 85% · 5h`);
`rate-limited` counts as a real quota state, missing windows are never shown as 0%.

## Build / run / test

Requires macOS 13+, Xcode 15+ / Swift 5.9+.

```sh
swift test   # mocked parser + taxonomy tests
make app     # -> QuotaBar.app (LSUIElement, menu-bar only)
make run     # launch
make zip     # -> QuotaBar.zip (shareable)
```

Auto-refresh every 5 min + ⌘R. Launch-at-login toggle in the footer (SMAppService).

## Open-source + downloadable

1. `git init && git add -A && git commit -m "v0.2.0" && gh repo create quota-bar --public --source=. --push`
2. Tag `v0.2.0` → `.github/workflows/release.yml` builds `QuotaBar.zip` on the GitHub Release.
3. (Optional) Homebrew cask snippet in a later release.

Personal/beta = unsigned ZIP, labeled as such. Public distribution = Developer ID
+ notarization first (deferred).

## Limits

- Codex uses the ChatGPT OAuth token; API-key-only setups need an external usage endpoint (out of scope for v1).
- No Sparkle auto-update in v1 — re-download the zip.
