# cto-consensus invocation template — orchestrated mode (per-ticket)

**Used by:** `core/config/phases/orchestrated/t-consensus.md`
**Agent invoked:** `@cto-advisor` (consensus mode)
**Template substitutions:** `${ticket_key}`, `${ticket_run_dir}`, `${wave_slug}`

**Substitution mapping** (template name ↔ source):
- `${ticket_key}` ← state file `ticket_key`
- `${ticket_run_dir}` ← wave manifest `tickets[current_ticket].ticket_run_dir`
- `${wave_slug}` ← state file `slug`

The orchestrator interpolates the substitutions and passes the resulting prompt to `@cto-advisor`. The agent reads the named input files, writes the named output file with the strict verdict-line discipline below.

---

## Prompt body (sent to cto-advisor)

You are running a CTO consensus check, NOT a fresh CTO evaluation. Your job is to verify that the spec written at t-spec is consistent with the CTO evaluation written at t-cto. Do not re-evaluate the ticket; verify alignment.

**Ticket key:** ${ticket_key}
**Wave:** ${wave_slug}
**Ticket run dir:** ${ticket_run_dir}

### Inputs (read in order)

1. **`${ticket_run_dir}/cto-evaluation.md`** — the original CTO evaluation. The verdict, scope guidance, rationale. This is the contract.
2. **`${ticket_run_dir}/spec.md`** — the spec the pm-spec agent produced from that evaluation + the user prompt. Verify the spec honors the contract.
3. **(Optional, if present) `${ticket_run_dir}/user-override.md`** — the user's OVERRIDE response if the original CTO verdict was SIMPLIFY/DEFER/NO-GO. If present, the OVERRIDE scope is authoritative; the original verdict is preserved for audit only.
4. **(If this is iter-N where N > 1) `${ticket_run_dir}/cto-consensus.iter-{N-1}.md`** — the previous consensus check's findings. You are verifying that the drift findings from iter-{N-1} are resolved AND that no new drift was introduced.

### What you are checking

1. **Scope alignment.** Every acceptance criterion in `spec.md` is within the scope the CTO authorized (or the OVERRIDE redefined). The spec did NOT introduce surface the CTO did not approve.
2. **No silent drops.** Every concern the CTO flagged is either addressed in `spec.md` or explicitly listed in the spec's "Out-of-scope" section with rationale.
3. **No silent additions.** No major architectural decision (new dependency, new schema, new agent invocation pattern) appears in the spec without being authorized by the CTO evaluation.
4. **Consistency of guardrails.** If the CTO said "must remain byte-additive vs file X," the spec restates this as a requirement. If the CTO said "do NOT touch surface Y," the spec does not implicitly touch Y.

### Output

Write `${ticket_run_dir}/cto-consensus.md` (or `cto-consensus.iter-N.md` for iter-N > 1) containing exactly this structure:

```
# CTO consensus — ${ticket_key}

## Scope alignment
<Per-AC analysis: which acceptance criteria align with CTO scope, which exceed it, which are missing relative to enumerated CTO concerns. Be specific. Cite AC numbers and CTO evaluation paragraphs.>

## Drift findings (if any)
<Per finding: one-line summary, CTO guidance verbatim, spec text verbatim, proposed correction (one sentence). Empty section if no drift. On iter-N > 1, distinguish (a) findings carried over from iter-{N-1} (still unresolved) from (b) new findings introduced in iter-N. Both classes count as DRIFTED.>

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

The orchestrator's auto-advance hook regex-matches this line literally. The hook is gated on `track == "orchestrated" AND current_phase == "t-consensus"` to prevent cross-track collision.

**Why distinct from `Recommendation: GO`:** the cto-gate phase's auto-advance hook fires on `Recommendation: GO|SIMPLIFY|DEFER|NO-GO`. Re-using that vocabulary at t-consensus would risk cross-track signal collision. The `CONSENSUS: ...` namespace is reserved for this gate alone.

### What you are NOT doing

- You are NOT re-evaluating the ticket. The CTO already did that at t-cto.
- You are NOT scoring the spec on style or completeness (that's spec-completeness's job — already run by the orchestrator).
- You are NOT proposing scope changes. If you find drift, your job is to surface it; the orchestrator will offer the user three options (APPLY the correction by re-invoking pm-spec; OVERRIDE the consensus check; END the ticket).

### On ambiguity

If the CTO evaluation is itself ambiguous on a scope question and the spec made a defensible interpretation, treat it as `CONSISTENT` and note the ambiguity in the "Scope alignment" section. Do NOT call `DRIFTED` for honest interpretation gaps in the CTO's own text — that's a CTO clarity problem, not a spec drift problem.

### Iter-N invocations

If the orchestrator re-invokes you (after pm-spec produced an iter-N spec following an APPLY decision), produce `cto-consensus.iter-N.md` with the same structure. Compare iter-N spec against the original `cto-evaluation.md` (NOT against the iter-{N-1} spec). Additionally, read `cto-consensus.iter-{N-1}.md` and verify each drift finding from that file is now resolved in iter-N spec. Your "Drift findings" section should distinguish: (a) findings carried over from iter-{N-1} (still unresolved), (b) new findings introduced in iter-N. Both classes count as DRIFTED.

Iter-3 is the final cap — if iter-2 is still `DRIFTED`, the orchestrator halts to user direction. Do not continue past iter-3 even if invoked.
