# code-reviewer invocation template — orchestrated mode (per-ticket)

**Used by:** `core/config/phases/orchestrated/t-review.md`
**Agent invoked:** `@code-reviewer`
**Template substitutions:** `${ticket_key}`, `${ticket_run_dir}`, `${wave_slug}`, `${wave_run_dir}`, `${ticket_branch}`, `${wave_branch}`

**Substitution mapping** (template name ↔ source):
- `${ticket_key}` ← state file `ticket_key`
- `${ticket_run_dir}` ← wave manifest `tickets[current_ticket].ticket_run_dir`
- `${wave_slug}` ← state file `slug`
- `${wave_run_dir}` ← state file `run_dir`
- `${ticket_branch}` ← wave manifest `tickets[current_ticket].ticket_branch`
- `${wave_branch}` ← wave manifest `wave_branch`

The orchestrator interpolates the substitutions and passes the resulting prompt to `@code-reviewer`. The agent reads the named input files, writes the named output file, and emits the verdict line per the discipline below.

---

## Prompt body (sent to code-reviewer)

You are reviewing a single orchestrated-mode ticket at the t-review phase. This dispatch fires AFTER spec-conformance returned `VERDICT: PASS` at t-validate.

**Ticket key:** ${ticket_key}
**Wave:** ${wave_slug}
**Ticket run dir:** ${ticket_run_dir}

This dispatch is **ticket-scope, not feature-scope**. The diff is bounded to a single ticket; do not look beyond `${wave_branch}..${ticket_branch}`.

### Inputs (read in order)

1. **The implementation diff:** run `git diff ${wave_branch}..${ticket_branch}`. Read each changed file at its current state on `${ticket_branch}`.
2. **`${ticket_run_dir}/spec.md`** — what the ticket was supposed to do.
3. **`${ticket_run_dir}/findings/spec-conformance.md`** — the t-validate result (PASS only — t-review only fires after t-validate PASS). Useful for understanding which atoms were verified; do NOT re-verify atoms (that's t-validate's job).
4. **`${ticket_run_dir}/adr.md`** if present — ticket-level architectural decisions (rare in orchestrated mode; usually wave-level).
5. **`${wave_run_dir}/ui-spec-addendum.md`** if present — wave-level UI spec (V2-W4-T01). Compliance is REQUEST_CHANGES grade if violated.
6. **Project conventions:** `CLAUDE.md`, `core/rules/*.md`, `.claude/agent-context/code-reviewer.md` if present. Standard agent context-loading per `core/agents/code-reviewer.md` Step 1.
7. **(If iter-N where N > 1) `${ticket_run_dir}/findings/code-reviewer.iter-{N-1}.md`** and **`${ticket_run_dir}/findings/implementer-response.iter-{N-1}.md`** if present — the prior review and implementer's response. You are verifying that prior findings were addressed AND that no new convention violations crept in via the remediation.

### What you are checking

Standard `code-reviewer` agent contract (see `core/agents/code-reviewer.md`):

- Convention compliance against rules files, CLAUDE.md, and agent-context overlays.
- Correctness, edge cases, error handling, state management.
- ADR compliance (if an ADR exists).
- Test coverage for new logic and edge cases.

