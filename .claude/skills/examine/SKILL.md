---
name: examine
description: Dispatch the Fable-pinned examiner over assembled material at a shape-deciding moment — post-plan/pre-build (/examine plan), post-build/pre-merge (/examine build), or ad-hoc (/examine <path>). The orchestrator assembles the brief, dispatches ONE examiner, persists the verdict, ledgers the spend. Triggers - "/examine", "examine this plan", "review the assembled spec", "good/bad/ugly pass".
user_invocable: true
---

# /examine — the Fable examiner door

`/examine` is the operator door to the **`examiner`** agent (Fable-pinned, review-only — see
`core/agents/examiner.md`). One verb: GOOD/BAD/UGLY + verdict + prescriptive `F-NNN` findings over
**assembled** material. The examiner authors nothing and fans out to nothing (no Agent/Task tool,
ADR-088 D2). **You, the orchestrator, own the brief** — a dispatched examiner starts cold, so brief
quality is your accountability (ADR-088 D5). Authority: `docs/decisions/ADR-088-narrow-fable-seats.md`.

This is **operator-invoked, zero engine wiring** in v1 (no per-wave gate — that was explicitly rejected
as cost creep). You call it; you stop after rendering the verdict; fold-in is a separate step.

## Usage

- `/examine <path-or-scope>` — **ad-hoc.** Point it at anything assembled: a backlog folder, a jam, a
  plan doc, a findings folder. (The 22→7 cluster-rationalization move.) Persists to `examiner-adhoc.md`.
- `/examine plan <spec-folder>` — **checkpoint 1** (highest value — specs are cheap to fix, builds are
  not). Brief = explore findings + roadmap + the wave specs. Persists to `examiner-plan.md`.
- `/examine build <run-folder>` — **checkpoint 2** (post-build, pre-merge). Brief = run-logs + gate
  findings + diffstat + the specs, with bounded reads of the built code. Persists to `examiner-build.md`.

## On invocation (the orchestrator does ALL of this)

### a. Assemble the brief (your accountability — ADR-088 D5)

Build the brief from the template below. A lazy brief makes Fable an expensive stranger. Inline what
fits; pass paths the examiner can bounded-read for the rest. State the read budget explicitly.

```
TARGET: <what is being judged — "the w1-telemetry wave spec + its decomposition">
CONTEXT: <what this is, where it came from, the prior decisions that BIND — the roadmap verdict,
          the ADR, the seam that was identified, anything already settled the review must respect>
MATERIAL:
  - <inline the small high-signal pieces (the AC list, the ticket table)>
  - <path/to/roadmap.md>, <path/to/waves/...> — bounded-read these
QUESTIONS: <the specific judgment wanted — "is the W1→W2 order right? are the ACs testable as
            written? does any ticket duplicate existing tooling?">
READ BUDGET: verify only what you will assert; ~15 tool calls.
RE-REVIEW: <OMIT on first pass. On a delta re-review, set this and attach the prior
            findings/examiner-*.md + the fold-in diff — see § Fold-in & delta re-review.>
```

### b. Dispatch ONE examiner

Dispatch a single `examiner` agent with the brief + read budget. One dispatch per `/examine`. Never
fan out, never loop the examiner against itself.

### c. Persist the verdict

The examiner writes no file — its final message IS the deliverable. Persist it to
`findings/examiner-{plan|build|adhoc}.md` in the **active run folder**. If there is no active run, the
report-class capture arm in `core/hooks/sync-artifacts-post-agent.sh` scaffolds an
`HHMM-AUDIT-examiner/` folder and writes `findings/examiner.md` automatically (`examiner` is in that
hook's `REPORT_CLASS_AGENTS` list) — verify it landed and reference the path.

### d. Append the telemetry line (binding — ADR-088 D4)

Source `in_tokens`, `out_tokens`, `cache_create`, `cache_read` and append ONE line to the Fable ledger
via a single-line O_APPEND (`>>`, ADR-085 D4 — never read-modify-write). **Token COUNTS only — never any
message content, payload, or body in any sourcing path (ADR-088 D4).**

**Where to source out/cache (ADR-118 W5A — by-view-verified).** The orchestrator's **dispatch usage
block does NOT reliably surface the per-dispatch out/cache breakdown** — `out_tokens`/`cache_*` land **0**
there, so the `out > 4000` arm of `over_envelope` could never trip. Source them instead from the
examiner's **subagent journal**, the exact source `measure-run.sh --per-agent` already reads (§d closing
note; `core/scripts/measure-run.sh` subagent roll-up). The examiner is dispatched as a subagent, so its
journal lands at `<transcript-without-.jsonl>/subagents/agent-*.jsonl` carrying a usage block with
per-dispatch `output_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens` and stamped with
`attributionAgent:"examiner"` + the parent `sessionId` (structural dir join + field-verified). Read the
counts (only the four numeric fields — no content) from the matching journal:

