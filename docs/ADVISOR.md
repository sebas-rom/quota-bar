# Next-task advice

QuotaBar can answer one narrow question above the cards: **which provider still
has quota for the task I am about to start?**

It is off by default. Turn it on in **Settings → General → Show quota
availability**. The **Forecast task length** picker next to it (25 minutes,
1 hour, 3 hours) only affects the 5-hour forecast captions — eligibility itself
is provider-scope and does not depend on the task. The same decision is
available to scripts and agents through `qbar --advise-json`.

The feature exists because three providers now share one menu bar: when one is
out, "which one do I use?" is a real question. What it deliberately does **not**
do matters just as much as what it does.

## What it never claims

- **No cross-provider score or ranking.** The providers report different units:
  Go reports a percentage of a model allowance, Command Code reports credit
  values against a 5-hour and a weekly cap, Codex reports plan- and
  model-dependent buckets. A single "best provider" number would be fabricated.
- **No confidence percentage.** A reading is either fresh and complete or it is
  not; there is no intermediate certainty to print.
- **No model-level routing.** "Go is the better choice for Claude" is not
  observable from the quota endpoints, so `scope` is always `"provider"`.
- **No exhaustion predictions.** Advice reads current headroom only. The
  separate forecast (History and the 5-hour caption) remains the only predictive
  surface, and it never drives alerts or provider switching.
- **No notifications.** Advice is a display, a CLI document and two explicit
  settings — nothing is pushed.

## Eligibility

One value per provider, computed from that provider's atomic current state:

| Eligibility | Meaning |
|---|---|
| `available` | Fresh, complete network reading; the most-used window is below 90%. |
| `constrained` | Same, but the most-used window is at or above 90%. Usable, flagged. |
| `exhausted` | A window reports the limit reached, or is at 100% used. |
| `unknown` | The evidence cannot prove anything: no reading, failed probe, stalled reading, local log only, 429, or a reading that lost one of the provider's required windows. |

Two strengths of exhaustion are kept apart: a provider-reported flag is
authoritative and says **"limit reached"** for the exact window the provider
named; a computed 100% says **"at 100% used"**, because no provider said the
window was blocked. The named window — not the highest percentage on the card —
is what the verdict points at.

`unknown` is never rendered as 0% and never treated as "available". Every
`unknown`/`constrained`/`exhausted` verdict carries at least one stable reason
code:

| Reason code | Emitted when |
|---|---|
| `no_observation` | No current state for that provider yet. |
| `probe_failed` | The last probe failed; retained numbers are not a live reading. |
| `stale` | The observation is older than `staleAfterSeconds` (900s). |
| `local_log_only` | Numbers came from the Codex session log, not the network. |
| `incomplete_snapshot` | A reading exists but is not a fresh, complete network sample. |
| `rate_limited` | The provider answered 429; that says "not now", not "0% left". |
| `quota_exhausted` | A window is exhausted: either the provider flagged it (`isLimited`, headline "limit reached") or it stands at 100% used (headline "at 100% used"). |
| `nearing_limit` | The limiting window is at or above 90%. |
| `eligible` | Nothing is wrong with this provider's reading. |
| `provider_unconfigured` | The last probe failed because the provider has no credentials at all. |
| `single_eligible_provider` | Selection: exactly one provider is viable. |
| `multiple_viable_providers` | Selection: more than one provider is viable. |
| `no_eligible_provider` | Selection: nothing can be proven usable. |

## Recommendation

| Status | When | `providerId` |
|---|---|---|
| `ok` | Exactly one provider is viable (`available`/`constrained`) and every other participating provider is positively out of quota. | that provider |
| `conditional` | Exactly one provider is viable, but at least one other participating provider is `unknown`. | that provider |
| `unknown` | Zero or two-plus providers are viable. | `null` |

A provider participates unless its state says it has no credentials. A provider
with **no state at all** participates as `unknown`: it may simply not have
answered yet, and one fresh reading must not become "the only provider with
quota" while two cards are still checking.

**Complete is a claim about windows, not about decoding.** Each adapter drops
windows it cannot parse, so "we got a reply" is not enough: Go must expose its
5-hour, weekly and monthly windows, Codex its primary and secondary buckets,
Command Code its 5-hour and weekly caps. The monthly window is required for Go
because it can be the only limiting window (the live reading on this machine is
exhausted exactly there). A reply that lost one of those is stored as
`partial` and the provider reads as `unknown`, because a missing 5-hour bucket
must never be mistaken for headroom on the limit it would have shown.

