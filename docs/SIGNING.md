# Signing & notarization (deliberately deferred)

**Status: deferred by decision (2026-10-27).** See
[`DECISIONS.md`](DECISIONS.md). This plan is ready to execute if that decision
changes; nothing below is enabled in CI.

QuotaBar currently ships **ad-hoc signed**. That is enough for Sparkle’s EdDSA
archive verification, but it costs users real friction:

- Gatekeeper warns on first launch (right-click → Open).
- macOS does not register ad-hoc apps with Notification Center, so alerts use the
  in-app panel fallback.
- Checksums prove integrity, not publisher identity.

**Notarization is the next distribution step.** It requires an Apple Developer
Program membership (US$99/year). This document is the implementation plan; the
workflow stays ad-hoc until the certificate and secrets exist.

## What changes

### 1. Certificate and keychain

- Create a **Developer ID Application** certificate.
- Export it as `.p12`; store `DEVELOPER_ID_P12` (base64) and
  `DEVELOPER_ID_PASSWORD` as GitHub Actions secrets.
- Import into a temporary keychain in CI.

### 2. Sign every nested component

Sparkle ships nested XPC services and helpers. Sign inside-out:

```sh
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  QuotaBar.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  QuotaBar.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  QuotaBar.app/Contents/Frameworks/Sparkle.framework
codesign --force --options runtime --timestamp --sign "$IDENTITY" QuotaBar.app
codesign --verify --deep --strict --verbose=2 QuotaBar.app
```

Replace the ad-hoc `codesign --force --deep --sign -` in `make app` with this
path when `DEVELOPER_ID_IDENTITY` is present; keep ad-hoc for local dev builds.

### 3. Notarize, staple, then re-package

```sh
ditto -c -k --sequesterRsrc --keepParent QuotaBar.app QuotaBar-notarize.zip
xcrun notarytool submit QuotaBar-notarize.zip --keychain-profile "quotabar" --wait
xcrun stapler staple QuotaBar.app
xcrun stapler validate QuotaBar.app
codesign --verify --deep --strict QuotaBar.app
spctl --assess --type execute --verbose QuotaBar.app   # must be accepted
```

A ZIP cannot hold the staple ticket itself; staple the `.app`, then create the
final ZIP **after** stapling. Order matters:

1. sign → 2. notarize → 3. staple → 4. zip → 5. SHA-256 → 6. Sparkle EdDSA sign
→ 7. publish alias/checksums/appcast.

Signing the archive before these steps invalidates the EdDSA signature.

### 4. CI secrets

- `DEVELOPER_ID_P12`, `DEVELOPER_ID_PASSWORD`
- `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` (or an App Store Connect
  API key)
- Existing `SPARKLE_PRIVATE_KEY`

Keep every secret out of logs; clean up the temporary keychain at job end.

### 5. Verify the unlock

- `spctl --assess` accepts the installed app on a normally configured Mac.
- First launch needs no right-click.
- Sparkle still updates from the previous version.
- Notification Center registration is **re-tested**; ad-hoc builds are excluded
  today, signed builds may work but must be proven.
- Re-run the ad-hoc `--notification-diagnose` to confirm the delivery path flips
  to `notification-center`.

## Until then

- Keep publishing `QuotaBar.zip`, `checksums.txt` and the versioned asset.
- Keep INSTALL.md’s honest Gatekeeper guidance; never recommend `xattr -dr`.
- Do not ship a Homebrew cask or a `curl | bash` installer that would bypass
  Gatekeeper; a cask pins to a notarized build with a SHA-256.
