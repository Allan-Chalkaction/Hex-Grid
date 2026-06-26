# Halt templates — canonical catalog (ADR-019)

> **Scope narrowed by ADR-105 (default autonomous disposition).** For engine paths the crit-1/2/3/5
> templates below **no longer frame a mid-run halt** — judgment-class findings auto-dispose + log + continue.
> These templates now frame (a) the **execution-class** halt (`implementer-blocked` / harness failure) and
> (b) **decision-log entries / the end-of-run summary** for a logged-loudly fork. Do NOT read a crit-1/2/3
> template here as evidence that a judgment-class halt still fires — it does not. crit-4 (operator-authority)
> framing survives as the **queued shared-state** notice in the end-of-run summary.
>
> **Single source of truth for halt-and-resume message framing.** Every halt-emission site MUST cite a template by name; producer sites do not author halt messages inline.
>
> **Authority:** ADR-019 (phase-boundary auto-advance + halt-template framing + PASS-THROUGH-SUMMARY).
>
> **Cross-references:** ADR-018 (criteria anchor — every halt template enforces criterion-cite framing); `core/config/phases/orchestrated/wave-resume-context.md` (SURFACE_TYPE enum + fence schema); `core/rules/rules-orchestrated-mode.md` § "Halt-fires criteria"; ADR-024 (precedent memory — adds optional `PRIOR_DISPOSITION:` line to halt format).

---

## Framing rules (binding for every template)

Each template enforces these rules. Templates that violate them are invalid; producer sites that cite invalid templates are substrate-CI failures.

1. **The question states the criterion-matched substantive decision.** Not "what would you like to do?" — the specific decision behind the halt:
   - **crit-1 (architectural):** "Which of these two architectural patterns governs going forward?" / "Should we amend ADR-NNN to cover this case?"
   - **crit-2 (spec/scope shift):** "Is this scope shift acceptable, or should we re-scope the ticket?" / "Which interpretation matches your intent?"
   - **crit-3 (security/privacy/safety):** "Is the proposed PII-redaction shape correct?" / "Authorize this auth-surface change?"
   - **crit-4 (operator-authority):** "Authorize the wave→main PR open?" / "Authorize `/bypass on` enablement?"
   - **crit-5 (INDETERMINATE):** "The resolver couldn't determine intent — which of these does the spec mean?"

2. **Options reflect the criterion-matched decision space, not a generic menu.** No more "APPLY / DEFER / DISMISS / END" listed equally when only one is sane. If three options are genuinely live, list three. If one is obviously correct from the artifact, state it with "RECOMMENDED: X" and offer "or specify override."

3. **The halt cites the criterion.** Every halt-and-resume emission includes a `CRITERION_MATCHED: crit-N` line in the fenced `wave-resume-context` block. Operator reads the criterion before reading the question; the criterion frames the question.

4. **No forward-narration.** Per ADR-014's existing rule and `core/rules/rules-orchestrator-behavior.md` § "Phase-prompt forward-narration discipline." Phase docs end with the disposition just made or the canonical halt-message format; never with "the next inject will fire X" or "I'll dispatch @Y next."

5. **Optional `PRIOR_DISPOSITION:` line** (per ADR-024 precedent memory). When a precedent cache entry exists for the halt's `halt_class_key`, the template includes `PRIOR_DISPOSITION: <verbatim operator reply>` as a "RECOMMENDED" pre-fill.

---

## Surface-or-resolve protocol (ADR-033 — the chokepoint)

> **Phased.** This section defines the shared chokepoint that ADR-033's resolution-authority tier
> activates. **W2 behavior: ALWAYS-ESCALATE pass-through — identical to pre-ADR-033 (no resolver
> dispatched).** W3 auto-disposition is **shelved on v3** (ADR-033 §3b — no resolvable v3 halt
> surface). **PRA-W3E (current, §3c) activates `enrich_only` ESCALATE-only dispatch for the three
> v3-live halts** (`implementer-blocked`, `manual-review`, `end-of-wave-blocker`): the resolver is
> dispatched, forced to ESCALATE, and its analysis is folded into the surface. The marker convention
> below (`<!-- HALT-TEMPLATE: X -->`) is the per-site reference point.