`unknown` is a real answer, not a failure: "two providers have quota, pick by
model or habit" is more useful than an arbitrary winner. The summary text is
nouns and counts only — it has no scores, percentages of confidence, or
superlatives.

**Providers that are not set up do not participate.** A provider with no
credentials is still listed (chip plus `provider_unconfigured`) but is not an
"alternative" — otherwise "the only provider with quota" could never be said on
a machine where the third CLI was never installed. A provider that is set up but
whose reading is stale, partial or failed does participate, and makes the answer
`conditional`.

## Data source: current state, not history

Advice reads `provider_state` (store schema v2): one atomic record per provider,
written whole by the same probe result that updates the cards. History rows are
per window, so a reader that took the newest row per window could stitch two
probes — or two accounts — into one imaginary snapshot. The atomic record makes
that impossible, carries the probe outcome separately from the observations, and
is cleared by **Clear History** so advice never stands on erased evidence.

The store schema is additive: `sample` keeps its v1 shape and meaning, and
`--status-json` continues to describe history exactly as before. **Clear
History** deletes current state in the same transaction and records a cutoff that
later state writes honour, in the store **and** in the model: a probe that
started before the deletion cannot restore erased advice either on disk or in the
popover. The one exception is a fresh failure that retains no windows (for
example "no credentials"), which carries no erased quota and is stored so the
advice can still say the provider is unconfigured. The row reports no reading
until the next refresh (at most five minutes).

## `qbar --advise-json`

```sh
/Applications/QuotaBar.app/Contents/MacOS/qbar --advise-json
/Applications/QuotaBar.app/Contents/MacOS/qbar --advise-json --task-minutes 60
```

Read-only: no GUI, no network probe, no credentials, no history rows. It opens
the local store, evaluates the persisted current state with the same pure
function the popover uses, and prints one document. Exit codes: `0` = document
written, `2` = no store / unreadable store (an error document is printed).

`--task-minutes` accepts `1…1440`; anything else is ignored rather than
rejected. The provider-scope decision does not depend on it — it is echoed back
so a caller can correlate the advice with its own request.

```json
{
  "generatedAt" : "2026-10-28T14:00:51Z",
  "providers" : [
    {
      "eligibility" : "exhausted",
      "headline" : "Monthly limit reached · 37h 25m left",
      "id" : "opencode-go",
      "limitingWindowId" : "go.monthly",
      "name" : "OpenCode Go",
      "reasonCodes" : [ "quota_exhausted" ]
    },
    {
      "eligibility" : "available",
      "headline" : "5-hour 10% used · 4h 31m left",
      "id" : "codex",
      "limitingWindowId" : "codex.primary",
      "name" : "Codex",
      "reasonCodes" : [ "eligible" ]
    },
    {
      "eligibility" : "available",
      "headline" : "Weekly 44% used · 5d left",
      "id" : "commandcode",
      "limitingWindowId" : "commandcode.weekly",
      "name" : "Command Code",
      "reasonCodes" : [ "eligible" ]
    }
  ],
  "recommendation" : {
    "reasonCodes" : [ "multiple_viable_providers" ],
    "status" : "unknown",
    "summary" : "2 providers still have quota — pick by model or habit"
  },
  "schemaVersion" : 1,
  "scope" : "provider",
  "staleAfterSeconds" : 900,
  "taskMinutes" : 60
}
```

The advice schema is versioned **independently** of `--status-json` (which stays
at `schemaVersion: 1` for its observation contract). Consumers should ignore
unknown fields; new reason codes are additive.

## Duration hint

When advice is on, a **non-rolling** 5-hour window can replace its usual
forecast caption with a task-aware one:

> At recent pace, 95% in ~30m — inside your 1h task

It only appears when the existing forecast already projects a 95% crossing
within the 2-hour horizon **and** that crossing falls inside the selected task
length. Rolling windows (Go's 5-hour, Codex's primary) are excluded because
their reset advances with time; a fixed-cycle window is the only place the
comparison is stable. It never says "exhausted", "blocked", or "guaranteed", and
it never fires when the forecast itself is an abstention.

## Settings

| Preference | Default | Effect |
|---|---|---|
| `AdvisorEnabled` | `false` | Adds the "Quota availability" popover row and the task-aware caption. |
| `AdvisorTaskMinutes` | `60` | Task length used by that caption (25/60/180); it does not change eligibility. |

Advice is a presentation and CLI feature: hiding a provider in Settings still
lets it be recommended, because advice describes quota, not layout.
