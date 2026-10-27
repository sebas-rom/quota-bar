# Installing QuotaBar

QuotaBar is a macOS 13+ menu-bar app distributed as a ZIP. **Notarization is
deliberately deferred** while there is no Apple Developer membership
([DECISIONS.md](docs/DECISIONS.md)), so Gatekeeper warns on first launch. This
page documents the supported path; do not strip quarantine flags or bypass
Gatekeeper.

## Requirements

- macOS 13 Ventura or newer.
- No installer, daemon, or admin password. The app is a single `.app` bundle.
- Existing credentials on disk are enough for Codex and Command Code; opencode-go
  can use a Personal API key entered in the app.

## Install (stable)

```sh
cd ~/Downloads
curl -fLO https://github.com/sebas-rom/quota-bar/releases/latest/download/QuotaBar.zip
curl -fLO https://github.com/sebas-rom/quota-bar/releases/latest/download/checksums.txt
grep '  QuotaBar.zip$' checksums.txt | shasum -a 256 -c -
unzip -q QuotaBar.zip
mv QuotaBar.app /Applications/
open /Applications/QuotaBar.app
```

Prefer Finder? Use the same
[direct download](https://github.com/sebas-rom/quota-bar/releases/latest/download/QuotaBar.zip),
unzip, and drag `QuotaBar.app` to `/Applications`.

### First launch (Gatekeeper)

Until the app is notarized, a normal Mac shows *“Apple could not verify
QuotaBar is free of malware”*:

1. Right-click `QuotaBar.app` → **Open** → **Open** again, **or**
2. System Settings → Privacy & Security → scroll down → **Open Anyway**.

Do **not** use `xattr -dr com.apple.quarantine`; that removes the protection
for every future download and is not supported.

## Pin a version (agents / reproducible installs)

Every stable tag carries the same two assets, so a pinned install never moves.

Agents can read status without the GUI (after installing):

```sh
/Applications/QuotaBar.app/Contents/MacOS/qbar --status-json
```

It exits 0 with a timestamped JSON document and 2 with an error document. See
[docs/STATUS.md](docs/STATUS.md). It never prints credentials and never triggers
a network probe.

```sh
VERSION=0.8.0
cd "$(mktemp -d)"
curl -fLO "https://github.com/sebas-rom/quota-bar/releases/download/v${VERSION}/QuotaBar.zip"
curl -fLO "https://github.com/sebas-rom/quota-bar/releases/download/v${VERSION}/checksums.txt"
grep '  QuotaBar.zip$' checksums.txt | shasum -a 256 -c -
unzip -q QuotaBar.zip
mkdir -p "$HOME/Applications"
mv QuotaBar.app "$HOME/Applications/"
open "$HOME/Applications/QuotaBar.app"
```

Agent rules:

- Install into `$HOME/Applications` (or a user-approved `--appdir`) — never
  overwrite an existing app silently, never request `sudo`.
- Verify `checksums.txt` before unzipping. A checksum is integrity, not
  independent publisher identity; until notarization exists, report that clearly.
- `codesign --verify --deep --strict QuotaBar.app` should pass (ad-hoc signature).
- `spctl --assess --type execute QuotaBar.app` will **reject** an unnotarized
  build on a normally configured Mac. Stop and tell the user instead of bypassing
  Gatekeeper.
- Never pipe a remote script into a shell.

## Setup

- **opencode-go**: ⋯ → **Enter API key…**, paste an opencode Personal API key. It
  is validated against `/usage`, stored in Keychain, and mirrored to
  `~/.config/quota-bar/opencode-go.json` (mode 0600) so updates do not re-prompt.
- **Codex**: sign in with the Codex CLI so `~/.codex/auth.json` exists.
- **Command Code**: set `COMMANDCODE_API_KEY`, or keep the key in
  `~/.config/opencode/opencode.json` under
  `providers.commandcode.settings.apiKey` (the official integration path).

## Updates

Sparkle 2 with Stable (tagged) and Nightly (main) channels. Use
⋯ → **Check for Updates…**; toggle the channel under ⋯ → **Update channel**.
Nightly is opt-in. Updates are Ed25519-signed and verified against the public key
inside the app.

## Diagnostics

- `QuotaBar.app/Contents/MacOS/QuotaBar --notification-diagnose` prints bundle id,
  notification authorization/settings, whether the build is ad-hoc, and the
  delivery path.
- History lives in `~/Library/Application Support/QuotaBar/telemetry.sqlite`.
  **Clear History…** wipes it. No prompts, tokens, emails or account ids are
  stored (account identity is a short hash).

## Uninstall

```sh
osascript -e 'quit app "QuotaBar"'
rm -rf /Applications/QuotaBar.app
rm -rf "$HOME/Library/Application Support/QuotaBar"
rm -f "$HOME/.config/quota-bar/opencode-go.json"
```

The Go key in Keychain can be removed from the app (⋯ → **Remove Saved Go Key…**)
or Keychain Access (`com.quota.bar`). Other apps’ credentials are untouched.

## Homebrew

A cask is deferred with notarization: an unnotarized cask would need quarantine
weakening. There is deliberately no `brew install` command and no `curl | bash`
installer until that decision changes.
