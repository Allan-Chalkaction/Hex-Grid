# Orchestrated Wave Execution Mode — Orchestrator Authority

`/orchestrated` runs a pre-decomposed wave of tickets as a **single Workflow-engine script**
(`core/scripts/workflows/orchestrated.js`) — the whole chain lives in one Workflow call that never enters
the orchestrator's per-turn context. It surfaces to the human only on material decisions. **Binding
contract only** — rationale and worked mechanics live in the ADRs; never inline them here.

> **Epic scale — straight is the default; interleave is opt-in.** The **default** way to build a planned
> multi-wave epic is `/orchestrated <epic-folder>` — **all waves straight** (front-loaded; ADR-112 Wave 2):
> a PLANNED folder skips the advisory preamble + decompose (plan-detect / slice-once) and builds every wave
> in dependency order in one run. **Opt into interleave only** when each wave must be re-planned on prior
> waves' *built* reality: `/orchestrate-epic <epic-slug>` (ADR-059; opt-in per ADR-062;
> `core/skills/orchestrate-epic/SKILL.md`) interleaves plan+build per wave (roadmap wave N → build wave N →
> roadmap wave N+1 grounded on the *built* wave N → …) on a shared epic branch, setting `crossWavePrior`
> and calling THIS wave engine once per wave. Interleave is glue above this contract, not a change to it —
> single-wave `/orchestrated` is unchanged, and interleave is never the silent default.

*ADRs: 039 (engine + four contracts), 040 (orchestrated wiring), 062/063 (build model + implementation),
009, 013, 014, 018, 029, 033, 036, **105 (default autonomous disposition — judgment-class auto-disposes;
only an execution-block halts)**. Halt criteria source-of-truth: `docs/conventions/halt-fires-criteria.md`.*

Durable state is the **thin manifest** (`run-manifest.py`, `tickets[]`); the Workflow script *is* the chain.

## The engine chain

One Workflow call dispatches, in order:

`cto-advisor → architect-review (PRE — soundness-validation + ADR authoring; skipped on PLANNED) → pm-spec →
[ui-spec if has_ui] → [spec-decomposer if multi-ticket → tickets[]] → explore → one-implementer
wave-build (in-place on the wave branch; commit per ticket in dependency order) → integrate (verification
no-op: assert one commit per ticket key in dependency order) → batch-gate (D5: code-reviewer ∥
spec-conformance [∥ contextual] [∥ security-auditor auto-added on an auth/secret/migration surface]) →
[architect-review (FINAL) if crossWavePrior]`.

**The PRE architect pass has two arms with different skip behavior (ADR-116 D2):**
- **(a) soundness-validation — SKIPPABLE when PLANNED.** On a NOT-PLANNED build it gates the approach before
  any implementation. On a PLANNED build (`/orchestrated <folder|wave>` over a graduated spec) it is **skipped**
  — `/roadmap`'s own `architect-review` already validated soundness at plan time, and re-running it would defeat
  slice-once (ADR-112).
- **(b) ADR authoring — never dropped, but WHERE it happens depends on the path.** On a **NOT-PLANNED** build,
  architect-pre **authors the ADR inline** (as today). On a **PLANNED** build the architect-pre pass is skipped,
  so the ADR is **NOT** authored by it; instead the ADR is **staged at `/roadmap` lock** (a Draft, UNnumbered,
  decisions pre-filled from the resolved forks, at `docs/step-3-specs/<epic>/adr.md`) and **finalized at
  `/orchestrated` build-start** (number claimed atomically via `claim-id.py adr`, `Status: Draft → Accepted` —
  ADR-072). This finalize step is gated **independently of the preamble-skip** so a PLANNED build still produces
  a numbered, Accepted ADR. (Mechanism: `core/skills/roadmap/SKILL.md` half-a + `core/skills/orchestrated/SKILL.md`
  + `core/scripts/workflows/orchestrated.js` `payload.adrFinalize` half-b.)

**The FINAL architect pass is conditional on a cross-wave seam** (ADR-062/063):
a wave composing with prior built waves (the `/orchestrate-epic` interleave case) sets `crossWavePrior:true`
→ architect-final fires; standalone single-wave runs skip it. The `implementer` agent is the canonical
wave-builder (CLAUDE.md / `_shared/implementer-protocol.md`).

