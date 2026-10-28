# Decisions

## 2026-10-27 — Provider layout is presentation-only

**Status:** accepted.

**Context.** Ordering and visibility were hardcoded to `ProviderID.allCases`, so
the popover, menu bar and History could not be arranged, and a provider could not
be removed from the glance surface without also losing its history.

**Decision.** `ProviderLayout` (order, hidden set, menu-bar style) is stored as
one JSON value in UserDefaults and consumed only by presentation. Hiding a
provider removes its card and its menu-bar percentage; the app keeps probing and
storing it, History keeps every provider (labelled "Hidden in overview"), and
its own alert switch still applies. A warning for a hidden provider appears in
the popover only while alerts for that provider are enabled. The
machine-readable contract (`qbar --status-json`) and alert identity never consult
the layout.

**Consequences.**

- Absent, corrupt, duplicate or unknown persisted ids normalize to a
  deterministic layout; providers added later are appended so they cannot be
  invisible after an update.
- Menu-bar style is a separate preference; hiding every provider falls back to
  the icon without rewriting the stored style.
- History remains the complete analytical surface, so hiding can never be used
  as data deletion.

## 2026-10-27 — Notarization deliberately deferred

**Status:** accepted.

**Context.** QuotaBar is distributed directly (ZIP + Sparkle), not through the App
Store. A Developer ID certificate and notarization require an Apple Developer
Program membership (US$99/year). The current audience is the maintainer and a
small circle of friends.

**Decision.** Do not enroll in the Apple Developer Program or notarize releases
at this time. This is a deliberate trade-off, not an unfinished step.

**Consequences.**

- First launch on a normally configured Mac requires right-click → **Open**
  (documented in `INSTALL.md`). No `xattr -dr` workaround is supported.
- macOS does not register ad-hoc apps with Notification Center, so quota alerts
  use the in-app panel fallback. This is why real notifications are unavailable.
- No Homebrew cask: a cask for an unnotarized app would need quarantine
  weakening, which defeats the point. A cask is deferred with notarization.
- Checksums prove integrity, not publisher identity. Sparkle’s EdDSA signature
  still protects every update archive.
- No `curl | bash` installer is offered.

**Revisit when** any of these becomes true:

- distribution grows beyond a small trusted circle;
- system notifications become important enough to pay for them;
- a Homebrew cask is wanted;
- users report repeated Gatekeeper friction.

The implementation plan is ready in [`docs/SIGNING.md`](SIGNING.md); it stays
disabled until a certificate exists.

## 2026-10-27 — Alerts use episodes on rolling windows

A rolling window's reset advances continuously (measured: ~170 distinct reset
values/day), so a reset-derived dedupe key re-arms an alert every few minutes.
Rolling windows therefore use a threshold **episode**: one 90% warning and one
independent limit escalation per episode, re-armed only after usage falls below
85%. Fixed-cycle windows keep the reset-bucket key. One classification
(`WindowSemantics`) is shared by alerts, history and the popover so the surfaces
cannot disagree. Persistence is part of the evaluation call (`AlertEngine.run`),
so a recovery transition is stored even when it produces no alert; otherwise the
next crossing would stay suppressed after a restart.

## 2026-10-27 — Rolling vs fixed quota windows

Go's 5-hour window and Codex's primary 5-hour window report a reset that advances
with time (measured: 167 and 88 distinct reset values over one day). They are
**rolling** windows, not fixed cycles. QuotaBar shows them as a trailing 5-hour
frame with a 2-hour projection; fixed windows (weekly/monthly, Command Code 5h)
keep cycle charts. Replay scoring excludes rolling windows because
crossing-before-reset has no stable cycle boundary to score.

## 2026-10-27 — Agent status is read-only and store-backed

`qbar --status-json` reads the latest persisted observation per window. It does
not trigger a network probe, start the GUI, or print credentials. `observedAt`,
`ageSeconds`, `origin` and `stale` are always present so an agent can decide
whether the data is usable. See [`docs/STATUS.md`](STATUS.md).
