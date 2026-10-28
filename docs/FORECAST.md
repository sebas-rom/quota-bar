# Forecast replay

`qbar --forecast-backtest` is a read-only diagnostic. It never starts the GUI,
probes a provider, writes history, or reads credentials.

```sh
/Applications/QuotaBar.app/Contents/MacOS/qbar --forecast-backtest
```

`insufficient_data` is the expected initial result: the gate needs many complete
cycles, and the local store currently holds days, not months.

## What is scored

- **Fixed-cycle 5-hour windows only** — currently Command Code's 5-hour window.
  It is the only window where (a) the app shows a forecast and (b) a reset
  boundary is stable enough to score.
- **Rolling 5-hour windows are not evaluated** (Go rolling, Codex primary). Their
  reported reset advances with time, so "crossing before reset" has no stable
  boundary; scoring them would require inventing an outcome contract. They are
  listed in the report's `notEvaluated` array with the reason.
- **Weekly and monthly windows are not scored.** The app does not show forecasts
  for them, and a 90-day retention window cannot hold the 20 complete cycles the
  gate requires, so including them would make the report permanently unable to
  pass.
- Network observations only. Local-log backfills, demo data, and stale rows never
  affect metrics.
- Predictions at a checkpoint use **only** observations available at that
  checkpoint (causal replay) and the unchanged `ForecastEngine.analyze`.

## Completeness

A cycle is scoreable only when all of these hold:

- its reset time has **already passed** (an ongoing cycle is `ongoingCycle`);
- the first observation is within 30 minutes of the cycle start;
- the last observation is within 15 minutes of the reset;
- no gap between consecutive observations exceeds 30 minutes.

Anything else is censored. Missing data is never scored as a successful negative.

## Outcomes and censoring

A cycle is `crossed` only when a below-95% observation is followed by a
≥95% observation before the reset. Otherwise it is `did_not_cross` (complete
evidence through the reset), `censored` (missing coverage near start/reset or
gaps), `ongoing` (reset in the future), or `ambiguous` (unbracketed crossing, or
an observation with no reset that cannot be attributed to a cycle). Only `crossed`
and `did_not_cross` enter the confusion matrix.

Checkpoints that are retrospective (`already95`, or after the crossing) are
counted in `excludedCheckpoints`, separately from engine abstentions
(`collecting` / `unavailable`).

## Schema (v1)

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-10-27T20:00:00Z",
  "targetPercent": 95,
  "checkpointMinutes": 30,
  "status": "insufficient_data",
  "groups": [{
    "provider": "commandcode",
    "windowId": "commandcode.5h",
    "status": "insufficient_data",
    "counts": { "completeCycles": 4, "crossingCycles": 1, "nonCrossingCycles": 3,
                "eligibleCheckpoints": 24, "classifiableCheckpoints": 18,
                "abstentions": 7, "excludedCheckpoints": 2,
                "truePositives": 2, "falsePositives": 0,
                "trueNegatives": 9, "falseNegatives": 0 },
    "excluded": { "ongoingCycle": 0, "incompleteCycle": 2, "samplingGap": 1,
                  "ambiguousReset": 0, "unknownOutcome": 1 },
    "metrics": { "precision": 1.0, "falsePositiveRate": 0.0,
                 "recallAt30m": null, "coverage": 0.6111,
                 "etaMaeMinutes": null, "etaP90Minutes": null }
  }],
  "notEvaluated": [
    { "provider": "opencode-go", "windowId": "go.rolling",
      "reason": "rolling 5-hour window: reset advances with time, no fixed cycle to score" }
  ]
}
```

- `status`: `pass`, `fail`, or `insufficient_data`. The top-level status is
  `fail` if any group fails, else `insufficient_data` if any group lacks evidence.
- Metrics with a zero denominator are `null`, never `0`.
- `recallAt30m` is opportunity-based: the denominator is every crossing cycle
  that offered at least one checkpoint with ≥30 minutes of lead, whether or not
  the engine emitted a prediction. An engine that stays silent through a crossing
  therefore scores zero recall, not a missing value.
- Exit 0 for a report (including insufficient data); exit 2 for an unreadable
  store or encode failure. The error document uses the same `schemaVersion` key
  as the report, so one decoder handles both.

## Gate (per provider/window)

At least 20 complete cycles, 8 crossing and 8 non-crossing, 50 classifiable
checkpoints, 15 positive and 15 negative predictions; precision ≥85%, false
positive rate ≤10%, recall at ≥30 min lead ≥50%, ETA MAE ≤20 min, P90 ≤45 min.

The gate is diagnostic. It does not automatically hide the forecast line in the
app; a failed, independently valid replay is a maintenance decision. See
[`DECISIONS.md`](DECISIONS.md).

## Known limits

- Replay reads up to 20,000 observations per window, newest first, so retention
  trims the oldest data rather than the most recent.
- Replay is not account-scoped. It currently scores one window only; before
  extending it to Codex, account identity must be carried through.