The script honors the **four ADR-039 engine contracts** unchanged: defensive args parse; **returns** a
structured payload (the orchestrator persists it via `persist-run-artifacts.py`); **computes** the surface
(`criterionFindings` + `surfaceRequired`, crit-1..5) while the orchestrator **performs** the single
consolidated halt (ADR-036) and the wave-level commit; the wave-builder runs **in-place on the wave
branch** and integrate verifies the per-ticket commit stream (no by-SHA fan-in). The across-wave
shared-sink rule still binds for `/launch` (ADR-053).

## Operating contract — default autonomous disposition (ADR-029; ADR-105)

A wave runs autonomously **to completion**, not to a per-touchpoint package (ADR-105 extends ADR-029). A
finding is a **decision the orchestrator makes**, not a stop. The five ADR-018 criteria no longer gate for
engine paths — judgment-class escalations auto-dispose + log + continue; the wave halts **only on an
execution-class block**.

**The one hard stop — execution-class (ADR-105):** the build literally cannot proceed —
`implementer-blocked`, harness/integration failure, corrupt manifest. Not an opinion; no judgment call
resolves it. Drain independent queued work first, then surface (`implementer-blocked`/`unknown`).

**Judgment-class → auto-dispose, never halt (ADR-105):** cto SIMPLIFY/DEFER/NO-GO, any `_criterion_match_`
finding (crit-1..5), architect-review crit-1, `@security-auditor` Critical, resolver INDETERMINATE. The
orchestrator decides — `APPLY` → remediation dispatch; `DEFER` → log; `DISMISS` → note; a load-bearing fork
→ best-judgment call + an ADR if warranted — records each in the decision log (§ Decision log), and
continues.

**Shared-state floor (preserved, does NOT halt):** wave→main PR, force-push, merge to main, ADR amendment
stay operator-only. The orchestrator completes all work up to the lever, **queues it**, and continues —
nothing reaches a shared system (remote/main/prod) unattended. A wrong autonomous call lands on the wave
branch, reviewable and revertible.

**Substrate-flow (never surface):** amend-planned-files; additive atom-traceable file additions;
reviewer↔implementer disagreements the implementer can settle with evidence; forward-carryable gate
findings. Do not halt for "checking in."

**Planner is the inverse (ADR-105 §4):** `/planner` is advisor-only and does NOT route through the
batch-gate consolidated surface — the flipped branch does not exist in its path, so its **collaborative
default holds**. Autonomy is the engine-path default; collaboration is the planner default.

## Authorities

**MAY:** dispatch the engine (which dispatches advisor- and implementer-tier agents per the chain);
auto-commit per ticket to the wave branch (main never written during execution); amend the in-progress
ticket and flag downstream tickets on scope shift (cross-ticket reasoning is the orchestrator's job —
ADR-009); record deferrals (one-line, ADR-036); halt-and-resume from any session via `/resume`
(`tickets[]`-walking).

**MUST NOT:** bypass user authorization for shared-state ops; hand-author plan steps — wave decomposition
into `tickets[]` is an engine-internal `[spec-decomposer]` step, and there is **no** orchestrator-authored
`plan-steps.json` (retired); auto-promote a too-big ticket to a different track without the operator;
auto-resolve disagreements without rule citation; auto-revert committed tickets.

**Planner discipline (B4).** Finding fixable within orchestrator-permitted-paths → direct edit. Application
source outside that allowlist → the engine's implementer dispatch.

## Hook short-circuits

| Hook | Behavior |
|---|---|
| `sync-artifacts-post-agent.sh` | Recognizes `*-WAVE-*`; skips autostate on `tickets/*`; cleans prior session state files. |
| `block-source-edits.sh` | Unchanged (guards active-runs state files; bypass lifts the source restriction; worktree edits pass). |
| `require-protocol.sh` | Live `orchestrated)` arm gates implementer dispatch on **CHECK 0 (state file exists) + CHECK 5 (≥1 completed Explore) only** (ADR-085 D1). The v1 phase-whitelist (CHECK 0b), the wave-manifest existence check, and the in-progress-ticket invariant are retired for engine tracks — `current_phase:"setup"` is a v2 run's steady state (no phase machine, ADR-079), and `run-manifest.json` is written post-run via persist (ADR-039 contract 2), not at dispatch. CHECK 0b is retained verbatim only for the dormant v1 `pipeline)` arm. |

## State lifecycle

| Event | Action |
|---|---|
| New wave | Skill creates `HHmm-WAVE-{slug}/`, parses the wave spec, writes `prompt.md`; the engine writes the thin `run-manifest.json` (`schema: thin-manifest/1`, `tickets[]`). |
| Resume | `/resume` walks `run-manifest.json` `tickets[]` (first dep-ready non-complete ticket); the wave branch's per-ticket commits are the durable substrate. |
| `/orchestrated off` | Skill removes the state file via Bash `rm -f` (active-runs guard blocks Edit/Write). Run folder + manifest persist. |
| Completion | All tickets `complete` → integrate → batch-gate → architect-final → `done`. |

