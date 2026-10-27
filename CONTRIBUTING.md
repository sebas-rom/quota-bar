# Contributing to QuotaBar

All changes go through pull requests against `main` — direct pushes are blocked.
The maintainer (@sebas-rom) reviews and merges; nothing lands without approval.

## Scope guardrails (please read before proposing features)

QuotaBar stays deliberately small:

- **Three shipped providers**: opencode-go, Codex, Command Code. No arbitrary
  provider-configuration engine. A new provider is a typed adapter plus the shared display contract —
  the cards and charts must not learn provider names.
- **Local-first**: read credentials already on disk; never scrape browsers, never
  touch the Keychain except the key the user explicitly enters in-app.
- **Official sources only**: provider HTTP APIs, documented CLIs, or read-only
  files the provider already writes (e.g. Codex session logs). No HTML scraping.
- **Telemetry is opt-out and non-invasive**: quota observations only. No prompts,
  transcripts, tokens, emails or account ids in the store; account identity is
  hashed. History must be deletable in one action.
- **Native + accessible**: SwiftUI, system colors/materials only, VoiceOver labels
  on every new row/control, no hardcoded dark-mode styling.

Proposals outside this scope will be politely declined — that's a feature, not a bug.

### Release signing

Updates are signed with Sparkle's EdDSA key. The public key lives in
`Info.plist` (`SUPublicEDKey`); the private key is the `SPARKLE_PRIVATE_KEY`
GitHub Actions secret and must never be committed. Losing it means users have to
reinstall manually.

## Workflow

```sh
git checkout -b feat/short-name
swift test        # must stay green
swift build -c release
make app && make run   # smoke-test the installed bundle, light + dark mode
./scripts/capture-ui.sh   # refresh docs/evidence when UI changes
make install              # replace /Applications/QuotaBar.app and relaunch
make update               # pull + build + install (dev update loop)
```

- Parser/decoder changes need mocked fixture tests in `Tests/QuotaBarKitTests` (see `GoUsageTests`: 0.5%-stays-0.5%, rate-limited, partial/malformed cases).
- UI changes need: VoiceOver label/value/hint, keyboard reachability, and the exact microcopy used.
- No secrets in code, fixtures, logs, or screenshots. The secret scanner + review will catch it; save everyone time.

## Releases

Maintainer only: bump `appVersion` + `Info.plist`, update README, commit,
`git tag vX.Y.Z && git push --tags` — CI attaches `QuotaBar.zip` to the GitHub Release.
