# QuotaBar — minimal macOS menu bar for opencode-go + Codex

MIT. Single Swift file. Local-auth only, no keychain scraping, no browser automation.

Menu shows e.g. `Go 34% · Cx 61%`. Click for 5h / weekly / monthly + plan + refresh.

## Uninstalling old OpenCode Bar

```sh
pkill -x "OpenCode Bar"
# remove Login Item: System Settings > General > Login Items > OpenCode Bar > -
rm -rf "/Applications/OpenCode Bar.app"
rm -f ~/Library/Preferences/com.copilotmonitor.CopilotMonitor.plist
rm -rf ~/Library/Caches/com.copilotmonitor.* ~/Library/Application\ Support/CopilotMonitor
```

## Data sources (read-only, files already on disk)

| Slot | File | Call |
|---|---|---|
| opencode-go | `~/.local/share/opencode/auth.json` → `opencode-go.key` | `GET https://opencode.ai/zen/go/v1/models` (key check + model count) |
| opencode-go % | optional `~/.config/quota-bar/opencode-go.json` `{workspaceId, authCookie}` or `OPENCODE_GO_WORKSPACE_ID` + `OPENCODE_GO_AUTH_COOKIE` | `GET https://opencode.ai/workspace/<id>/go` → parses `rollingUsage` / `weeklyUsage` / `monthlyUsage` |
| Codex | `~/.codex/auth.json` → `tokens.access_token` (+ `account_id`) | `GET https://chatgpt.com/backend-api/wham/usage` |

No creds without workspace linkage: Go shows `key OK (N models) · link dashboard for %`. That keeps v1 extremely simple — dashboard HTML parsing is the only fragile part, isolated to one function.

Optional dashboard link file:

```json
{ "workspaceId": "wrk_ABC…", "authCookie": "auth=…" }
```

Get the cookie by visiting `opencode.ai/workspace/<id>/go` once in Chrome and copying the `auth` cookie. Env vars work too.

## Build / run

Requires macOS 13+, Xcode 15+ / Swift 5.9+.

```sh
make app   # -> QuotaBar.app (LSUIElement, menu-bar only)
make run   # launch
make zip   # -> QuotaBar.zip (shareable)
```

Auto-refresh: on open + every 5 min (add a Timer in `QuotaBarApp.swift` if you want background polling; v1 refreshes on open + ⌘R).

## Open-source + downloadable

1. `git init && git add -A && git commit -m "v0.1.0" && gh repo create quota-bar --public --source=. --push`
2. Tag `v0.1.0` → `.github/workflows/release.yml` builds `QuotaBar.zip` and attaches it to the GitHub Release.
3. (Optional) Homebrew tap:
   ```ruby
   cask "quota-bar" do
     version "0.1.0"
     url "https://github.com/YOU/quota-bar/releases/download/v0.1.0/QuotaBar.zip"
     app "QuotaBar.app"
   end
   ```

## Limits

- Go % needs workspace cookie; without it you get key-valid only (by design, simplest).
- Codex uses ChatGPT OAuth token; API-key-only setups need an external usage endpoint (out of scope for v1).
- No Sparkle auto-update in v1 — re-download the zip.
