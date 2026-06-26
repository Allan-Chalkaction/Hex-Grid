You are in **roadmap mode** — the advisory planning funnel runs **on the Workflow engine** (ADR-055), autonomous-to-completion (ADR-054). This phase is injected every turn while the run is active. The full protocol is `core/skills/roadmap/SKILL.md`; the binding contract is `core/rules/rules-advisory-modes.md`.

Run folder: `${run_dir}`
Slug: `${slug}`

## The orchestrator drives NO funnel ceremony

Roadmap is a **Workflow script** (`core/scripts/workflows/roadmap.js`) like `/orchestrated` — it shows in `/workflows`, runs outside your per-turn context, and its agents (research, cto-advisor, the authoring agent, the planner self-QA) run **inside the script**. **You do NOT dispatch the funnel agents or author the draft yourself.** Your entire runtime job is the four steps in the skill's **§ "Engine dispatch"**:

1. **Scaffold** (once): source the intent jam-first (ADR-051 §8), create `${run_dir}`, write `prompt.md` + `round-0-intent.md`. Record `attended: true` in `prompt.md` only if the operator passed `--attended`.
2. **One `Workflow` call** — `scriptPath` = `roadmap.js` (resolve `.claude` else `core`), `args = { runDir, repoRoot, phase: 'E'|'W', epicSlug, waveSlug?, intent, attended }`. The engine runs the funnel and returns the finalized markdown + findings.
3. **One persist call** — write the return to a tmp JSON, `persist-run-artifacts.py --run-dir ${run_dir} --return-file …`. It writes findings + the **canonical** `docs/step-3-specs/<epic>/roadmap.md` (E) / wave files (W).
4. **Teardown + present** — `rm -f` the state file (Bash), then present the completion report (canonical path, shape, next step).

## Autonomous (default) vs `--attended`

- **Autonomous (default):** the engine finalizes in one pass; `surfaceRequired:false`. Persist writes the canonical artifact; you teardown + present. No halt.
- **`--attended`:** the engine returns the draft + self-QA WITHOUT finalizing (`surfaceRequired:true`, `surfaceType:"roadmap-round"`). Do NOT teardown — present the round boundary (draft + the planner's recommended reply) and the operator `lock`/tunes per the skill's §"Per-round protocol"/§"Exit contract". The interactive multi-round loop is the only orchestrator-mediated path.

## Interrupts (the only stops)

If the engine returns `surfaceRequired:true` with a `criterionFindings` entry (a genuine ADR-018 crit-1/2/3/5 interrupt an agent raised — critical architecture, scope shift, security, ambiguity), perform the single consolidated halt per the surface protocol instead of finalizing. A `cto-advisor` SIMPLIFY is folded by the engine, not surfaced. Difficulty / "checking in" / re-confirmation are NOT interrupts.

## Resume safety

If resuming, the run folder + thin manifest are the substrate. In autonomous mode, re-dispatch the Workflow (it reuses on-disk `round-0-intent.md`); if a finalized `docs/step-3-specs/<epic>/roadmap.md` already exists, the run is complete — present it and teardown.

Phase instructions above are authoritative. Proceed immediately — dispatch the engine; do not hand-drive the funnel.
