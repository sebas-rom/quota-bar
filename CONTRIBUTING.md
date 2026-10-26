# Contributing to QuotaBar

All changes go through pull requests against `main` — direct pushes are blocked.
The maintainer (@sebas-rom) reviews and merges; nothing lands without approval.

## Scope guardrails (please read before proposing features)

QuotaBar stays deliberately small:

- **Two providers only**: opencode-go + Codex. No generic provider engine.
- **Local-first**: read credentials already on disk; never scrape browsers, never touch the Keychain except the key the user explicitly enters in-app.
- **Official APIs only**: no HTML scraping fallbacks unless an official endpoint is proven dead.
- **Native + accessible**: SwiftUI, system colors/materials only, VoiceOver labels on every new row/control, no hardcoded dark-mode styling.

Proposals outside this scope will be politely declined — that's a feature, not a bug.

## Workflow

```sh
git checkout -b feat/short-name
swift test        # must stay green
swift build -c release
make app && make run   # smoke-test the installed bundle, light + dark mode
```

- Parser/decoder changes need mocked fixture tests in `Tests/QuotaBarKitTests` (see `GoUsageTests`: 0.5%-stays-0.5%, rate-limited, partial/malformed cases).
- UI changes need: VoiceOver label/value/hint, keyboard reachability, and the exact microcopy used.
- No secrets in code, fixtures, logs, or screenshots. The secret scanner + review will catch it; save everyone time.

## Releases

Maintainer only: bump `appVersion` + `Info.plist`, update README, commit,
`git tag vX.Y.Z && git push --tags` — CI attaches `QuotaBar.zip` to the GitHub Release.