The **thin manifest** (`${wave_run_dir}/run-manifest.json`) is the source of truth: per-ticket
`key / status / depends_on / commit_sha / planned_files`. `run-manifest.py` provides `set-tickets`,
`set-ticket`, `next-ticket` (`BLOCKED:<key>` / `WAITING:<key>` / `COMPLETE`). Schema: the `run-manifest.py`
docstring (authoritative). **Nimble never writes `tickets[]`; its single-chain path is unchanged.**

## Halt-fires criteria (ADR-018, narrowed by ADR-105 — binding)

**For engine paths the substrate halts iff an execution-class block fires** (§ Operating contract). The five
ADR-018 criteria no longer gate — judgment-class matches auto-dispose + log + continue. Per-criterion
examples + auto-dispose list: ADR-018 + `docs/conventions/halt-fires-criteria.md`.

**`_criterion_match_` (binding — now drives disposition + the log, not the halt).** Every code-reviewer and
spec-conformance finding carries `_criterion_match_` ∈ {none, crit-1..crit-5}. **Absent/malformed → fail
closed to `crit-1`.** Under ADR-105 the tag drives the **decision-log entry** — crit-1..3 and former
operator-authority forks are logged **loudly** (flagged for review) — it no longer gates. The script
computes the criterion findings; the orchestrator disposes and logs.

**Resolver tier (ADR-033).** `enrich_only` ESCALATE-only dispatch enriches the **disposition record**. Every
criterion match is disposed + logged; the resolver enriches the log entry, not a halt.

## Consolidated gate surface → disposition (ADR-036, flipped by ADR-105 — binding)

**No batched halt for judgment-class findings (ADR-105).** The per-phase consolidated *halt* is retired for
engine paths — judgment-class findings auto-dispose + log + continue. A non-blocking consolidated *summary*
is emitted at run-end (§ Decision log). (Still retires the per-item
`suggestion-disposition`/`review-discussion`/`deferral-proposed` loops.)

At the batch-gate site **the script computes the criterion findings** (`criterionFindings` +
`surfaceRequired` — `_criterion_match_` ∈ crit-1..5 membership, per ADR-039 contract 3); the orchestrator
then dispatches `@resolver` per finding in one parallel batch → **autonomously disposes EVERY finding —
escalating and non-escalating alike** (`APPLY` → `findings/remediate-apply.md` → a remediation implementer
dispatch; `DEFER` → one line in `findings/deferrals-log.md`; `DISMISS` → one-line note; a load-bearing fork
→ best-judgment call + an ADR if warranted) → records each disposition in the decision log (§ Decision log)
→ **continues**. The ADR-036 escalation-set branch is flipped: a non-empty escalation set (INDETERMINATE OR
`_criterion_match_` ∈ crit-1..5; absent → crit-1) is **disposed + logged + advanced**, NOT
surfaced-and-halted. `surfaceRequired` no longer gates a judgment-class halt — only an execution-class block
ends the turn.

Disagreement (`NEEDS_DISCUSSION`) resolves per finding via the resolver: auto-resolves to `DISMISS` when
the implementer cites a `file:line` in a binding-rules doc covering the finding (requiring both
`topic_overlap` AND permissive language — "MAY"/"is permitted"/"is allowed"/"default"), footnoting
`RESOLVED-WITH-CITATION: <file>:<line>`; `APPLY` when the code should change; `INDETERMINATE` → best-judgment
call. Every disposition — including a logged-loudly fork — lands in the decision log, not a halt surface.

## Decision log (ADR-105 — binding)

Default-autonomy's review surface — it replaces the per-touchpoint halt as the operator's control point
("eyes at the end"). Every autonomous judgment-class disposition is recorded in the per-run
**`${wave_run_dir}/autonomous-decisions-log.md`**: one entry per call —
`{what was decided, why, alternatives, confidence, remediate-if-wrong}`. Load-bearing forks (former crit-1 /
cto NO-GO / `@security-auditor` Critical) are flagged **loudly** at the top. At run-end the orchestrator
emits a **non-blocking consolidated summary** (NOT silence) so the operator sees the run's shape without
opening the log. Distinct from the deferral record (§ Deferral record): the deferral log records only
`DEFER` dispositions; the decision log records ALL autonomous judgment calls. Nothing reaches a shared
system before the operator reviews — the shared-state floor (§ Operating contract) holds the levers.

