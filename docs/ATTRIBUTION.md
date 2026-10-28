# Local per-project attribution — design (not built)

**Status:** proposed. Nothing in the app reads project activity today; this
document exists so the idea is specified before code, and so the parts that are
easy to get wrong (privacy, confidence, cost) are decided up front.

## The question

QuotaBar already answers "how much of my allowance is left?" and "where should
the next task go?" (`docs/ADVISOR.md`). The natural follow-up is:

> Which of my projects is using this quota?

A user with three repositories and two CLIs cannot currently tell whether last
week's monthly exhaustion came from the big refactor, from an agent left running
in a scratch folder, or from another tool entirely.

## Why not now

- It is a **different data product**: local activity metadata, not provider
  quota. The quota contracts (`--status-json` v1, `--advise-json` v1) must not
  grow fields for it.
- The sources are other tools' private stores. They change shape without notice,
  and they are large: the local opencode database on this Mac is ~7.6 GB. A
  careless implementation becomes a slow, memory-hungry scanner inside a
  menu-bar app.
- Attribution is the part that cannot be faked. A number labelled "this project
  used 40%" that is actually "a session started while this folder was open" is
  worse than no number.

## Candidate sources (all read-only)

| Source | What it plausibly holds | Risk |
|---|---|---|
| opencode SQLite (`$XDG_DATA_HOME/opencode/opencode.db`, `~/.local/share/opencode/opencode.db`) | session rows, per-session directory, timestamps, token counts | schema is private; multi-GB; WAL files |
| Codex rollout logs (`~/.codex/sessions/**/*.jsonl`) | `session_meta` with `cwd`, model, token counts, rate-limit snapshots | JSONL files accumulate; fields differ per CLI version |
| Command Code CLI logs | unknown; may hold nothing local | must be discovered, not assumed |
| Provider dashboards | aggregate only, no project dimension | none usable |

**Step 0 of any implementation is a discovery probe, not an importer.** It must
enumerate tables/columns (SQLite `sqlite_master`, `PRAGMA table_info`) or JSONL
keys, report what it found, and stop. No hard-coded schema survives contact with
an updating CLI.

## Proposed contract (sketch, not shipping)

A third, independent document with its own `schemaVersion`:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-02T09:12:00Z",
  "windowDays": 7,
  "projects": [
    {
      "projectId": "p_3f9a1c",
      "displayName": "quota-bar",
      "sources": [
        {
          "tool": "codex",
          "sessions": 12,
          "firstSeen": "2026-10-27T18:04:00Z",
          "lastSeen": "2026-11-02T08:41:00Z",
          "models": ["gpt-6.1-sol"],
          "tokens": { "input": 410000, "output": 52000, "cached": 90000 }
        }
      ],
      "attribution": "observed"
    }
  ],
  "unattributed": {
    "sessions": 3,
    "reasonCodes": ["no_project_metadata"]
  },
  "caveats": ["tokens_are_local_counts", "no_cost_estimate"]
}
```

Design rules baked into that shape:

- **`attribution` is explicit**: `observed` (the tool recorded the directory for
  that session), `inferred` (derived from a heuristic — v1 would not ship these
  at all), or the session lands in `unattributed`. No silent guessing.
- **No cost figure.** Token counts are facts the tools recorded; prices are not
  observable and change. A cost column would need a user-supplied price table
  and an `estimated` label, and is explicitly out of scope for v1.
- **No ranking across tools.** "Go used more than Codex" compares different
  units again; each source is reported separately.
- **Stable project ids are hashes** of the resolved path (same short-hash helper
  as `accountRef`), with the display name kept to the last path component. The
  full path never leaves the machine, and it is not needed in the document.
- **`caveats` is part of the contract**, so a consumer cannot print a token
  number without also receiving the reason it is not a bill.

## Privacy rules

- Metadata only: directories, timestamps, models, token counts. **Never** prompt
  text, message bodies, file contents, or tool arguments.
- Read-only SQLite (`mode=ro`, `immutable` where safe) with a bounded query:
  time window first, `LIMIT` always, no `SELECT *` over unbounded tables.
- No copying, no vacuuming, no writes — not even a WAL checkpoint — into another
  tool's store.
- Failures are local and silent: an unreadable store contributes
  `unattributed`, never an error dialog.
- Nothing is uploaded, and the document is not part of `--status-json`.

## Performance budget

- One command invocation, cold, under ~300ms for a 7-day window on a multi-GB
  store. If the discovery probe cannot prove an index-backed query, the feature
  does not ship with that source.
- No work at popover-open time: this is an on-demand CLI document (and, later, a
  History tab), never part of the 5-minute refresh loop.

## Rollout gates

1. **Discovery probe** (read-only, prints shape only) run on a real machine;
   results recorded in this document.
2. Synthetic fixtures in tests: a tiny SQLite file and a couple of JSONL files
   covering "directory recorded", "directory missing", "two tools, one project",
   "session spans two windows".
3. Contract review before UI: the JSON above, `schemaVersion: 1`, and the
   caveats vocabulary.
4. Only then a read-only CLI command; a UI surface last, and only if the data is
   `observed` often enough to be useful.

## Open questions

- Do opencode sessions record a directory per **session**, per **message**, or
  not at all? (Unknown until step 1; the whole feature depends on it.)
- How should a session that changes directory mid-run be attributed — first
  directory, last, or split? (Recommendation: last, with a caveat code.)
- Do worktrees and submodules deserve their own project identity, or fold into
  the repository root?
- Is a 7-day default window honest for monthly quotas, or should the window
  follow the provider's cycle (the way History already does)?
- Should `projectId` be salted per machine to make accidental sharing of the
  document less identifying? (Recommendation: yes, salt stored locally.)
