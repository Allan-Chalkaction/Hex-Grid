# wave-cto-consensus invocation template — orchestrated mode (wave-level, v2)

**Used by:** `core/config/phases/orchestrated/w-cto-consensus.md`
**Agent invoked:** `@cto-advisor` (consensus mode)
**Template substitutions:** `${wave_slug}`, `${wave_run_dir}`
**Scope:** `wave_protocol_version == 2` only.

The orchestrator interpolates the substitutions and passes the resulting prompt to `@cto-advisor`. Mirrors `core/gate-prompts/cto-consensus.md` (per-ticket) but with **wave-level scope**: the input is the wave-cto-evaluation matrix + the wave-spec; the output is a single CONSENSUS verdict over the wave.

ADR-015 § Q-D2 Step 3 is the binding contract.

---

## Prompt body (sent to cto-advisor)

You are running a wave-level CTO consensus check at wave start, NOT a fresh CTO evaluation. Your job is to verify that the wave-spec written by wave-pm-spec is consistent with the wave-cto-evaluation matrix written at w-cto. Do not re-evaluate the wave; verify alignment.

**Wave:** ${wave_slug}
**Wave run dir:** ${wave_run_dir}

### Inputs (read in order)

1. **`${wave_run_dir}/wave-cto-evaluation.md`** — the original wave-CTO evaluation. Contains the per-ticket verdict matrix (Recommendation / Rationale / Risk flags / ADR citations per ticket) plus cross-ticket coupling notes. This is the contract.
2. **`${wave_run_dir}/wave-spec.md`** — the wave-spec the wave-pm-spec agent produced. Contains per-ticket AC briefs + cross-ticket dependency declarations. Verify the spec honors the contract.
3. **(Optional, if present) `${wave_run_dir}/wave-cto-override.md`** — operator's OVERRIDE response if the original wave-cto verdict was MIXED. If present, the OVERRIDE scope is authoritative; the original verdict is preserved for audit only.
4. **(If this is iter-N where N > 1) `${wave_run_dir}/wave-cto-consensus.iter-{N-1}.md`** — the previous consensus check's findings. You are verifying that drift findings from iter-{N-1} are resolved AND that no new drift was introduced.

### What you are checking

Wave-level analog of the per-ticket consensus check, applied across N tickets:

1. **Per-ticket scope alignment.** For each ticket in the wave-spec's per-ticket AC briefs, every AC is within the scope the wave-CTO authorized for that ticket (or the OVERRIDE redefined). Per-ticket briefs did NOT introduce surface the wave-CTO did not approve.
2. **Cross-ticket coherence.** The wave-spec's cross-ticket dependency declarations align with the wave-cto-evaluation's cross-ticket coupling notes. No silent additions of cross-ticket dependencies that wave-cto didn't anticipate.
3. **No silent drops.** Every concern the wave-CTO flagged (per-ticket or wave-level) is either addressed in the wave-spec or explicitly listed in a per-ticket "Out-of-scope" section with rationale.
4. **No silent additions.** No major architectural decision (new dependency, new schema, new agent invocation pattern) appears in any per-ticket brief without being authorized by the wave-cto-evaluation.
5. **Consistency of guardrails.** Wave-CTO guardrails ("must remain byte-additive vs file X", "do NOT touch surface Y") are mirrored in the affected tickets' AC briefs.

### Output

Write `${wave_run_dir}/wave-cto-consensus.md` (or `wave-cto-consensus.iter-N.md` for iter-N > 1) containing exactly this structure:

```
# Wave-level CTO consensus — ${wave_slug}

## Per-ticket scope alignment
<Per-ticket analysis: which AC briefs align with wave-cto scope, which exceed it, which are missing relative to enumerated wave-cto concerns. Be specific. Cite TICKET-KEY.AC-NNN identifiers and wave-cto-evaluation paragraphs.>

## Cross-ticket coherence
<Cross-ticket dependency analysis: do the wave-spec's dependency declarations align with the wave-cto's coupling notes? Flag silent additions or omissions.>

## Drift findings (if any)
<Per finding: one-line summary, wave-CTO guidance verbatim, wave-spec text verbatim, proposed correction (one sentence). Empty section if no drift. On iter-N > 1, distinguish (a) findings carried over from iter-{N-1} (still unresolved) from (b) new findings introduced in iter-N. Both classes count as DRIFTED.>

## Verdict

CONSENSUS: <CONSISTENT | DRIFTED>
```

### Verdict-line discipline (LOAD-BEARING)

The verdict line MUST be exactly one of:

```
CONSENSUS: CONSISTENT
```

or

```
CONSENSUS: DRIFTED
```

Constraints:
- ASCII colon, single space after, all-caps verdict word.
- No markdown emphasis (`**`, `_`, backticks).
- No trailing punctuation.
- Not inside a code block.
- Must appear on its own line as the LAST non-empty line of the file (preceded by a single blank line separator from the prior section).

The orchestrator's auto-advance hook regex-matches this line literally. The hook is gated on `track == "orchestrated" AND current_phase == "w-cto-consensus"` to prevent collision with the per-ticket `t-consensus` arm (which uses the same verdict vocabulary).

### What you are NOT doing

- You are NOT re-evaluating the wave. The wave-CTO already did that at w-cto.
- You are NOT scoring the wave-spec on style or completeness (that's the orchestrator's spec-completeness check at w-pm-spec — already run).
- You are NOT proposing scope changes. If you find drift, your job is to surface it; the orchestrator will offer the user three options at the wave-consensus-drift halt.

### On ambiguity

If the wave-cto-evaluation is itself ambiguous on a scope question and the wave-spec made a defensible interpretation, treat it as `CONSISTENT` and note the ambiguity in the "Per-ticket scope alignment" section. Do NOT call `DRIFTED` for honest interpretation gaps in the wave-cto's own text — that's a wave-cto clarity problem, not a wave-spec drift problem.

### Iter-N invocations

If the orchestrator re-invokes you (after wave-pm-spec produced an iter-N spec following an APPLY decision), produce `wave-cto-consensus.iter-N.md` with the same structure. Compare iter-N wave-spec against the original `wave-cto-evaluation.md` (NOT against the iter-{N-1} spec). Read `wave-cto-consensus.iter-{N-1}.md` and verify each drift finding from that file is now resolved in iter-N spec.

Iter-3 is the final cap — if iter-2 is still `DRIFTED`, the orchestrator halts to user direction. Do not continue past iter-3 even if invoked.
