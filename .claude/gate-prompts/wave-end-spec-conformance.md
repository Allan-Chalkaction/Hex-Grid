# wave-end-spec-conformance invocation template — orchestrated mode (wave-level, v3)

**Used by:** `core/config/phases/orchestrated/w-finalize.md` Step 4a.
**Agent invoked:** `@spec-conformance`
**Template substitutions:** `${slug}`, `${run_dir}`, `${wave_base_ref}`.
**Scope:** `wave_protocol_version == 3` only. Under v1/v2, spec-conformance ran per-ticket at `t-validate`; ADR-026 collapses it to this single wave-end pass against the integrated diff.

The orchestrator interpolates the substitutions and passes the resulting prompt to `@spec-conformance`. This is the **spec-conformance leg of the wave-end post-impl trio** (ADR-026): it verifies atom coverage across the whole wave against the integrated diff, and — critically — emits a **per-ticket atom-coverage sub-section** that is the input `w-finalize.md` Step 4c's lightweight structural check reads under v3 (the binding ADR-016 cross-reference amendment, landed by INFRA-028).

ADR-026 § Decision (the three wave-end reviewers) and ADR-018 (`_criterion_match_` vocabulary + manual-review gating) are binding here.

---

## Prompt body (sent to spec-conformance)

You are running the wave-end **spec-conformance** gate for orchestrated wave ${slug}.

This dispatch is **wave-scope, against the integrated wave diff** — NOT ticket-scope. Under v3 (ADR-026) the per-ticket post-impl review phases are retired; you verify atom coverage for every ticket in the wave at once, against the merged implementation. Orchestrated mode does NOT decompose tickets into plan-steps; verify each ticket's spec atoms (AC-NNN / R-NNN) against the integrated diff as a whole.

**Wave:** ${slug}
**Wave run dir:** ${run_dir}
**Wave base ref:** ${wave_base_ref}

### Inputs (read in order)

1. **`${run_dir}/spec.md`** (the wave-level pm-spec; falls back to `${run_dir}/wave-spec.md` if present) — the per-ticket AC-NNN / R-NNN briefs are the binding contract. Each ticket's atoms appear under its per-ticket section.
2. **The wave manifest** `${run_dir}/wave-manifest.json` — the ticket list, each ticket's `planned_files`, and `commit_sha`. Use `planned_files` + the `<TICKET-KEY>:` commit subjects to attribute each diff hunk to its owning ticket (ADR-026 § bisection cost — attribution is mechanical via `planned_files` mapping + `git blame`).
3. **The integrated wave diff** — `git diff ${wave_base_ref}..feature/wave-${slug}`. This is the implementation evidence. Cite `file:line` for every SATISFIED / NOT_SATISFIED determination.
4. **Per-ticket prompts** at `${run_dir}/tickets/*/prompt.md` (and `spec.md` when present) — context for each ticket's intended scope.
5. **`CLAUDE.md`** — project-wide conventions.

### How to evaluate (same per-atom discipline as the ticket-scope gate)

For each AC-NNN and R-NNN, determine whether the integrated diff SATISFIES it:

- **AC-NNN (acceptance criteria)** — SATISFIED requires a passing automated test OR a one-shot manual check explicitly noted in the spec as the acceptance method.
- **R-NNN (requirements)** — SATISFIED requires evidence in the diff: a `file:line` where honored, or an absence-search across changed files for "must NOT do X" requirements.
- **Substantive standard vs. verification mechanism** — treat the substantive standard as truth; the verification mechanism is evidence (may report false positives in audit-trail / past-tense text). Honor enumerated exclusions.
- **Cross-ticket integration is in scope.** Because you see the integrated diff (not N isolated ticket diffs), you can — and MUST — catch cross-ticket atom failures the per-ticket lens structurally could not: an AC satisfied within its ticket but broken at the seam by another ticket's change; a requirement honored in one ticket and violated by an integration in another. This is the load-bearing reason the gate moved to wave-end (ADR-026 Context).

### Output

Write `${run_dir}/findings/end-of-wave/spec-conformance.md` containing, in order:

1. **Wave summary** — one paragraph: what the wave built; overall atom-coverage posture.

2. **Per-atom verdicts** — one section per atom, grouped by ticket. Use `file:line` evidence:

   ```
   ### AC-001: <given/when/then>
   - **Ticket:** <TICKET-KEY>
   - **Status:** SATISFIED | NOT_SATISFIED
   - **Evidence:** <file:line citation(s) from the integrated diff>
   ```

