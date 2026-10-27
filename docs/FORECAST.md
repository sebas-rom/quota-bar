# Forecast replay

`qbar --forecast-backtest` is a read-only diagnostic. It never starts the GUI,
probes a provider, writes history, or reads credentials.

```sh
/Applications/QuotaBar.app/Contents/MacOS/qbar --forecast-backtest
```

`insufficient_data` is the expected initial result: the gate needs many complete
cycles, and the local store currently holds days, not months.

## What is scored

- Fixed-cycle windows only: Go weekly/monthly, Codex secondary, Command Code
  5h/weekly/monthly.
- **Rolling 5-hour windows are excluded** (Go rolling, Codex primary). Their
  reported reset advances with time; a fixed cycle boundary is not observable,
  so crossing-before-reset cannot be scored without inventing one.
- Network observations only. Local-log backfills, demo data, and stale rows never
  affect metrics.
- Predictions at a checkpoint use **only** observations available at that
  checkpoint (causal replay) and the unchanged `ForecastEngine.analyze`.

## Outcomes and censoring

A cycle is `crossed` only when a below-95% observation is followed by a
≥95% observation before the reset. Otherwise it is `did_not_cross` (complete
evidence through the end), `censored` (missing coverage near reset or gaps), or
`ambiguous` (bad reset metadata / unbracketed crossing). Only the first two enter
the confusion matrix; missing data is never a true negative.

## Schema (v1)

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-10-27T20:00:00Z",
  "targetPercent": 95,
  "checkpointMinutes": 30,
  "status": "insufficient_data",
  "groups": [{
    "provider": "codex",
    "windowId": "codex.secondary",
    "status": "insufficient_data",
    "counts": { "completeCycles": 4, "crossingCycles": 1, "nonCrossingCycles": 3,
                "eligibleCheckpoints": 24, "classifiableCheckpoints": 18,
                "abstentions": 7, "truePositives": 2, "falsePositives": 0,
                "trueNegatives": 9, "falseNegatives": 0 },
    "excluded": { "incompleteCycle": 2, "samplingGap": 1,
                  "ambiguousReset": 0, "unknownOutcome": 1 },
    "metrics": { "precision": 1.0, "falsePositiveRate": 0.0,
                 "recallAt30m": null, "coverage": 0.6111,
                 "etaMaeMinutes": null, "etaP90Minutes": null }
  }]
}
```

- `status`: `pass`, `fail`, or `insufficient_data`. The top-level status is
  `fail` if any group fails, else `insufficient_data` if any group lacks evidence.
- Metrics with a zero denominator are `null`, never `0`.
- Exit 0 for a report (including insufficient data); exit 2 for an unreadable
  store or encode failure.

## Gate (per provider/window)

At least 20 complete cycles, 8 crossing and 8 non-crossing, 50 classifiable
checkpoints, 15 positive and 15 negative predictions; precision ≥85%, false
positive rate ≤10%, recall at ≥30 min lead ≥50%, ETA MAE ≤20 min, P90 ≤45 min.

The gate is diagnostic. It does not automatically hide the forecast line in the
app; a failed, independently valid replay is a maintenance decision. See
[`DECISIONS.md`](DECISIONS.md).