```bash
TS="$(date -u +%FT%TZ)"
# Per-dispatch out/cache breakdown comes from the examiner's subagent journal (NOT the dispatch
# usage block, where out/cache land 0 — ADR-118 W5A). The journal is the SAME source
# measure-run.sh --per-agent reads, so the two stay reconcilable. Counts only — no content.
TRANSCRIPT="$(find "$HOME/.claude/projects" -name "${SESSION}.jsonl" -type f 2>/dev/null | head -1)"
SUBAGENTS_DIR="${TRANSCRIPT%.jsonl}/subagents"
# Sum the examiner journal's usage counts (in/out/cache), matched by attributionAgent + sessionId.
# Newest examiner journal in this session = the dispatch we just ran.
read -r IN_TOKENS OUT_TOKENS CACHE_CREATE CACHE_READ < <(python3 - "$SUBAGENTS_DIR" "$SESSION" <<'PY'
import json, os, sys, glob
d, sess = sys.argv[1], sys.argv[2]
best=None; best_m=-1
for jp in glob.glob(os.path.join(d, "agent-*.jsonl")):
    j_in=j_out=j_cc=j_cr=0; j_agent=None; j_sess=None
    try: f=open(jp, encoding="utf-8")
    except Exception: continue
    with f:
        for jl in f:
            jl=jl.strip()
            if not jl: continue
            try: o=json.loads(jl)
            except Exception: continue
            if j_sess is None and o.get("sessionId"): j_sess=o["sessionId"]
            if j_agent is None and o.get("attributionAgent"): j_agent=o["attributionAgent"]
            if o.get("type")=="assistant":
                u=(o.get("message") or {}).get("usage") or {}
                j_in+=int(u.get("input_tokens") or 0); j_out+=int(u.get("output_tokens") or 0)
                j_cc+=int(u.get("cache_creation_input_tokens") or 0); j_cr+=int(u.get("cache_read_input_tokens") or 0)
    if j_agent!="examiner" or (j_sess is not None and j_sess!=sess): continue
    m=os.path.getmtime(jp)
    if m>best_m: best_m=m; best=(j_in,j_out,j_cc,j_cr)
print("%d %d %d %d" % (best if best else (0,0,0,0)))
PY
)
OVER=false; if [ "$IN_TOKENS" -gt 90000 ] || [ "$OUT_TOKENS" -gt 4000 ]; then OVER=true; fi
# jq -nc guarantees a valid JSON line regardless of quotes/backslashes in $TARGET (CR-001)
jq -nc --arg ts "$TS" --arg target "$TARGET" --arg session "$SESSION" --arg verdict "$VERDICT" \
  --argjson in_tokens "$IN_TOKENS" --argjson out_tokens "$OUT_TOKENS" \
  --argjson cache_create "$CACHE_CREATE" --argjson cache_read "$CACHE_READ" --argjson over "$OVER" \
  '{ts:$ts,agent:"examiner",target:$target,in_tokens:$in_tokens,out_tokens:$out_tokens,cache_create:$cache_create,cache_read:$cache_read,session:$session,verdict:$verdict,over_envelope:$over}' \
  >> docs/step-3-specs/_fable-spend.jsonl
```

`over_envelope` = `(in_tokens > 90000 || out_tokens > 4000)` — the 2× rule over the ~25–45k in / ≤2k
out soft envelope. With out/cache now sourced from the journal, the `out > 4000` arm can actually trip
(it could not when out landed 0 from the dispatch usage block). The ledger file is created on first
dispatch (do not pre-create an empty one). `measure-run.sh --per-agent` reads the **same**
`attributionAgent` journals, so the two sources stay reconcilable by construction. The roll-up renders
via `/doctor --tokens`.

> If the examiner journal is genuinely unavailable in a given environment (no `subagents/` dir resolved),
> the Python helper falls back to `0 0 0 0` — out/cache are then aggregate-dark for that line and only the
> `in_tokens > 90000` arm of `over_envelope` can trip. This is the honest-degradation fallback, not the
> intended path: when the journal is present (the normal case) the breakdown is real.

### e. Flag over-envelope in the run log

If `over_envelope` is `true`, flag it one line in the run log ("examiner dispatch over envelope:
<in>/<out> tok — creep watch"). No hard cap in v1; the alarm makes creep visible the day it starts.

### f. Render the verdict and STOP

Render the verdict + findings to the operator (it's a one-page doc) and **stop**. Fold-in is a
separate, operator-driven step — `/examine` does not fold in. End the turn on the verdict.

## Fold-in & delta re-review (the recipe — operator-driven, separate from the verdict)

When the operator says "go" on a `FOLD-IN-REQUIRED` verdict:

1. **Fold in (Opus owns it).** For each finding the operator accepts: edit the spec directly (docs path)
   or re-dispatch the authoring agent (e.g. `pm-spec` for a re-render); an accepted UGLY may add a
   ticket. The examiner never touches the artifact — it prescribed; you apply.
2. **Delta re-review — only when a finding was STRUCTURAL** (a re-decompose, a cut ticket, a seam move),
   and **at most ONCE per artifact** (the anti-ping-pong cap, ADR-088 D2). Re-dispatch `examiner` with
   `RE-REVIEW:` set + the prior `findings/examiner-*.md` + the fold-in diff. The examiner answers each
   `F-NNN` addressed yes/no + a one-line attestation, and returns a verdict only (no fresh survey).
   Persist + ledger this dispatch like any other. A cosmetic fold-in needs no re-review — trust it.
3. **Build/merge proceeds** under the normal track once the verdict is SOUND (or the operator accepts
   the residual findings as deferrals).

## Guardrails

- **One examiner dispatch per `/examine`.** Delta re-review is the only second dispatch, and only once
  per artifact.
- **The examiner authors nothing and you don't ask it to.** It prescribes; Opus folds in.
- **Always ledger.** Every examiner dispatch appends exactly one `_fable-spend.jsonl` line (D4 is
  binding — the operator monitors Fable spend like a hawk).
- **Stop on the verdict.** Fold-in is operator-driven; don't auto-apply prescriptions.
