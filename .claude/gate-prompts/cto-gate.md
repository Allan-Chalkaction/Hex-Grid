# cto-gate invocation template — orchestrated mode (per-ticket)

**Used by:** `core/config/phases/orchestrated/t-cto.md`
**Agent invoked:** `@cto-advisor`
**Template substitutions:** `${ticket_key}`, `${ticket_run_dir}`, `${wave_slug}`, `${wave_run_dir}`

**Substitution mapping** (template name ↔ source):
- `${ticket_key}` ← state file `ticket_key`
- `${ticket_run_dir}` ← wave manifest `tickets[current_ticket].ticket_run_dir`
- `${wave_slug}` ← state file `slug` (the wave is the run; the slug IS the wave slug)
- `${wave_run_dir}` ← state file `run_dir`

The orchestrator interpolates the substitutions and passes the resulting prompt to `@cto-advisor`. Originally derived from the now-retired pipeline cto-gate phase, adapted for ticket scope: the input is a single ticket's prompt (one of N in a wave), not a feature request.

---

## Prompt body (sent to cto-advisor)

You are evaluating a single orchestrated-mode ticket inside a wave.

**Ticket key:** ${ticket_key}
**Wave:** ${wave_slug}
**Ticket run dir:** ${ticket_run_dir}

### Inputs

1. **`${ticket_run_dir}/prompt.md`** — the ticket's user-facing description. This is the scope you are evaluating.
2. **`${wave_run_dir}/wave-manifest.json`** — wave-level context: ticket dependencies, planned files, gate recommendations. Read selectively for cross-ticket awareness; do NOT read other tickets' `prompt.md` or `spec.md` (your scope is bounded to this ticket; cross-ticket reasoning is the orchestrator's job per ADR-009).
3. **(If present) `${ticket_run_dir}/deferrals-injected.md`** — deferrals carried forward from earlier tickets in this wave (V2-W3-T01). If present, factor them into your evaluation.
4. **Cited ADRs** — `docs/decisions/ADR-*.md` files referenced (by filename or short slug) in `${ticket_run_dir}/prompt.md` or in the wave manifest's planned-file paths. Identify each cited ADR and read its specification (paths, naming conventions, file layout, architectural patterns). The cross-check at the Output's "ADR alignment" section depends on this.

### Output

Write `${ticket_run_dir}/cto-evaluation.md` containing:

1. **Ticket summary** — one-line restatement of what this ticket builds.
2. **Strategic fit** — does this ticket fit the wave's direction? Cite wave-manifest fields if relevant.
3. **Feasibility assessment** — what makes this hard or risky? Reference existing patterns or known constraints.
4. **Tech-debt impact** — does this introduce, reduce, or maintain technical debt?
5. **Recommendation** — one of: `GO`, `SIMPLIFY`, `DEFER`, `NO-GO` (with rationale).
6. **ADR alignment** — for each ADR cited in the prompt or wave context, verify that the ticket's paths, naming conventions, file layout, and architectural patterns align with the ADR's specification. Drift on paths, naming, or architectural patterns is BLOCKING — recommend SIMPLIFY (align prompt with ADR) or NO-GO (ADR is wrong, escalate to ADR revision). Cosmetic drift (variable names, comment styles, internal helper structure) is non-blocking; note in the section but do not escalate the verdict. If no ADRs are cited, write "No ADRs cited; alignment check N/A" and continue.

### Verdict-line discipline (LOAD-BEARING)

The recommendation MUST appear on its own line in the form:

```
Recommendation: GO
```

(or `SIMPLIFY` / `DEFER` / `NO-GO`). The orchestrator's auto-advance hook regex-matches this literally — see `core/hooks/advance-workflow-phase.sh` (the orchestrated track-arm gates this regex on `current_phase == "t-cto"` to prevent collision with t-consensus's `CONSENSUS:` namespace).

Constraints:
- ASCII colon, single space after, all-caps verdict word.
- No markdown emphasis (`**`, `_`, backticks).
- No trailing punctuation.
- Not inside a code block.
- May appear inside the body of `cto-evaluation.md` (the existing pipeline pattern places it under a `### Recommendation:` heading; that's also fine).

### SIMPLIFY / DEFER / NO-GO surfaces

If your verdict is **GO**: write the evaluation as above; the orchestrator advances autonomously.

If your verdict is **SIMPLIFY**: include the simplified scope as a clearly-labeled `## Simplified scope` section in the evaluation. The orchestrator will halt, present 4 options to the user (GO with simplified scope, OVERRIDE with original prompt, free-text feedback, END). Iter-N preservation: `cto-evaluation.iter-2.md` for the first re-invocation after free-text feedback, etc.

If **DEFER**: include the trigger condition under a `## Defer until` section. Orchestrator presents override-or-END.

If **NO-GO**: include the blocking concern under a `## Blocked by` section. Orchestrator presents override-or-END.

The four-option / override-or-END text is the canonical CTO-gate surface wording (originally derived from the now-retired pipeline cto-gate phase) with `${run_dir}` → `${ticket_run_dir}` substitution. Do NOT deviate; the surfaces' wording is part of the user's mental model across modes.

### What you are NOT doing

- You are NOT writing the spec. The pm-spec agent does that at t-spec.
- You are NOT consensus-checking; that's a separate gate (t-consensus) with its own template.
- You are NOT evaluating the wave as a whole. Each ticket is a separate CTO call with its own evaluation; wave-level decisions were made at wave planning.

### Re-invocation after free-text feedback

If the orchestrator re-invokes you with user feedback inline, the prior `cto-evaluation.md` has already been preserved as `cto-evaluation.iter-{N}.md` (the orchestrator handles this before re-invocation). Write a fresh `cto-evaluation.md` reflecting your revised verdict given the user's feedback. The new evaluation re-enters the same gate.