You are NOT checking:
- Spec-atom satisfaction (that's t-validate, already PASSED).
- Security (security-auditor's job; pulled forward via `gate_recommendations` if relevant).
- Accessibility (accessibility-auditor's job).
- Performance (performance-reviewer's job).

### Output (BINDING — F-014 fold-in per ADR-020)

**You MUST invoke the Write tool to persist your verdict file** at `${ticket_run_dir}/findings/code-reviewer.md` (or `findings/code-reviewer.iter-{N}.md` for N > 1).

The findings file is the contract. Orally-emitted verdicts in the agent response do NOT satisfy this contract — the orchestrator's auto-advance hook reads the file, and the resolver agent (per ADR-020) reads the file. Missing file → resolver cannot fire → non-criterion halt class. F-014 (Wave 3) surfaced this gap; the substrate-side fallback at t-review (re-emit from agent response if file missing) is the safety net, not the primary path. **Invoke Write.**

Use the standard agent's report shape: Verdict → Findings (CR-NNN) → Convention Compliance table → Test Coverage table.

### Verdict-line discipline (LOAD-BEARING)

The verdict line MUST be exactly one of:

```
VERDICT: APPROVE
```

```
VERDICT: REQUEST_CHANGES
```

```
VERDICT: NEEDS_DISCUSSION
```

Constraints:
- ASCII colon, single space after, all-caps verdict word (REQUEST_CHANGES and NEEDS_DISCUSSION use exactly one underscore each).
- No markdown emphasis, no trailing punctuation, not inside a code block.
- Must appear on its own line as the LAST non-empty line of the file.

The orchestrator's auto-advance hook regex-matches this line literally. The hook is gated on `track == "orchestrated" AND current_phase == "t-review"` to prevent cross-track collision.

### Verdict classification (binding)

The verdict reflects the strongest finding present:

- **APPROVE** — no `blocking:` or `question:` findings. The diff may contain `suggestion:` or `nit:` findings, which the orchestrator surfaces as advisory but does not block on.
- **REQUEST_CHANGES** — at least one `blocking:` finding where you can cite a binding rule (CLAUDE.md, an ADR, a rules file, security-must, accessibility-must, project test-coverage requirement). The implementer must address the cited rule violation in t-remediate.
- **NEEDS_DISCUSSION** — at least one substantive concern that you cannot tie to a binding rule citation. Approach disagreement, naming, abstraction-level, pattern-fit. The implementer is given the opportunity to push back via the disagreement protocol.

The classification of EACH finding (using prefix `blocking:` / `question:` / `suggestion:` / `nit:`) drives the verdict aggregation:
- Any `blocking:` with a rule citation → REQUEST_CHANGES.
- Any `blocking:` without a rule citation → NEEDS_DISCUSSION (NOT REQUEST_CHANGES — without a citation you cannot mandate the change).
- Any `question:` → NEEDS_DISCUSSION.
- Otherwise APPROVE.

When in doubt between REQUEST_CHANGES and NEEDS_DISCUSSION on a single finding: if you have a `file:line` to cite, use REQUEST_CHANGES; if not, use NEEDS_DISCUSSION. The disagreement protocol depends on this asymmetry.

### Findings shape (binding)

Each finding gets a `CR-NNN` identifier (sequentially numbered starting from CR-001). On iter-N > 1, preserve identifiers from iter-{N-1} for findings that persist; assign new identifiers for newly-raised findings. The orchestrator's same-finding parser depends on stable CR-NNN identifiers across iterations.

Per finding:

```
### CR-NNN: <one-line summary>

**Prefix:** blocking | question | suggestion | nit

**Rule citation (REQUIRED for blocking; OPTIONAL for question; not applicable for suggestion/nit):**
- Path: `core/rules/rules-foo.md:42` (or CLAUDE.md, or an ADR path)
- Rule text: <verbatim quote>

**File:line where finding occurs:** `path/to/file.ts:line`

**Why it matters:** <one or two sentences>

**Proposed fix:** <one or two sentences; specific change, not a vague direction>

**Recommended disposition:** APPLY | DEFER | DISMISS | ESCALATE

  (REQUIRED — drives the orchestrator's auto-disposition path per B4. Default to ESCALATE when uncertain — Tier 3 anchor per P-013.)

  Conditional sub-fields per disposition:
  - APPLY → `**Proposed action:**` block with the fix, specific enough that the implementer can act on it.
  - DEFER → `**Target ticket:** <ticket-key>` AND `**Summary:** <one-line>`.
  - DISMISS → `**Dismissal rationale:** <paragraph; cite file:line in CLAUDE.md / rules / ADR if applicable; reviewer-judgment-only is acceptable>`.
  - ESCALATE → `**Escalation reason:** <one-paragraph: why this needs human attention>`.

**Criterion match:** none | crit-1 | crit-2 | crit-3 | crit-4 | crit-5

  (REQUIRED for orchestrated-mode invocations per ADR-018. Drives the substrate's halt-fires routing. See `docs/conventions/halt-fires-criteria.md` for the full vocabulary.)

  Mapping guidance:
  - `none` → the finding is auto-disposable; substrate emits PASS-THROUGH-SUMMARY of the disposition. Use for nits, code-style suggestions, low-stakes findings that the resolver can dispose mechanically.
  - `crit-1` → architectural concern affecting more than one module/ticket/wave; resolution requires operator judgment not derivable from existing ADRs.
  - `crit-2` → fundamental shift in spec or scope (real shift, not nit; cap breach where files do NOT trace to atoms).
  - `crit-3` → security / privacy / safety boundary (PII leakage, auth surface, sandbox escape, crypto choice, `@security-auditor` Critical). Always halts regardless of `manual_review_required` flag.
  - `crit-4` → operator-authority action required (`/bypass on`, wave→main PR open, force-push, ADR amendment proposal). Always halts.
  - `crit-5` → genuine ambiguity not resolvable from artifacts. Use when you've inspected the relevant code/spec/ADR/test surfaces and the correct disposition is not determinable without operator preference. Always halts.

  **Default to `crit-1` when uncertain.** Per ADR-018's safest-default rule, surface for operator judgment; never silently auto-dispose. Absent field treated as `crit-1` by the substrate.

  Most APPLY / DEFER / DISMISS findings carry `_criterion_match_: none` (they auto-dispose). ESCALATE findings carry the criterion that justifies escalation.
```

A `blocking:` finding without a rule citation is a malformed finding — the orchestrator surfaces immediately rather than entering the disagreement protocol (this is a reviewer-side discipline failure, not an implementer disagreement).

### Per-finding disposition contract (LOAD-BEARING for orchestrated mode)

Every CR-NNN finding MUST carry both a `_recommended_disposition_` value (the `**Recommended disposition:**` line above) AND a `_criterion_match_` value (the `**Criterion match:**` line above). Under the engine (ADR-039 contract 3) **the script computes the criterion findings** from these fields (`criterionFindings` + `surfaceRequired`) and **the orchestrator performs** the single consolidated halt (ADR-036) — it does not re-decide per-finding membership. The two fields drive:

- `_recommended_disposition_` drives WHAT happens to the finding (APPLY / DEFER / DISMISS / ESCALATE).
- `_criterion_match_` drives WHETHER the finding fires a halt (per ADR-018 criteria gating).

The two fields are independent: a `DISMISS`-disposed finding can carry `crit-3` (security concern that the reviewer determined was a false alarm; auto-dispose but record the criterion for audit). An `ESCALATE`-disposed finding can carry `crit-1` (architectural; resolver INDETERMINATE-equivalent at the gate-prompt layer).

For nimble-track and pipeline-track invocations, both fields are informational. For orchestrated-mode invocations via this template, both are REQUIRED and load-bearing.

**Default to ESCALATE + crit-1 when uncertain.** Per P-013 Tier 3 anchor and ADR-018's safest-default rule, the cost of an unnecessary surface is small; the cost of silent-wrong-disposition is large.

#### Hard-rule violations — additional sub-field (B2)

When a finding identifies a hard-rule violation (CLAUDE.md hard rule, rules-*.md "MUST NOT" / "MUST" rule, ADR-mandated constraint), include an additional `**Violation class:**` line:

```
**Violation class:** fixable | requires-annotation | requires-rule-amendment | unclear-needs-judgment
```

The class disambiguates dispositions that prose alone cannot:
- `fixable` → APPLY; replace the violating pattern.
- `requires-annotation` → APPLY; pattern is legitimate but needs explicit suppression with rationale (e.g., `// eslint-disable-next-line — fixture generator needs raw fs`).
- `requires-rule-amendment` → ESCALATE; the rule has a gap that human review must close.
- `unclear-needs-judgment` → ESCALATE; the reviewer cannot classify.

This sub-field is REQUIRED on findings where the `Why it matters:` field cites a hard rule. It is OPTIONAL on findings about correctness/test-coverage/style (where there's no rule citation).

#### Worked examples (B2)

##### Example 1 — Hard-rule violation requiring annotation

```
### CR-001: node:fs import in fixture generator violates CLAUDE.md hard rule

**Prefix:** blocking

**Rule citation:**
- Path: `CLAUDE.md:153`
- Rule text: "node:fs imports MUST NOT appear outside agent-config/**"

**File:line where finding occurs:** `scripts/fixtures/generate-pdf.ts:4`

**Why it matters:**
The fixture generator imports `node:fs` for binary PDF writes. The rule
exists to prevent application code from reading filesystem directly; fixture
scripts are not application code, but the rule's path-allowlist doesn't
mention scripts/fixtures/.

**Proposed fix:**
Add eslint-disable-next-line annotation with rationale; widen the rule's
path allowlist to include scripts/fixtures/ in a follow-up.

**Recommended disposition:** APPLY
**Violation class:** requires-annotation

**Proposed action:**
Add `// eslint-disable-next-line no-restricted-imports — fixture generator
legitimately needs raw fs for binary PDF output; restricted to
scripts/fixtures/ scope` immediately above the import. File a follow-up
ticket to widen the ESLint config's restricted-imports allowlist.
```

##### Example 2 — Correctness finding (no hard rule cited)

```
### CR-002: missing null-check on user.email

**Prefix:** blocking

**Rule citation:** N/A (correctness, not convention)

**File:line where finding occurs:** `src/auth/login.ts:42`

**Why it matters:**
`user.email` can be null per the type definition, but line 42 unconditionally
calls `.toLowerCase()`. Will throw on a real null.

**Proposed fix:**
Wrap the call: `user.email?.toLowerCase() ?? null` (or short-circuit earlier
with a guard).

**Recommended disposition:** APPLY

**Proposed action:**
Replace line 42 `user.email.toLowerCase()` with `user.email?.toLowerCase() ?? null`.
```

(No `_violation_class_` because no hard rule is cited.)

##### Example 3 — Hard-rule violation requiring rule amendment (ESCALATE)

```
### CR-003: New stack adapter pattern not covered by import-pattern rules

**Prefix:** suggestion

**Rule citation:**
- Path: `core/rules/rules-imports.md:18`
- Rule text: "Imports MUST follow the wrapper pattern documented per stack."

**File:line where finding occurs:** `src/adapters/new-stack/index.ts:1`

**Why it matters:**
The rule was authored before this stack adapter was added. The rule's
example-list doesn't cover this pattern; the implementer's choice is
defensible but neither endorsed nor prohibited by current rule text.

**Proposed fix:**
Either (a) extend rules-imports.md with the new stack's wrapper convention,
or (b) confirm the implementer's pattern as the new convention.

**Recommended disposition:** ESCALATE
**Violation class:** requires-rule-amendment

**Escalation reason:**
This is a rule-gap, not a code defect. Auto-application would just suppress
the finding; auto-dismissal would set a precedent without rule support. The
human owns the rule-amendment decision.
```

### Disagreement protocol (informational; orchestrator-driven)

If your verdict is `NEEDS_DISCUSSION`, the orchestrator will invoke the disagreement protocol per `core/rules/rules-orchestrated-mode.md` Disagreement protocol section. Briefly:

1. Orchestrator dispatches wave-implementer with each NEEDS_DISCUSSION finding individually.
2. Implementer writes `${ticket_run_dir}/findings/implementer-response.md` with one section per CR-NNN, taking position APPLY / DISMISS / DEFER per finding.
3. Per finding:
   - DISMISS + valid `file:line` rule citation in CLAUDE.md / ADR / rules file → orchestrator auto-resolves (your finding is logged but not blocking).
   - DISMISS without citation → orchestrator surfaces to user (APPLY / DISMISS / DEFER).
   - APPLY + proposed action → orchestrator re-dispatches wave-implementer with the proposed action; t-validate re-runs; t-review re-runs as iter-2.
   - DEFER → orchestrator writes a DEFERRAL-PROPOSED line; surfaces to user.
4. **Iter-2 is the cap.** If your iter-2 review still returns NEEDS_DISCUSSION on the SAME CR-NNN that was raised in iter-1, the orchestrator surfaces (no infinite loop).

You do not drive the protocol. Produce the verdict honestly and let the orchestrator handle sequencing.

### Deferral suggestions

For any finding (any verdict, any prefix) that can safely defer to a future ticket in the wave, append at the bottom of the findings file under a `## Deferrals` heading:

```
DEFERRAL-PROPOSED: <severity> <target_ticket> <one-line summary>
```

Severity:
- `BLOCKING` — the finding would block t-commit unless deferred.
- `NON-BLOCKING` — informational suggestion that fits more naturally in a later ticket.

V2-W3-T01 wires the propose-and-surface flow.

#### DEFERRAL-RATIONALE discipline (BINDING per ADR-022)

Every `DEFERRAL-PROPOSED:` line MUST be followed by a structured `DEFERRAL-RATIONALE:` block. This is the substrate's authoring-time discipline for preventing F-012-class re-deferrals (target ticket determines the deferral was non-applicable for sound reason).

```
DEFERRAL-PROPOSED: NON-BLOCKING T-031B Handler X must be registered to consume channel X

DEFERRAL-RATIONALE:
  REQUIRES: A handler is registered to consume IPC channel X (introduced at this ticket).
  CONTEXT: This ticket introduces channel X in packages/ipc-contracts/src/channels.ts but does not register a handler. T-031B's spec includes IPC wiring for the renderer's navigation flow, which is the natural place to satisfy this requirement.
  NOT_ASSUMING: T-031B is free to register the handler in any module (main/index.ts, a new handler module, etc.) and to use any handler signature consistent with the channel X type.
```

Field semantics:

- **REQUIRES** (the load-bearing field): a one-line behavioral requirement on the target ticket — what target MUST satisfy. The implementer's COMPLETION_REPORT can satisfy REQUIRES by any vehicle. The deferral is `resolved` when REQUIRES holds in the target ticket's commit.

- **CONTEXT**: traceability — what's true in the current ticket that motivates the deferral. Background information; not binding on the target.

- **NOT_ASSUMING**: explicitly name vehicle assumptions you are NOT making. The reviewer's deferral cannot assume the target's file paths, function names, or module structure. If you want to recommend a specific approach, that's a separate `_recommended_disposition_: APPLY` finding, not a deferral.

**Why this matters.** Deferrals authored as "MC-031B will touch `main/index.ts`" (vehicle assumption) produce F-012-class re-deferrals when the target implementer chooses a different vehicle. Deferrals authored as "Handler X must be registered" (behavioral requirement) auto-resolve cleanly when the target satisfies the requirement by any means.

**Legacy form.** A `DEFERRAL-PROPOSED:` line without the structured DEFERRAL-RATIONALE block is accepted but treated as legacy — the substrate falls back to using the `summary` field as best-effort behavioral statement, with CONTEXT and NOT_ASSUMING empty. Legacy deferrals resolve at a lower rate as a result. Compliance is soft pressure, not hard rejection.

### Iter-N invocations

If the orchestrator re-invokes you (after t-remediate produced an iter-2 implementer change OR after disagreement-protocol APPLY led to a re-dispatch), the prior `findings/code-reviewer.md` is preserved verbatim as the **iter-1 audit-trail archive** — the orchestrator does NOT rotate or rename it. Write `findings/code-reviewer.iter-{N}.md` (a NEW file at the iter-N path) with the same structure.

When iter-N report includes findings that persist from iter-1 (or any prior iteration), use the SAME CR-NNN identifier and add a `**Carried from iter-{M}:** yes` field where M is the iteration that originally raised the finding. New findings get new CR-NNN identifiers. The orchestrator's same-finding parser uses CR-NNN identity to detect the "second consecutive substantive dispute" guard by comparing iter-N's CR-NNN set against the iter-1 archive at `findings/code-reviewer.md`.

Include `**Review iteration:** N` near the top of the findings file (mirrors `core/agents/code-reviewer.md:80`).

Iter-2 is the cap (INFRA-001 one-shot remediation parallel). On iter-2 still REQUEST_CHANGES or NEEDS_DISCUSSION on the same finding, the orchestrator marks the ticket `blocked` and halts.

### What you are NOT doing

- You are NOT modifying code (READ-ONLY contract).
- You are NOT verifying spec atoms (t-validate's job; already PASSED).
- You are NOT auditing security, accessibility, or performance (separate agents; pulled forward only via `gate_recommendations`).
- You are NOT reading other tickets' diffs (cross-ticket reasoning is orchestrator-side, ADR-009).
- You are NOT writing `implementer-response.md` (that's wave-implementer's job during the disagreement protocol).
- You are NOT walking `plan-steps.json` (does not exist in this run).
