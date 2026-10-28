# Releasing QuotaBar

Two channels share one Sparkle appcast:

| Channel | Trigger | Release | Notes |
|---|---|---|---|
| Stable | tag `v*` | permanent tag | advertised to everyone |
| Nightly | push to `main` | `nightly` prerelease | opt-in via Settings → General → Channel |

## What CI does

`.github/workflows/release.yml`:

1. `swift test`, appcast tests, `make app` (ad-hoc signed, Sparkle embedded).
2. Stamps `CFBundleVersion` with a UTC timestamp (`%Y%m%d%H%M%S`).
3. Signs the bundle, zips it, signs the zip with the EdDSA key.
4. Publishes an immutable asset:
   - stable: `QuotaBar-<short>-<build>.zip` under the tag
   - nightly: `QuotaBar-<build>.zip` under the fixed `nightly` tag (assets accumulate)
5. Adds/updates an item in the `appcast` release's `appcast.xml`.

The app reads `https://github.com/sebas-rom/quota-bar/releases/download/appcast/appcast.xml`.

## Rules that keep updates working

- **Never replace a published archive.** CI reuses an existing stable ZIP on retry
  instead of rebuilding it. Nightly URLs are unique per build; old ones stay
  downloadable so cached feeds keep matching their EdDSA signature.
- **An existing feed is read strictly.** A download or parse failure fails the
  job; CI never regenerates a feed from scratch when one already exists.
  `scripts/appcast.py --require-existing` enforces this.
- **One signing key.** Public key is `SUPublicEDKey` in `Info.plist`; the private
  key is the `SPARKLE_PRIVATE_KEY` Actions secret plus a local backup at
  `~/.config/quota-bar/sparkle-private-key.txt` (mode 600). Never commit it.
  Losing it means every install must be replaced manually.
- **Only the newest nightly is advertised**, but previous nightly archives are
  kept on purpose. Do not prune assets still referenced by cached feeds.
- **Stable tags must advance the lineage.** Build numbers are publication time,
  so publishing an older commit later would produce a "newer" build.

## Recovery

| Situation | Action |
|---|---|
| Stable release exists **with** its ZIP | Re-run the workflow. It reuses the ZIP, re-signs those bytes, repairs the appcast. |
| Stable release exists **without** a ZIP | Do **not** delete or replace the release. Inspect what failed (upload/permissions), upload the intended ZIP manually under its `QuotaBar-<short>-<build>.zip` name, then re-run the workflow to repair the feed. |
| `appcast` release exists, `appcast.xml` missing | Treat as suspicious. Confirm whether the file was deleted or the release was just created; do not let CI invent a feed. Restore the previous feed (release history/PR artifacts) before republishing. |
| `appcast` release does not exist | Genuinely first publication; CI creates an empty feed and adds the first item. |
| Feed upload failed after the release | Re-run; the item is idempotent per build number. |
| Bad update shipped | Ship a higher build number. Sparkle does not downgrade. Never reuse a version/build. |

## First-install bootstrap (one time)

The Sparkle-enabled build must be installed manually once, because earlier
builds have no updater:

```sh
git checkout feat/updates   # after merge: main
make update                 # build + install + relaunch
```

After that, *Settings → General → Check Now* can replace the app in place.

## Acceptance before trusting the pipeline

Perform once on an unlocked Mac, recording source and destination builds:

1. Install a Sparkle-enabled build with a build number lower than the published
   nightly; confirm quotas and history work.
2. Publish a nightly; confirm the release asset name, appcast URL, length,
   `sparkle:version`, and EdDSA signature all match the ZIP.
3. Switch to Nightly in Settings → General, press *Check Now*, install, confirm the app quits,
   relaunches, and the bundle version increased.
4. Confirm telemetry history, Keychain access, and both provider probes survive.
5. Check again: no phantom update, no re-download.
6. Publish a second nightly: the old archive stays downloadable, the new one is
   offered, and switching back to Stable does not downgrade.
