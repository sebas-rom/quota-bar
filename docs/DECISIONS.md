# Decisions

## 2026-10-28 — 0.12.1: reachable controls, honest labels, fewer decorations

**Status:** accepted.

**Context.** Two everyday complaints exposed a navigation and interaction problem
rather than a styling one: the manual update check had moved into Settings while
the documentation still pointed at the ⋯ menu, and the card's disclosure control
was an 11pt chevron glyph. A UX review of the whole popover also found a claim
it did not support (the advice row's "Next task · 60 min" implied that
eligibility depended on task length) and duplicated affordances.

**Decision.** Restore *Check for Updates…* as the first ⋯ item (⌘U) and keep
Settings → General for configuration; remove the duplicate Settings… item and
move ⌘, to the gear. Make the entire card header the disclosure button (32pt,
chevron trailing after the plan, one VoiceOver button with an Expanded/Collapsed
value); reserve the chevron slot on non-expandable headers so plan labels align.
Rename the advice row to *Quota availability*, drop the task length from its
header (duration only affects the 5-hour forecast caption) and remove its
Settings… link. Drop the setup card's filler sentence once a provider is
configured. Give the footer icon controls 28pt targets, and call the History
button what it is.

The popover sparkline is removed. It had no period, scale or label, appeared only
for windows with enough samples (so card heights varied), and answered a question
History answers properly. `TrendCoverage` and `QuotaModel.cycleTrend` went with
it rather than staying as unused "in case" code. History keeps every chart.

Command Code's "Renews <date>" fact stays model-level. Suppressing it whenever a
monthly window exists was tried and reverted: a compact card shows only the
limiting window, so the monthly row (and with it the only visible renewal date)
can be hidden. A repeated date in the expanded view is preferable to a missing
date in the default one; a presentation-aware rule would be the only correct
version of the suppression.

**Consequences.**

- Two paths to update for two intents, one path to Settings.
- Disclosure works with a pointer, Return/Space and VoiceOver; no tiny target.
- The availability row can no longer be read as a duration-aware recommendation;
  `--advise-json` is untouched.
- Cards are shorter and consistent; the popover is a status surface.

## 2026-10-28 — Advice fails closed, and untrusted diagnostics stay out

**Status:** accepted.

**Context.** A review of the 0.12 batch found that several failure paths were
more optimistic than the product's own invariants: a strict local-only Codex
source could be dropped when the store failed to open, a network reply that had
lost a required window could be read as complete, a provider that had not
answered yet could be excluded from the decision, Clear History did not protect
against an in-flight probe, and child-process diagnostics could reach persisted
state.

**Decision.** Every one of those paths now fails closed. The chosen
`CodexSource` survives a store failure. Completeness requires each provider's
core windows (Go 5-hour/weekly/monthly, Codex primary/secondary, Command Code
5-hour/weekly). A provider with no reading yet counts as unresolved. Current
state honours the same deletion cutoff as history. A provider-reported limit is
distinguished from a computed 100%, and only the bucket named by
`rateLimitReachedType` is flagged. App-server failures collapse to fixed
categories; stderr and JSON-RPC text are inspected for a sign-in hint and then
discarded. `--status-json` keeps its exit-2 contract when encoding fails.

**Consequences.**

- Advice can say "unknown" more often (first launch, partial replies), which is
  the intended trade: a conservative abstention beats a confident wrong answer.
- The app-server source is now safe to describe as "no QuotaBar network
  request", not "no network at all": the spawned CLI is the vendor's process.
- Diagnostics that would help debugging are deliberately not persisted or
  printed; the probe command reports a fixed reason instead.

## 2026-10-28 — Advice reads atomic current state, and is versioned separately

**Status:** accepted.

**Context.** The advisor needs to know "what is true for this provider right
now". History is stored per window, so a reader that took the newest row per
window could combine windows written by different probes, or by different
accounts after a sign-in change, into a snapshot that never existed. The
provider units are also not comparable (percent-of-allowance vs credit value vs
plan-dependent buckets), so a single cross-provider score would be invented.

**Decision.** Store schema v2 adds `provider_state`: one whole record per
provider, carrying generation, observation time/origin, plan, account ref,
completeness, last probe outcome and the windows written together. History
(`sample`) is untouched, so charts, replay and `--status-json` v1 keep their
meaning. `Advisor` reads only `provider_state` and emits
`available|constrained|exhausted|unknown` plus stable reason codes; a
recommendation is `ok` only when exactly one provider is viable and every
alternative is positively out of quota, `conditional` when another provider is
unknown, and `unknown` otherwise. The advice document has its own
`schemaVersion: 1`, independent of the status contract. Clearing history also
clears current state.

**Consequences.**

- A stale, failed, local-log-only or 429 reading can never be shown as headroom,
  and a failed probe never becomes 0%.
- Complete means "the provider's required windows are present", not "the adapter
  decoded something": Go needs its 5-hour, weekly and monthly windows, Codex its
  primary and secondary buckets, Command Code its 5-hour and weekly caps. A reply that
  lost one is partial, so a missing 5-hour bucket cannot be read as headroom.
- The advice row is hidden until a full refresh pass finishes, so persisted
  advice is never shown beside a card that is still checking.
- The chosen Codex source survives a store failure: the degraded model is built
  with the same `CodexSource`, so strict local-only mode cannot silently become
  an HTTP request when the database is unreadable.
- Two viable providers produce "pick by model or habit", not an arbitrary
  winner; there is no confidence number or ranking field to misuse. A provider
  with no reading yet is unresolved, so one fresh reading cannot be called "the
  only provider with quota" while the others are still checking; only an
  explicit no-credentials state sits outside the decision.
- The popover row, the Settings toggles and `--advise-json` share one pure
  function, so the surfaces cannot disagree.
- Window forecastability moved to `WindowSemantics.isForecastable`; the old
  `kind == .rolling || .primary` checks silently broke when Command Code's
  5-hour window became `.primary`.

## 2026-10-28 — Codex can read from the CLI's local app-server

**Status:** accepted.

**Context.** Codex numbers normally come from the private
`chatgpt.com/backend-api/wham/usage` endpoint. The installed CLI exposes a typed
local RPC (`codex app-server`) with the same buckets plus plan and reset-credit
inventory, and some users would rather not have QuotaBar call the web endpoint
at all.

**Decision.** `CodexSource` is a user preference with three values: `http`
(default, unchanged), `appServer` (local RPC only — a failure is reported on the
card, never silently replaced by HTTP) and `automatic` (RPC, then HTTP). Only
`initialize` and `account/rateLimits/read` are called; the protocol's mutating
`account/rateLimitResetCredit/consume` is never used. The child runs with a hard
deadline, `poll`-based pipe IO, `SIGTERM`/`SIGKILL` plus `waitUntilExit()` to
reap, and fixed error categories (child diagnostics are never persisted or
printed).
`qbar --codex-app-server-probe` validates the path by hand.

**Consequences.**

- Strict mode is honest about its promise (no network request) and its cost (a
  missing, unsigned-out or updated CLI is visible, not masked).
- The pipe reader cannot hang the refresh task: `FileHandle.read(upToCount:)` on
  a `Process` pipe can block indefinitely on current macOS and would have
  defeated the timeout.
- Account identity is hashed with the existing short-hash helper; the raw id is
  never displayed, stored or logged.

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