Every halt-emission site cites its template via the `<!-- HALT-TEMPLATE: ${SURFACE_TYPE} -->` marker
placed at its **last common point before `surface-prompt.md` is written** (the per-site seam — e.g.
`validate-fail`'s seam is *after* t-validate Step 5b's per-finding `resolver` loop). At that
seam, the site follows this protocol with a **fully-computed surface payload**
(`{SURFACE_TYPE, fired_criterion, rendered question/options/context, current_ticket, current_phase,
run_dir, subset_member}`):

| Phase | Behavior at the seam |
|---|---|
| **W2** | **ESCALATE always.** Proceed directly to the inline emit (write `surface-prompt.md` → fenced block → end turn) exactly as today. No resolver is dispatched. Behavior-preserving; `test-orchestrated-advance.sh` stays green. |
| **W3 (shelved on v3)** | If `subset_member` (ADR-033 §3) and not a retry re-fire: dispatch `@resolver`. On **RESOLVE/RECLASSIFY** → apply the operator-equivalent downstream action + append a `planner-resolved` entry to `pass-through-log.md` + **skip the emit, continue the loop**. On **ESCALATE** → proceed to the inline emit. Non-subset types and retry re-fires → ESCALATE without dispatching the resolver. **No v3 halt is `subset_member`, so this branch never fires on v3** (§3b); retained for a future v1/v2 wave. |
| **PRA-W3E (current, v3)** | If `wave_protocol_version == 3` AND SURFACE_TYPE ∈ the **`enrich_only` set** (`implementer-blocked`, `manual-review`, `end-of-wave-blocker`) AND not a retry re-fire: dispatch `@resolver` in **`enrich_only` mode**. The resolver is forced to **ESCALATE** (RESOLVE/RECLASSIFY disabled — see rubric below); proceed to the inline emit **enriched** with its analysis. Every other SURFACE_TYPE, every v1/v2 firing, and every retry re-fire → ESCALATE without dispatching the resolver (W2 behavior). |

**Load-bearing invariant (ADR-033 §1a):** the inline emit (`surface-prompt.md` write + fenced block +
end turn) happens **ONLY on ESCALATE**. RESOLVE/RECLASSIFY never enter the emit sequence — there is no
operator to resume to, and entering it would corrupt the latest-wins `surface-prompt.md` slot with a
question that was never asked. The order-load-bearing write-precedes-emit sequence
(`wave-resume-context.md` §5, guarded by `test-orchestrated-advance.sh` Assertion 5) is preserved
exactly on ESCALATE and skipped entirely otherwise.

### `enrich_only` rubric (PRA-W3E — ESCALATE-only enrichment, ADR-033 §3c)

The three v3-live halts (`implementer-blocked`, `manual-review`, `end-of-wave-blocker`) are the
**`enrich_only` set**. On a `wave_protocol_version == 3` wave, when one of these fires at its seam,
the site follows this rubric instead of the bare W2 emit:

1. **What the resolver receives.** The already-computed surface payload (`{SURFACE_TYPE,
   fired_criterion, rendered question/options/context, current_ticket, current_phase, run_dir}`) plus
   the flag **`enrich_only: true`**. This is distinct from `subset_member`: `subset_member` invites
   RESOLVE/RECLASSIFY (the v1 subset, dormant on v3); `enrich_only` explicitly **forbids** them.
   Dispatch `@resolver` read-only with **`MODE: halt`** in the dispatch prompt (it performs no writes;
   the orchestrator performs all writes).

2. **The resolver returns ESCALATE — always.** RESOLVE and RECLASSIFY are **disabled** for
   `enrich_only` types. If the resolver nonetheless returns RESOLVE/RECLASSIFY (model error), the
   orchestrator **treats it as ESCALATE** and proceeds to the emit — it NEVER auto-disposes on v3.
   The escalate-by-default floor is structural: an `enrich_only` halt always terminates in the
   operator surface. (Criteria 3 and 4 already ESCALATE always per the resolver's own authority map —
   `enrich_only` does not weaken that.) A retry re-fire (`retry_context` present) skips the dispatch
   entirely and ESCALATEs bare — bounded retry, ADR-033 §5.