3. **Per-ticket atom-coverage sub-section (LOAD-BEARING — Step 4c reads this).** A section headed exactly `## Per-ticket atom-coverage`, then for **each ticket** in the wave a sub-section headed `#### <TICKET-KEY>` (four hashes, the bare ticket key) containing:
   - One line per atom: `- AC-NNN: SATISFIED` / `- AC-NNN: NOT_SATISFIED` (and `- R-NNN: ...`). The literal token `SATISFIED` (or `PASS`) is what the structural check counts.
   - A per-ticket verdict line: `TICKET-VERDICT: PASS` (every atom for that ticket SATISFIED) or `TICKET-VERDICT: FAIL`.

   Example:
   ```
   ## Per-ticket atom-coverage

   #### INFRA-028
   - AC-001: SATISFIED
   - AC-002: SATISFIED
   - R-001: SATISFIED
   TICKET-VERDICT: PASS

   #### INFRA-029
   - AC-001: SATISFIED
   - AC-002: NOT_SATISFIED
   TICKET-VERDICT: FAIL
   ```

   This sub-section replaces the per-ticket `spec-conformance.md` files that v1/v2 produced — it is the input `w-finalize.md` Step 4c's structural check reads under v3 (ADR-016 cross-reference amendment).

4. **NOT_SATISFIED detail** — for each NOT_SATISFIED atom, the recommended disposition + criterion match:

   ```
   - **Atom:** AC-NNN (<TICKET-KEY>)
   - **_recommended_disposition_:** REMEDIATE | DEFER | ESCALATE
   - **_criterion_match_:** none | crit-1 | crit-2 | crit-3 | crit-4 | crit-5
   - **Rationale:** <one sentence>
   ```

   `_criterion_match_` vocabulary (ADR-018, verbatim semantics):
   - `none` — auto-disposable (resolver determines APPLY / DEFER / DISMISS). Common for atom-coverage gaps.
   - `crit-1` — architectural concern crossing module/ticket/wave boundaries; resolution needs operator judgment beyond existing ADRs.
   - `crit-2` — fundamental spec/scope shift (stated approach cannot deliver stated AC behavior).
   - `crit-3` — security/privacy/safety boundary (rare here; usually via `@security-auditor`).
   - `crit-4` — requires operator-authority action to resolve.
   - `crit-5` — genuine ambiguity artifacts cannot resolve.

   The wave-end manual review (w-finalize Step 4d) fires iff at least one wave-end finding carries `_criterion_match_` in `{crit-1, crit-2, crit-3}` under `wave_manual_review_required`, OR any finding carries `crit-4` / `crit-5` (which fire regardless). So set `_criterion_match_` honestly.

5. **Deferral proposals (optional)** — if an atom is better satisfied by a *later* wave, emit a `DEFERRAL-PROPOSED:` line + a structured `DEFERRAL-RATIONALE:` block (REQUIRES / CONTEXT / NOT_ASSUMING) per ADR-022. Note: under v3 + one-implementer-per-wave, within-wave deferrals are largely moot (ADR-026 Consequences + synthesis §8.2) — the single implementer does the work when it reaches the ticket. Most deferrals here are genuinely cross-wave.

   ```
   DEFERRAL-PROPOSED: <severity> <target_ticket_or_wave> <one-line summary>
   DEFERRAL-RATIONALE:
     REQUIRES: <one-line behavioral requirement on the target>
     CONTEXT: <what's true in this wave that motivates the deferral>
     NOT_ASSUMING: <vehicle assumptions explicitly NOT made>
   ```

6. **Verdict line** — the LAST non-empty line of the file, exactly one of:

   ```
   VERDICT: PASS
   ```
   ```
   VERDICT: FAIL
   ```

   `VERDICT: PASS` iff every atom across every ticket is SATISFIED. `VERDICT: FAIL` if any atom is NOT_SATISFIED, OR any AC-NNN has no test coverage, OR any R-NNN cannot be evidenced from the integrated diff.

### Verdict-line discipline (LOAD-BEARING)

- ASCII colon, single space, all-caps verdict word (`PASS` | `FAIL`).
- No markdown emphasis, no trailing punctuation, not inside a code block.
- Must be the LAST non-empty line of the file.

`w-finalize.md` Step 4a / Step 6 regex-match this line literally. The gate is gated on `track == "orchestrated" AND wave_protocol_version == 3`.

### Disposition + resolver composition (ADR-020)

Every NOT_SATISFIED finding routes through `@resolver` per-finding (ADR-020), exactly as per-ticket spec-conformance findings did at t-validate — the resolver's APPLY / DEFER / DISMISS / INDETERMINATE verdicts are unchanged; only *where the finding came from* changed (integrated diff vs ticket diff). Attribution to the owning ticket is via `planned_files` mapping / `git blame`.

### Iter-N invocations (rare)

If the orchestrator re-invokes you after a wave-level remediation pass (ADR-026 fix-and-re-review, per-gate iter-2 cap), your prior `spec-conformance.md` is preserved as `spec-conformance.iter-N.md`. Re-audit only the previously-failing atoms; carry forward already-SATISFIED verdicts.
