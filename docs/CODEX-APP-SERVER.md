# Codex from the local app-server

QuotaBar normally reads Codex quota from the same private endpoint the ChatGPT
web UI uses (`GET https://chatgpt.com/backend-api/wham/usage`) with the OAuth
token already in `~/.codex/auth.json`. That works, but it is an undocumented
surface and it only returns percentages.

The Codex CLI ships a typed local RPC — `codex app-server` — that exposes the
same numbers plus the buckets, plan and credit inventory the CLI itself works
with. QuotaBar can read Codex from there instead. It is **opt-in** and never the
default.

## Choosing a source

**Settings → General → Codex reading** (stored in `UserDefaults` key
`CodexSource`):

| Source | Behaviour | Network |
|---|---|---|
| `HTTP` (default) | The private endpoint, as before. | one request to `chatgpt.com` |
| `Codex app-server` | The CLI's local RPC **only**. If it cannot answer, the card reports the failure instead of silently switching. | none |
| `Automatic` | The RPC when it answers, the HTTP endpoint otherwise. | only on fallback |

Strict `appServer` exists on purpose: it is the "QuotaBar makes no web request"
choice, so a quiet fallback would break the promise the user just made. The
spawned CLI may itself use the network on its own (it is the vendor's process,
not a socket opened here) — the guarantee is about QuotaBar's transport. `Automatic` is the "prefer the richer payload, never blank the card"
choice.

## What is called, and what never is

The transport is newline-delimited JSON-RPC over the child's stdin/stdout, in
this order:

1. `initialize` with `clientInfo: { name: "quotabar", version: "1.0" }`.
2. `account/rateLimits/read` with an empty params object.

That is the whole conversation. The same protocol also exposes
`account/rateLimitResetCredit/consume` — a **mutating** call that spends a reset
credit. QuotaBar never calls it, and the client has no code path that could: the
only methods are the two string constants above.

Result fields QuotaBar uses:

```json
{
  "ordinaryUsageAllowed": true,
  "rateLimits": {
    "primary":   { "usedPercent": 10, "windowDurationMins": 300,   "resetsAt": 1793211010 },
    "secondary": { "usedPercent": 2,  "windowDurationMins": 10080, "resetsAt": 1793797810 },
    "credits":   { "hasCredits": false, "unlimited": false, "balance": "0" },
    "planType": "plus",
    "rateLimitReachedType": null
  },
  "rateLimitsByLimitId": { "codex": { "...": "..." } },
  "rateLimitResetCredits": { "availableCount": 2 }
}
```

- `primary` → `codex.primary` (5-hour), `secondary` → `codex.secondary`
  (weekly). Extra buckets in `rateLimitsByLimitId` become
  `codex.extra.<id>.primary|secondary`.
- `rateLimitReachedType` marks the bucket the provider says is exhausted; a
  window is only flagged limited when that is set **and** it is at 99%+.
- `resetCreditsAvailable` and a non-zero credit balance become the card's facts
  line, exactly like the HTTP path.
- `accountId` is hashed with the same short stable hash as every other account
  reference; the raw id never reaches the UI, disk or logs.

## Process discipline

The CLI is a child process, so the rules are stricter than for a URL fetch:

- **Located, never resolved by shell.** `codex` is looked up in
  `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.bun/bin`,
  `~/.npm-global/bin`, then `PATH`. A menu-bar app inherits launchd's `PATH`,
  which on a normal Mac contains none of those — this is the single most common
  reason a CLI "works in the terminal" but not in the app.
- **Read-only, argument-free.** The executable is run as `codex app-server`
  with no interpolated strings. The **app-server transport** does not open
  anything under `~/.codex`; the CLI owns its credential handling. (The rest of
  the app does read Codex's session logs for its local-log fallback and history
  backfill, which is a separate, documented path.)
- **Hard timeout, always reaped.** One deadline (12s) covers the handshake and
  the read. On return — success, timeout or error — the child gets `SIGTERM`
  and then `SIGKILL`, `waitUntilExit()` reaps it, and the pipes are closed so the
  CLI's own inner process sees EOF.
- **No raw diagnostics.** stderr and JSON-RPC error text are inspected for a
  sign-in hint and then discarded; they can contain tokens or private paths. Only
  a fixed category reaches the card, the store or the probe output.
- **`poll`-based pipe IO.** `FileHandle.read(upToCount:)` on a `Process` pipe can
  block indefinitely on current macOS, which would have made the timeout
  meaningless: an unresponsive child would hang the refresh task forever. The
  reader uses `poll` + `read` with the deadline enforced between chunks. A
  regression test runs a child that never answers and asserts the probe fails in
  well under a second and a half.

## Validating it by hand

```sh
/Applications/QuotaBar.app/Contents/MacOS/qbar --codex-app-server-probe
```

It prints one JSON document and exits `0` (ok) or `2` (failure); nothing is
persisted and no credential is printed:

```json
{
  "accountRef" : "6370d0a4d1",
  "binary" : "/opt/homebrew/bin/codex",
  "creditBalance" : "0",
  "ok" : true,
  "ordinaryUsageAllowed" : true,
  "plan" : "plus",
  "resetCreditsAvailable" : 2,
  "windows" : [
    { "id" : "codex.primary", "label" : "5-hour", "limitReached" : false,
      "percentUsed" : 10, "resetsAt" : "2026-10-28T18:32:42Z", "windowMinutes" : 300 },
    { "id" : "codex.secondary", "label" : "Weekly", "limitReached" : false,
      "percentUsed" : 2, "resetsAt" : "2026-11-04T13:32:42Z", "windowMinutes" : 10080 }
  ]
}
```

Use it after upgrading the CLI, before trusting the card.

## Failure modes

| Condition | `appServer` | `automatic` |
|---|---|---|
| CLI not installed / not on a known path | card error (`providerDown`, "codex CLI not found…") | falls back to HTTP |
| CLI installed but not signed in | card error (`noCredentials`) | falls back to HTTP |
| Child starts but never answers | card error after 12s | falls back to HTTP |
| Unexpected payload / protocol change | card error (`badResponse`) | falls back to HTTP |
| Reply without a required bucket (`primary`/`secondary`) | card shows what it got; the reading is `partial`, so advice reports the provider as unknown | same |
| `rateLimitReachedType` names one bucket | only that bucket is flagged limited; a 99% bucket the provider did not name is not | same |

A card error retains the last good snapshot, so history and the menu bar do not
blank out while the source is broken.

## Known limits

- The app-server protocol is typed but not a public compatibility promise; the
  probe command is the way to check it after a CLI update.
- Only the `codex` account the CLI is signed into is read. Multi-account setups
  must switch the CLI, exactly as the CLI itself requires.
- The RPC starts a process on every refresh (5 minutes); there is no long-lived
  connection, deliberately — a resident child holding a pipe is a worse failure
  mode than a short-lived one.