3. **Fold the analysis into `surface-prompt.md`.** Before step 1 of the emission contract (the
   `surface-prompt.md` write), prepend an **`## Analysis (resolver)`** section composed from the
   resolver's ESCALATE output: its `CRITERION_MATCH`, `ESCALATION_REASON`, `RECOMMENDED_DISPOSITION`
   (the pre-chewed recommendation), and `OPERATOR_OPTIONS` (which inform — never replace — the
   surface's own Options). The section sits **inside `surface-prompt.md`, before** the fenced
   `wave-resume-context` block, preserving the load-bearing write-precedes-fenced-block ordering
   (`wave-resume-context.md` §5; Assertion 5). The fenced block, SURFACE_TYPE, and the seven canonical
   keys are **unchanged** — enrichment adds a prose section, it does not alter the resume contract.

4. **Optional audit log.** Append an `escalation-enriched` event to `pass-through-log.md` via
   `emit_pass_through_summary()` (resolver dispatched, verdict ESCALATE, recommendation attached). No
   `planner-resolved` entry (nothing is resolved on v3); no new file. Skippable if it adds friction —
   `surface-prompt.md` already carries the analysis.

**The decision still lands on the operator.** Enrichment changes only *how much pre-analysis* the
operator reads at the surface, never *whether* the halt surfaces. A resolver bug degrades to "halts
like today, minus the `## Analysis` section," never to "silently doesn't halt."

**Why the emit stays inline (not centralized into a called helper):** Assertion 5 guards per-site that
the `surface-prompt.md` write precedes the fenced block *at that site*; the compute (question/options)
genuinely varies per site. The chokepoint is therefore a **shared referenced protocol** (this
section), not a single textual location. The marker is the reference; the emit is local.

Full contract + the `@resolver` agent: `docs/decisions/ADR-033-planner-resolution-authority-tier.md`,
`core/agents/resolver.md`.

---

## Template catalog (closed for v1; extension is ADR amendment)

Each template defines: name, SURFACE_TYPE (per wave-resume-context.md enum), expected criterion match, halt_class_key derivation rule, question shape, options shape.

### template: `cto-simplify`

- **SURFACE_TYPE:** `cto-simplify`
- **Expected criterion:** crit-1 (architectural; CTO declared the scope is too big or shape is wrong)
- **halt_class_key derivation:** `cto-simplify:${current_ticket}` (per-ticket; new tickets generate new key)
- **Producer:** `core/config/phases/orchestrated/t-cto.md` Step 4
- **Question shape:** "CTO has recommended SIMPLIFY for ticket {ticket_key}. The simplified scope is: {summary}. The original scope was: {orig_summary}. Which scope governs going forward?"
- **Options shape:** "GO (accept SIMPLIFY) / OVERRIDE (proceed with original) / feedback (re-invoke cto-advisor with notes) / END (close run)"

### template: `cto-defer`

- **SURFACE_TYPE:** `cto-defer`
- **Expected criterion:** crit-1
- **halt_class_key derivation:** `cto-defer:${current_ticket}`
- **Producer:** `t-cto.md` Step 4
- **Question shape:** "CTO has recommended DEFER for ticket {ticket_key}. Rationale: {summary}. Override and proceed, or close run?"
- **Options shape:** "GO (override and proceed with original scope) / END (close run)"

### template: `cto-no-go`

- **SURFACE_TYPE:** `cto-no-go`
- **Expected criterion:** crit-1
- **halt_class_key derivation:** `cto-no-go:${current_ticket}`
- **Producer:** `t-cto.md` Step 4
- **Question shape:** "CTO has recommended NO-GO for ticket {ticket_key}. Rationale: {summary}. Override and proceed, or close run?"
- **Options shape:** "GO (override and proceed) / END (close run)"

### template: `consensus-drift`

- **SURFACE_TYPE:** `consensus-drift`
- **Expected criterion:** crit-1
- **halt_class_key derivation:** `consensus-drift:${current_ticket}`
- **Producer:** `t-consensus.md`
- **Question shape:** "cto-consensus returned DRIFTED for ticket {ticket_key}. The spec and CTO evaluation are inconsistent. Re-invoke cto-advisor with spec context, or override and proceed?"
- **Options shape:** "REINVOKE / OVERRIDE / END"

### template: `validate-fail`

- **SURFACE_TYPE:** `validate-fail`
- **Expected criterion:** crit-2 (spec shift implied by atom-not-satisfied that cannot remediate) OR crit-5 (resolver INDETERMINATE on the failure)
- **halt_class_key derivation:** `validate-fail:${current_ticket}:${iter}`
- **Producer:** `t-validate.md` Step 5
- **Question shape:** "spec-conformance returned FAIL for ticket {ticket_key} after one-shot remediation. {N} atoms NOT_SATISFIED: {atom_list}. How should the substrate proceed?"
- **Options shape:** "REMEDIATE-AGAIN (re-dispatch implementer with refined guidance) / DEFER (approve covering deferrals to clear the atoms) / END (mark ticket blocked; halt wave)"

### template: `review-changes`

- **SURFACE_TYPE:** `review-changes`
- **Expected criterion:** crit-2 (substantive blocking findings that require operator decision on direction) OR crit-1 (architectural rule violation surfaced)
- **halt_class_key derivation:** `review-changes:${current_ticket}:${iter}`
- **Producer:** `t-review.md` Step 5 (the consolidated gate surface, ADR-036 — carries the whole escalation set: REQUEST_CHANGES blocking findings, manual-review crit-1/2/3, and INDETERMINATE disagreements, batched into one halt)
- **Question shape:** "code-reviewer VERDICT: {verdict} for ticket {ticket_key}. {N} findings could not be auto-disposed (INDETERMINATE / criterion-matched): {finding_summaries}. The rest auto-disposed. Disposition per finding?"
- **Options shape (one batched reply):** "APPLY <CR-NNN …> / DEFER <CR-NNN> <target> <summary> / DISMISS <CR-NNN> <rationale>"

### template: `review-discussion` — DEPRECATED (ADR-036)

> Retired by the consolidated gate surface. NEEDS_DISCUSSION findings are resolved by `@resolver` and, if INDETERMINATE/criterion-matched, fold into the single `review-changes` batch. No per-finding loop. Template kept for historical resume-block parsing only.

- **SURFACE_TYPE:** `review-discussion`
- **Expected criterion:** crit-1 OR crit-5 (per-finding; iterated)
- **halt_class_key derivation:** `review-discussion:${finding_signature}` where `finding_signature` is a hash of the implementer-response position + CR-NNN identifier (lets precedent memory recognize same-shape disagreements within wave)
- **Producer:** `t-review.md` Step 7c per-finding loop
- **Question shape:** "NEEDS_DISCUSSION on {CR-NNN}: {finding_one_liner}. Implementer's position: {position}. Reviewer's position: {position}. How should this CR-NNN resolve?"
- **Options shape:** "APPLY / DISMISS / DEFER <target_ticket>"

### template: `manual-review`

- **SURFACE_TYPE:** `manual-review`
- **Expected criterion:** crit-1, crit-2, OR crit-3 (per ADR-018 gating; ≥1 finding meets one of these)
- **halt_class_key derivation:** `manual-review:${current_ticket}:${iter}` (per-ticket-per-iter; allows precedent memory across iterations)
- **Producer:** `w-finalize.md` Step 4d (v3 wave-end manual review). At t-review (v1/v2), manual review folds into the consolidated `review-changes` surface (ADR-036) — it is NOT a separate halt.
- **Question shape:** "Manual review halt for ticket {ticket_key}. {N} findings meet criteria 1-3: {finding_summaries_with_criteria}. Approve disposition path, or revise?"
- **Options shape:** "APPROVE (mark manual-review-approved; advance to t-commit) / REVISE (specify alternative dispositions) / END"

### template: `suggestion-disposition` — DEPRECATED (ADR-036)

> Retired by the consolidated gate surface. suggestion/nit findings auto-dispose via `@resolver`; if INDETERMINATE/criterion-matched they fold into the single `review-changes` batch. No per-finding loop. Template kept for historical resume-block parsing only.

- **SURFACE_TYPE:** `suggestion-disposition`
- **Expected criterion:** crit-5 (per-finding; the resolver returned INDETERMINATE or the finding was authored without a clear disposition)
- **halt_class_key derivation:** `suggestion-disposition:${finding_signature}`
- **Producer:** `t-review.md` Step 7a.0 per-finding sub-loop (B3)
- **Question shape:** "Per-finding disposition for {CR-NNN} (suggestion/nit prefix): {finding_one_liner}. Resolver verdict: INDETERMINATE — {rationale}. How should this be disposed?"
- **Options shape:** "APPLY (queue for next ticket) / DEFER <target_ticket> / DISMISS / ESCALATE (substrate fault)"

### template: `implementer-blocked`

- **SURFACE_TYPE:** `implementer-blocked`
- **Expected criterion:** crit-2 (implementer couldn't deliver stated AC) OR crit-1 (implementer surfaced architectural concern)
- **halt_class_key derivation:** `implementer-blocked:${current_ticket}:${iter}`
- **Producer:** `t-implement.md`
- **Question shape:** "Implementer returned status: {blocked|partial} for ticket {ticket_key}. Reason: {summary}. Re-dispatch with refined guidance, amend ticket scope, or mark ticket blocked?"
- **Options shape:** "REDISPATCH <guidance> / AMEND-MANIFEST <delta> / BLOCK / END"

### template: `amendment-proposed`

- **SURFACE_TYPE:** `amendment-proposed`
- **Expected criterion:** crit-2 (mid-execution scope shift; per ADR-009)
- **halt_class_key derivation:** `amendment-proposed:${source_ticket}` (per-source-ticket; each amendment site generates one key)
- **Producer:** `t-implement.md` Step 6 / `t-validate.md` Step 0
- **Question shape:** "Ticket {source_ticket} introduced scope shift. {N} affected downstream tickets: {downstream_list}. Per-downstream amendment text: {drafted_text_per_downstream}. APPROVE-ALL / APPROVE-INDIVIDUAL / EDIT / REJECT?"
- **Options shape:** "APPROVE-ALL / APPROVE-INDIVIDUAL <key list> / EDIT <key> / REJECT"

### template: `deferral-proposed` — DEPRECATED (ADR-036)

> Retired by the consolidated gate surface. A deferral is now a one-line record in `findings/deferrals-log.md` (no propose/surface/approve ceremony). The resolver's DEFER verdict auto-disposes; only an INDETERMINATE deferral verdict folds into the single gate batch. Template kept for historical resume-block parsing only.

- **SURFACE_TYPE:** `deferral-proposed`
- **Expected criterion:** crit-5 (resolver INDETERMINATE on deferral verdict) OR crit-4 (deferral creates cross-wave dependency requiring operator authorization)
- **halt_class_key derivation:** `deferral-proposed:${source_ticket}:${target_ticket}`
- **Producer:** `t-validate.md` Step 6 / `t-review.md` Step 8 per-line loop
- **Question shape:** "DEFERRAL proposed: from {source_ticket} to {target_ticket}. Summary: {summary}. APPROVE (add to ledger) / REJECT (re-route as APPLY/DISMISS) / EDIT (modify before approving)?"
- **Options shape:** "APPROVE / REJECT / EDIT <text>"

### template: `end-of-wave-blocker`

- **SURFACE_TYPE:** `end-of-wave-blocker`
- **Expected criterion:** crit-2 (wave-scope integration issue) OR crit-3 (security finding from end-of-wave gates) OR crit-1 (architectural)
- **halt_class_key derivation:** `end-of-wave-blocker:${finding_class}` (finding_class derived from gate-output severity + agent type)
- **Producer:** `w-finalize.md` (also fires from ADR-023 Step 0 boot failure)
- **Question shape:** "End-of-wave gate {gate_name} returned blocking finding(s) on committed ticket(s) {tickets}. Finding summaries: {finding_summaries}. REVERT (revert specific ticket commits) / FOLLOW-UP (log for next wave) / END (halt wave)?"
- **Options shape:** "REVERT <ticket list> / FOLLOW-UP / END"

### template: `wave-cto-disposition`

- **SURFACE_TYPE:** `wave-cto-disposition`
- **Expected criterion:** crit-1 (architectural; CTO's wave-level evaluation surfaced ticket-level concerns) OR crit-2 (scope shift across wave)
- **halt_class_key derivation:** `wave-cto-disposition` (single-shot per wave; no per-ticket subkey)
- **Producer:** `w-cto.md` Step 4 (ADR-015 wave-level review trio)
- **Question shape:** "Wave-level CTO evaluation returned {N} tickets with verdict ≠ GO: {ticket_verdict_summaries}. Per-ticket dispositions or wave-wide override?"
- **Options shape:** "ACCEPT-AS-IS (per-ticket halts will fire at t-cto entry per ticket) / OVERRIDE-WAVE / END"

### template: `wave-pm-discord`

- **SURFACE_TYPE:** `wave-pm-discord`
- **Expected criterion:** crit-2 (wave-level spec has structural gaps not resolvable via iter-2 remediation)
- **halt_class_key derivation:** `wave-pm-discord`
- **Producer:** `w-pm-spec.md` Step 8 (ADR-015 spec authoring; gap after iter-2)
- **Question shape:** "Wave-level pm-spec returned COMPLETENESS: GAP after iter-2 remediation. Remaining gaps: {gap_summaries}. Authorize gap acceptance, re-author wave-spec, or close run?"
- **Options shape:** "ACCEPT-GAPS / REAUTHOR / END"

### template: `wave-consensus-drift`

- **SURFACE_TYPE:** `wave-consensus-drift`
- **Expected criterion:** crit-1
- **halt_class_key derivation:** `wave-consensus-drift`
- **Producer:** `w-cto-consensus.md` (ADR-015 consensus check after iter-2 cap)
- **Question shape:** "Wave-level cto-consensus returned DRIFTED after iter-2. Inconsistency: {summary}. Override and proceed to per-ticket loop, or re-author wave-cto / wave-spec?"
- **Options shape:** "OVERRIDE / REAUTHOR-CTO / REAUTHOR-SPEC / END"

### template: `wave-drift-detected`

- **SURFACE_TYPE:** `wave-drift-detected`
- **Expected criterion:** crit-2 (drift-check Layer 1 surfaced cross-ticket scope drift)
- **halt_class_key derivation:** `wave-drift-detected:${current_ticket}:${check_id}`
- **Producer:** `t-drift-check.md` (Layer 1 v2)
- **Question shape:** "Drift-check Layer 1 returned DRIFTED for ticket {ticket_key} on Check {N}: {check_name}. {drift_description}. APPLY-AMENDMENT / SKIP / ESCALATE / END?"
- **Options shape:** "APPLY-AMENDMENT / SKIP / ESCALATE / END"

### template: `end-of-wave-structural-fail`

- **SURFACE_TYPE:** `end-of-wave-structural-fail`
- **Expected criterion:** crit-1 (architectural; atom-coverage mismatch indicates spec-decomposition error)
- **halt_class_key derivation:** `end-of-wave-structural-fail`
- **Producer:** `w-finalize.md` Step 4c (per ADR-016 structural check)
- **Question shape:** "End-of-wave structural check returned FAIL. Per-ticket atom-coverage mismatch: {mismatch_summary}. The wave-spec's per-ticket AC counts do not match the spec-conformance atoms. Halt wave for re-decomposition, or accept structural deviation?"
- **Options shape:** "ACCEPT-DEVIATION (log + advance) / REDECOMPOSE (halt wave for spec-author re-work) / END"

### template: `unknown`

- **SURFACE_TYPE:** `unknown`
- **Expected criterion:** crit-1 (defaults to architectural; unknown halt class is itself an architectural concern requiring substrate amendment)
- **halt_class_key derivation:** `unknown:${producer_site}`
- **Producer:** any phase file that hits a halt site not yet enumerated
- **Question shape:** "Substrate emitted an unrecognized halt from {producer_site}. Surface raw context: {context}. How should the substrate proceed?"
- **Options shape:** "PROCEED-MANUALLY <action> / ESCALATE (substrate-bug; halt for amendment) / END"

---

## Implementation contract

Phase files reference templates via a comment marker:

```
<!-- HALT-TEMPLATE: cto-simplify -->
```

Substrate tests (`core/scripts/test-orchestrated-mode.sh` extended) verify that every halt-emission site references a template in this catalog AND that the template's expected criterion appears in the halt's `CRITERION_MATCHED:` line.

Adding a new halt template requires:
1. Adding the template definition to this catalog (with name, SURFACE_TYPE, expected criterion, derivation rule, question/options shape).
2. Adding the corresponding SURFACE_TYPE to `wave-resume-context.md` Section 3 enum.
3. Updating the producer site's phase file to cite the new template.

Template removal requires verifying no producer site cites the removed template (substrate-CI check).
