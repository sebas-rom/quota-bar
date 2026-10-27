# `qbar --status-json`

Read-only machine-readable status for local agents and scripts. It reads the
latest persisted observation per provider/window from
`~/Library/Application Support/QuotaBar/telemetry.sqlite`; it does **not** start
the GUI, trigger a network probe, or print credentials.

```sh
/Applications/QuotaBar.app/Contents/MacOS/qbar --status-json
```

Exit codes: `0` = document written, `2` = no store / unreadable store (an
`{"schema_version":1,"error":"…"}` document is printed).

## Schema (v1)

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-10-27T17:34:39Z",
  "staleAfterSeconds": 900,
  "fresh": true,
  "providers": [
    {
      "id": "codex",
      "name": "Codex",
      "plan": "plus",
      "windows": [
        {
          "id": "codex.primary",
          "label": "5-hour",
          "percentUsed": 30,
          "resetsAt": "2026-10-27T21:03:29Z",
          "observedAt": "2026-10-27T17:33:29Z",
          "origin": "network",
          "ageSeconds": 70,
          "stale": false
        }
      ]
    }
  ]
}
```

## Contract

- `percentUsed` is **used** percentage points (0–100+ if a provider reports
  overage). It is not a remaining percentage.
- `origin` is `network` for live probes and `localLog` for the Codex session-log
  fallback. Do not treat `localLog` as a live reading.
- `stale` is true when `ageSeconds >= staleAfterSeconds` (15 minutes). `fresh` is
  true when at least one window is not stale.
- `observedAt`/`resetsAt` are ISO-8601 UTC.
- Windows are provider-specific; compare within a provider, not across providers.
- No email, account id, token, prompt or message content is included.
- The document reflects persisted data only. If it is stale, ask the user to open
  QuotaBar or wait for the next sample; do not invent a refresh.
- Schema changes bump `schemaVersion`. Unknown fields should be ignored.
