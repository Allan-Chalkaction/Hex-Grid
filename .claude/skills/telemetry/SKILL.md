---
name: telemetry
description: "Operator-invoked READ-ONLY telemetry dashboard. Renders cost / Fable-spend / gate-efficacy / pipeline-health / measurement-gaps over the EXISTING ledgers (docs/step-3-specs/_metrics.jsonl + _fable-spend.jsonl), reusing the /doctor --tokens roll-up + metrics-summary.sh --json — no new aggregator. Reads only; writes NOTHING. Triggers: '/telemetry', 'telemetry dashboard', 'show run cost', 'token/cost roll-up', 'how's spend trending', 'measurement gaps'."
user_invocable: true
---

# /telemetry — read-only telemetry dashboard

`/telemetry` is the operator-facing **read-only** dashboard over the substrate's existing telemetry
ledgers. It renders run cost, Fable spend, gate efficacy, pipeline health, and measurement gaps in one
pass — **reusing the two roll-up shapes that already exist** rather than introducing a parallel parser.

It is the read-only render partner to the ledgers `/doctor` and `measure-run.sh` already write: it consumes
their output, it does not produce any. Run it any time you want "what does run shape / spend look like right
now?" without re-deriving from the raw JSONL.

## Scope

- **READ-ONLY. Writes NOTHING.** No `git add`, no `git mv`, no `git rm`, no `git commit`, no `git push`,
  no `gh pr`, no `os.makedirs`, no `open(..., 'w')` — it renders to stdout only. It never mutates a ledger,
  an inbox file, a run folder, the config it reads, or any consumer. Shared-state floor (ADR-105): nothing
  reaches a shared system.
- **No new aggregator.** It reuses the two existing read-side shapes (see § Process). It authors no fresh
  `jq`/python parser — every number comes through `metrics-summary.sh --json` or the `--tokens` Fable
  roll-up.
- **Scoped to token / cost / gate-efficacy telemetry.** `/telemetry` is the *cost-and-quality* surface.
- **`/sitrep` is explicitly OUT OF SCOPE (future / deferred).** A separate, broader **`/sitrep`** surface
  (live runs, queue depth, active branches — the *operational-status* view) is **NOT built here** and is
  out of scope for `/telemetry`. `/telemetry` answers "what did it cost / how well did gates work / are we
  measuring enough?"; `/sitrep` would answer "what is running right now?" — they are distinct doors. Do not
  fold `/sitrep` concerns into this skill.

## Process

Resolve the substrate script path (ADR-031: `.claude/scripts` in a consumer, `core/scripts` in
claude-infra), then render the five sections **read-only**:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
METRICS=docs/step-3-specs/_metrics.jsonl
FABLE=docs/step-3-specs/_fable-spend.jsonl
```

Render exactly five sections, each with a plain-text section label (no color-only / symbol-only signaling —
use text status tokens like `OVER`, `STALE`, `GAP`, `OK`, consistent with the `/doctor` Step 1c + `--tokens`
convention):

### 1. Cost (per-run roll-up)

Reuse the **`metrics-summary.sh --json`** aggregator over `_metrics.jsonl` — the single existing aggregator,
with its null-skip and stable `{median, mean, n}` per-metric shape:

```bash
bash "$S/metrics-summary.sh" --json        # grouped {median,mean,n} per metric, per version
```

Render `output_tokens`, `operator_interrupts`, and `agent_dispatches` median/mean/n by version. This is the
"what does a run cost" view. (Empty/absent ledger → `metrics-summary.sh` emits `{}` and exits 0 — render
`no measurement records yet`.)

### 2. Fable-spend

Reuse the **`/doctor --tokens` Fable roll-up shape** over `_fable-spend.jsonl` (the same line-tolerant render
— NOT a new parser):

```bash
bash "$S/infra-doctor.sh" --tokens         # spend this week (in+out), per-dispatch median/max, by-target, over_envelope
```

Render spend this week (in + out), per-dispatch in_tokens median/max, dispatch count by target, and flag any
`over_envelope` line as `OVER`. (Absent/empty ledger → the roll-up prints "no Fable spend recorded" and
exits 0.)

### 3. Gate-efficacy

A read over the same `_metrics.jsonl` aggregate: surface `operator_interrupts` (median/mean/n) and
`agent_dispatches` as the gate-efficacy proxy — how often a run needed operator intervention vs. ran clean,
and dispatch volume per run. No new parser — these come straight from § 1's `metrics-summary.sh --json`
output. Label a high interrupt median `OVER` against the operator's expectation; otherwise `OK`.

### 4. Pipeline-health (duration)

Render **`duration_seconds`** (median / mean / n) from the same `metrics-summary.sh --json` output —
`duration_seconds` is a first-class field in the `METRICS` tuple (extended in `metrics-summary.sh` for this
dashboard; committed to `_metrics.jsonl` by `measure-run.sh`, T11), so it surfaces through the single
existing aggregator with the same null-skip + `{median, mean, n}` shape. This is the "how long does a run
take" view — the pipeline-health signal. Label a duration median over the operator's expectation `OVER`.

### 5. Measurement-gaps

Read the per-metric **`n`** from § 1's aggregate against the run count: a metric whose `n` is well below the
run count (many null/missing samples) is a **measurement gap** — the lever exists but is not actually being
captured. Surface each low-coverage metric with a `GAP` label and its `n` vs. runs (e.g.
`duration_seconds: GAP (n=2 of 11 runs)`). No write — this is a read-only nudge; acting on it is the
operator's call (e.g. via `/doctor --eval`, which logs such gaps as inbox tickets).

## Bottom line

End with one plain-text summary line, e.g.:
`Telemetry: <N> runs measured · spend <in>+<out> this week · duration median <D>s · <G> measurement gap(s) — read-only.`

## Notes

- **Read-only by construction** — `/telemetry` renders; it never moves, stages, commits, or pushes. The
  ledgers are written elsewhere (`measure-run.sh`, examiner dispatch O_APPEND); `/telemetry` only reads them.
- **Reuses, never re-parses** — both roll-up shapes (`metrics-summary.sh --json`, `infra-doctor.sh
  --tokens`) already exist; `/telemetry` composes them. Adding a second JSONL parser is an explicit
  non-goal.
- **`/sitrep` is the separate future surface** (live runs / queue / branches) — named out-of-scope above.
- Related: `/doctor --tokens` (the focused Fable-only render), `/doctor --eval` (the detect-and-log
  optimization arm that auto-logs measurement gaps as inbox tickets), `measure-run.sh` (the writer of
  `_metrics.jsonl`, incl. `duration_seconds`).