## Surface protocol

Schema (binding): the **ADR-036 consolidated-surface contract** — halt-message format, the closed
`SURFACE_TYPE` enum, producer ordering. Under ADR-105 this governs the **execution-class halt** and the
**end-of-run summary**; it no longer fires for judgment-class findings.

**Triggers → `SURFACE_TYPE` (ADR-105 — narrowed to execution-class):** the only mid-run halt is an
execution-class block — implement blocked (`implementer-blocked`); harness/integration/manifest failure or
no-rule verdict (`unknown`). cto verdicts, batch-gate escalation sets, and amendments **no longer halt** —
they auto-dispose + log. The **end-of-run summary** (non-blocking) reports the dispositions made and any
queued shared-state / operator-authority action.

**Producer ordering (binding):** compute fields → **write `surface-prompt.md`** → print prose → emit the
fenced `wave-resume-context` block → END THE TURN. File write MUST precede the fenced block.

## Autonomous disposition (Tier 0/1/2/3 — ADR-014)

Tier 0 = convergent, no mention. Tier 1 = autonomous advance — **now the default for judgment-class
escalations too** (ADR-105): the orchestrator disposes + logs + continues. Under the engine the **Workflow
script's control flow is the transition authority** (dependency order, parallelism, and concurrency cap live
in the script). Tier 2 = halt and surface — **narrowed to execution-class blocks only** (ADR-105). Tier 3 =
escape hatch: any non-Tier-1, non-Tier-2 condition → halt with `SURFACE_TYPE: unknown`.

## Deferral record (ADR-036)

> The per-run log below is the **in-flight** record. The durable **cross-run inbox** is the global
> `docs/step-1-ideas/` drop-folder (one `DEFER-` file per deferral; `/defer` writes one — ADR-087 merged the
> old `docs/deferrals/` silo into the ideas inbox, location-is-status; renamed from `step-1-backlog` by ADR-089) — it replaces the retired heavy
> `deferrals.json` ledger (ADR-010/021/022). Convention: `docs/step-1-ideas/README.md`.

Append one line to `${wave_run_dir}/findings/deferrals-log.md`:
`DEFER <source> → <target|standalone>: <summary>  [found_by=<agent>, at=<ISO>]`. No
propose/surface/approve round-trip. A `DEFERRAL-PROPOSED:` line still pairs with a `DEFERRAL-RATIONALE:`
block (REQUIRES/CONTEXT/NOT_ASSUMING) — the resolver reads REQUIRES to choose DEFER vs DISMISS.

## Mid-execution amendment (ADR-009)

`@pm-spec`-time `planned_files` additions are a planning event (amend-planned-files, no surface).
Post-implement: detect-amendment; non-empty diff → amendment required (auto-applied + logged, ADR-105; no
halt). A ticket >10 files is a load-bearing fork — auto-dispose + log **loudly** (ADR-105), not an
unconditional halt. Persist the proposal to the decision log. Status flows through the manifest's
`tickets[]`:
`amending` (source mid-flight, not `next-ticket`-eligible); `pending-amendment-applied` (downstream,
eligible alongside `pending`). An implementer NEVER reads another ticket's content; the orchestrator MAY
NOT amend a `complete` ticket.

## Branching (ADR-013; ADR-062/063)

Wave branch `feature/wave-{slug}`; the **one implementer per wave** runs **in-place on the wave branch**
(no per-ticket worktree) and commits per ticket in dependency order with `T-NNN: <description>` messages.
`integrate` is a **verification no-op**: assert one commit per ticket key, in dependency order, against the
wave base — no by-SHA fan-in. Operator-driven wave→main PR at wave-end; no commits to main during
execution. `manual_review_required` defaults `true`; set `false` at planning time only when ALL
`planned_files` are cosmetic-only (`docs/`, top-level `*.md`, `tests/`). **Post-ADR-105 the flag no longer
gates a halt** (judgment-class never halts) — it now sets **decision-log severity**: a `true` ticket whose
gate produces a judgment-class fork is logged **loudly** (flagged for end-of-run review); a `false`
(cosmetic-only) ticket is logged quietly.

## Bypass overlay / multi-run

Bypass takes priority — its short-circuit fires before protocol checks; when active, every agent and direct
source edit passes. Bypass does NOT mutate the orchestrated state file. Switching waves in-session is
supported; `sync-artifacts-post-agent.sh` cleans the prior state file.
