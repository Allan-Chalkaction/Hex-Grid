# end-of-wave-gates invocation procedure — orchestrated mode (per-wave, terminal)

**Used by:** `core/config/phases/orchestrated/w-finalize.md` Step 4 onwards.
**Agents invoked (selected from matrix):** `@code-reviewer`, `@security-auditor`, `@db-migration-reviewer`, `@performance-reviewer`, `@ui-review`, `@dependency-auditor`, `@e2e-test-writer` — the matrix-selectable gates from `core/skills/batch-gate/SKILL.md` Step 2. (`@accessibility-auditor` is invokable manually via `@accessibility-auditor` outside the orchestrated flow but is not in today's `/batch-gate` matrix; it does not auto-fire at end-of-wave. CR-003 iter-2: dropped from the procedural set to keep the header accurate.)
**Template substitutions:** `${slug}`, `${run_dir}`, `${wave_base_ref}`, `${session_id}`.

This file is NOT a per-agent prompt. It is the orchestrator-side procedure for the wave-terminal gate phase. The matrix-selection logic is composed against `/batch-gate`'s canonical matrix; the per-finding surface loop is composed against W3-T02's halt-and-resume protocol. Direct dispatch (NOT `/batch-gate` Skill invocation) is binding — historical rationale lived in V2-W4-T01's Phase 1 design proposal (now removed; see `docs/decisions/` for the active contract).

---

## Step 1 — Compute changed-files set

Compute the wave's full diff against the base ref captured at `w-setup`:

```bash
WAVE_BASE_REF=$(jq -r '.wave_base_ref' "${run_dir}/wave-manifest.json")
if [ -z "$WAVE_BASE_REF" ] || [ "$WAVE_BASE_REF" = "null" ]; then
  echo "wave-manifest.wave_base_ref is not set; cannot compute end-of-wave diff" >&2
  exit 2
fi
git diff --name-only "${WAVE_BASE_REF}..feature/wave-${slug}" > "${run_dir}/changed-files.txt"
```

**Why `${wave_base_ref}` and not `main`:** the wave branched off main at `w-setup`; main may have advanced since. The `wave_base_ref` is the captured ancestor SHA — using it produces the wave's own contribution, not a diff polluted by intervening main commits.

If `changed-files.txt` is empty, log "No changes between wave_base_ref and feature/wave-${slug}; skipping end-of-wave gates" to `${run_dir}/run-log.md` and advance `current_phase` to `done` immediately.

## Step 2 — Apply the matrix to compute the gate list

Apply the matrix at **`core/skills/batch-gate/SKILL.md` Step 2** unchanged, against `changed-files.txt`. The orchestrated mode does NOT inline a copy of the matrix — the SKILL is the single source of truth (drift between this template and the SKILL is a defect; see Constraints below).

The matrix as it stands at SKILL Step 2:

| Condition | Required gate |
|---|---|
| Always | `code-reviewer` |
| Any `.tsx` with visual output (JSX, not hooks/utils) | `+ ui-review` |
| Any file in `supabase/migrations/` | `+ db-migration-reviewer`, `+ security-auditor` |
| Any file in `supabase/functions/` | `+ security-auditor` |
| `package.json` was modified | `+ dependency-auditor` |
| Any file in `client/src/hooks/use-*.ts(x)` | `+ performance-reviewer` |
| 10+ files changed | `+ performance-reviewer` |
| Any `.tsx` with visual output AND `playwright.config.*` exists | `+ e2e-test-writer` (Wave 2) |
| `wave_protocol_version` in `{2, 3}` | `+ architect-review` (**Wave 1.5** — between Wave 1 and Wave 2; D5 / ADR-016 § Q-D6) |
| `wave_protocol_version == 3` | `+ spec-conformance` (**Wave 1**, parallel; against the integrated diff; ADR-026) `+ manual-review` (**matrix close**, criteria-gated; w-finalize Step 4d; ADR-026) |

The above table is a runtime cache of `core/skills/batch-gate/SKILL.md` Step 2 for reading convenience. **The SKILL is canonical.** If the SKILL changes, this cache is stale but does not bind — the orchestrator at execution time MUST consult the SKILL, not this cached copy.

The wave's `gate_recommendations` field is INFORMATIVE — it carries the planning-time recommendation. The matrix is AUTHORITATIVE — at execution time, the gates fire from what the diff says. If `gate_recommendations` ⊋ matrix output, log the delta as a planning-time-vs-execution-time discrepancy in `run-log.md` for retrospective; run gates per the matrix.

Dedup the gate list. Print to user:

> End-of-wave gate matrix selected: `<gate-list>` (from `<N>` changed files).

## Step 3 — (no cancel window in v1)

V1 ships without a cancel-window mechanism. Gates dispatch immediately at Step 4 with no preceding pause or interactive cancel.

**Decision history (V2-W4-T01 Phase 1, PATH-1 disposition):** the plan-literal `bash sleep 10` cancel mechanism does not actually achieve a cancel window — within a single orchestrator turn, user input is queued for processing at turn boundaries (not polled during tool calls), so CANCEL replies arrive too late to abort gate dispatch. Achieving a real cancel window requires a turn-yielding-with-timeout primitive (e.g., `ScheduleWakeup`-style) that is not generally available in claude-infra today. Rather than ship a misleading emit ("Reply CANCEL within 10s to skip" that the system structurally cannot honor), v1 ships without the feature. Cancel-window UX is a deferred follow-up (see `${run_dir}/follow-ups.md` if populated, or the build's standalone follow-ups list).

The standard Claude Code session-interrupt mechanism remains available during gate dispatch as an escape hatch.

If a future ticket adds the turn-yielding primitive, this Step 3 is the natural insertion point. The `^[Cc][Aa][Nn][Cc][Ee][Ll]\s*$` regex (whole-line, case-insensitive, optional trailing whitespace; substring matching forbidden) is documented here for forward compatibility.

## Step 4 — Dispatch gates directly

Compose the gate dispatch inline. Do NOT invoke `/batch-gate` via the Skill tool — the SKILL has hardcoded assumptions (`HHmm-BATCH-GATE/` folder, diff vs HEAD, `ungated_count` reset) that orchestrated-mode end-of-wave structurally cannot satisfy. The SKILL's matrix table at Step 2 IS the canonical reference (read at runtime; do NOT inline a copy of the matrix in this template). The orchestration is composed inline.

**Wave 1 (read-only gates), in sequence:**

For each gate `g` in `<gate-list>` ∩ `{code-reviewer, ui-review, security-auditor, db-migration-reviewer, dependency-auditor, performance-reviewer}`:

```
Agent(subagent_type=g, prompt="""
You are running the end-of-wave <g> gate for wave ${slug}.

Changed files (computed from ${WAVE_BASE_REF}..feature/wave-${slug}):
$(cat ${run_dir}/changed-files.txt)

Wave run dir: ${run_dir}
Findings output path: ${run_dir}/findings/end-of-wave/<g>.md

Review the changes. Write your findings to the output path using the standard
findings template (Severity / File / Rule / Evidence / Why-it-matters / Remediation).
End your file with the verdict line: VERDICT: APPROVE | REQUEST_CHANGES | NEEDS_DISCUSSION.
""")
```

Wait for each agent to complete before invoking the next (sequential, mirrors `/batch-gate` Step 3 Wave 1 pattern).

**After EACH gate completes, verify the findings file landed (A8 / F-017).** Per-ticket flows already do this (`t-validate.md` Step 4 / `t-review.md` Step 5); end-of-wave inherits the same discipline:

```bash
GATE_FILE="${run_dir}/findings/end-of-wave/<g>.md"
if [ ! -f "$GATE_FILE" ]; then
  # Re-invoke the gate ONCE with an explicit "write your findings to <path>" reminder.
  # Mirrors t-validate.md:222-230 / t-review.md:48-56 — the agent occasionally
  # produces findings as conversation output without persisting; F-017 was
  # observed in storage-fs-foundations w-finalize for db-migration-reviewer.
  Agent(subagent_type=<g>, prompt="""
  Re-invoking <g> end-of-wave gate. Your prior dispatch did not write the
  findings file. Write your full findings to ${run_dir}/findings/end-of-wave/<g>.md
  exactly per the prior dispatch's contract. End with VERDICT: <verdict>.
  """)
  if [ ! -f "$GATE_FILE" ]; then
    # Halt with canonical end-of-wave-blocker surface (mirrors w-finalize.md
    # Step 5 surface format). Do NOT continue Step 5's blocking-findings
    # parse with a missing gate file — that would silently skip the gate.
    echo "BLOCKED: gate <g> failed to produce findings file at ${GATE_FILE} after one re-invocation retry. F-017 class — agent's findings exist in conversation output but did not persist." >&2
    # Operator dispositions: re-invoke manually with explicit path enforcement,
    # or skip this gate (END) and document the gap in the wave's follow-ups.
    exit 2
  fi
fi
```

**Wave 1 (v3 addition) — wave-end spec-conformance:** if `wave_protocol_version == 3`, ALSO dispatch `@spec-conformance` against the integrated wave diff using the prompt body from `core/gate-prompts/wave-end-spec-conformance.md` (substitute `${slug}`, `${run_dir}`, `${wave_base_ref}`). It is a read-only Wave 1 gate; findings land in `${run_dir}/findings/end-of-wave/spec-conformance.md` with a per-ticket atom-coverage sub-section + `VERDICT: PASS | FAIL`. Under v1/v2 spec-conformance ran per-ticket at t-validate; ADR-026 moves it here. The same findings-file presence verification block applies.

**Wave 1.5 (architect-review, v2 + v3), runs after Wave 1 completes and before Wave 2:**

If `wave_protocol_version` is in `{2, 3}` (read from `${run_dir}/wave-manifest.json`), invoke `@architect-review` ONCE with the prompt body from `core/gate-prompts/wave-end-architect-review.md`. Architect-review consumes Wave 1's specialist findings as context, so it MUST run after Wave 1 completes (not in parallel with Wave 1). Findings land in `${run_dir}/findings/end-of-wave/architect-review.md` with `VERDICT: APPROVE | REQUEST_CHANGES`. (Under v3 the architect-review framework ADR-016 established still applies — ADR-026 extends it.)

The same Wave 1 findings-file presence verification block (re-invoke once on missing; halt with end-of-wave-blocker on second-attempt failure) applies.

v1 (legacy) waves SKIP Wave 1.5 entirely — `architect-review` is not in the v1 matrix.

**Matrix close (v3 only) — wave-end manual review:** after Wave 1.5 (and the structural check), `wave_protocol_version == 3` runs the single wave-level manual review, criteria-gated per ADR-018 (`wave_manual_review_required := any(tickets[i].manual_review_required)`; fires iff a wave-end finding carries `_criterion_match_ ∈ {crit-1, crit-2, crit-3}`, or any `crit-4` / `crit-5` regardless). Full handler: `w-finalize.md` Step 4d. Satisfied by PASS-THROUGH-SUMMARY when no criterion is met.

**Wave 2 (test-writing gates), runs after Wave 1.5 (v2) or Wave 1 (v1) completes:**

For each gate `g` in `<gate-list>` ∩ `{e2e-test-writer, qa-tester}`:

Same dispatch shape as Wave 1, but the agent writes test files in addition to findings. The test files land in the project's standard test directory (not in `${run_dir}`). The Wave 1 findings-file presence verification block above applies symmetrically to Wave 2.

**No `ungated_count` mutation.** The `/batch-gate` SKILL resets `ungated_count` in `_queue.json` (Step 5); orchestrated mode does NOT — the wave branch's commits are not "ungated work" in the sense `/batch-gate` tracks.

**Findings consolidation:** after all gates complete, parse each `${run_dir}/findings/end-of-wave/<g>.md` for blocking findings and feed the queue into Step 5. The presence-verification block above guarantees every gate-file exists before this consolidation runs (or a halt fired).

## Step 5 — Per-finding loop (blocking findings only)

For each gate's findings file at `${run_dir}/findings/end-of-wave/<g>.md`, parse findings with `Severity: BLOCKING` (or `Severity: Critical | High` per the SKILL's findings template) into a queue. Non-blocking findings are logged to `run-log.md` and NOT surfaced.

For each blocking finding (loop iteration):

### Step 5.1 — Identify the affected ticket(s) and source file

For each blocking finding, extract the `File:` field — call it `${affected_source_file}`. Map it to the owning ticket(s) via the manifest:

```bash
# Substrate root: core/ in claude-infra, .claude/ in a consumer project (ADR-031).
# This gate-prompt body is read directly (not injected), so it self-resolves the
# substrate path rather than relying on the inject-time rewrite in workflow-state-inject.sh.
SUBSTRATE=$([ -d .claude/scripts ] && echo .claude || echo core)
AFFECTED_TICKETS=$(python3 "$SUBSTRATE/scripts/wave-manifest.py" find-tickets-for-file \
    "${run_dir}/wave-manifest.json" "${affected_source_file}")
```

(V2-W4-T01 helper. Returns ticket keys whose `planned_files` contains the path, sorted ascending. Empty result triggers fallback A.)

**Fallback A (manifest miss):** `git log --follow --format=%H -- "${affected_source_file}"` and intersect with `tickets[].commit_sha`. Returns ticket keys whose commit_sha appears in the file's history on the wave branch.

**Fallback B (history miss):** if fallback A is also empty, the finding is **unattributed** — the file was modified on the wave branch but cannot be tied to any known ticket commit. Set `IS_UNATTRIBUTED=1`. Step 5.2 emits a modified menu without REVERT.

The variable `${findings_doc_path}` (= `${run_dir}/findings/end-of-wave/<g>.md`) is the gate's findings markdown — distinct from `${affected_source_file}` (the source file referenced in the finding's `File:` field). The two are not interchangeable; the helper consumes only `${affected_source_file}`.

### Step 5.2 — Emit per-finding surface (P-027 latest-wins, unattributed-aware)

Per the W3-T02 loop-body emission convention (P-027), emit ONE `${run_dir}/surface-prompt.md` write per loop iteration, OVERWRITING the previous. The `## Loop progress` section carries:

- **Already processed:** `<list of finding IDs already dispositioned, with REVERT/FOLLOW-UP/END>`
- **In-flight:** `<this finding's ID>`
- **Pending:** `<list of finding IDs not yet processed>`

Loop state is reconstructable from external files on a fresh-session resume:
- `${findings_doc_path}` enumerates all findings.
- `${run_dir}/surface-log.md` records dispositions of already-processed findings.
- `${run_dir}/surface-prompt.md` carries the in-flight finding's question.

**Surface format (attributed finding):**

> Gate `<g>` reported a BLOCKING finding `<finding-ID>` on file `<affected_source_file>`.
> Affected ticket(s): `<ticket-keys>` (commits `<SHA-list>`).
> Finding summary: `<finding-summary-from-${findings_doc_path}>`.
> Reply: `REVERT` (revert the affected commit(s) on the wave branch) / `FOLLOW-UP <target-wave-slug | standalone>` (add to a future wave or standalone follow-ups list) / `END` (acknowledge and continue).

**Surface format (unattributed finding — `IS_UNATTRIBUTED=1`):**

> Gate `<g>` reported a BLOCKING finding `<finding-ID>` on file `<affected_source_file>`.
> **Status: UNATTRIBUTED** — this file was not found in any ticket's `planned_files` and `git log --follow` did not produce a commit on this wave branch. The file was likely modified by an out-of-band edit (manual edit during the wave, or an amendment not captured in `actual_files_modified`). REVERT is unavailable because no specific commit can be identified.
> Finding summary: `<finding-summary-from-${findings_doc_path}>`.
> Reply: `FOLLOW-UP <target-wave-slug | standalone>` / `END`.

Emit canonical halt-and-resume per `core/config/phases/orchestrated/wave-resume-context.md` Section 5 producer-side ordering:

1. Compute `SURFACE_TYPE=end-of-wave-blocker` and the question/options/loop-progress.
2. Write `${run_dir}/surface-prompt.md`.
3. Print user-facing prose.
4. Emit fenced `wave-resume-context` block (per `w-finalize.md` lines 30-41 — already scaffolded by W3-T02).
5. END THE TURN.

### Step 5.3 — Disposition handlers (resume entry)

On resume, parse the user's reply for the in-flight finding:

**REVERT** (rejected if `IS_UNATTRIBUTED=1`; rejected if wave branch is pushed-and-not-ahead):

If `IS_UNATTRIBUTED=1`, the orchestrator MUST refuse REVERT and re-prompt:

> Finding `<ID>` is UNATTRIBUTED. REVERT is unavailable. Reply FOLLOW-UP or END.

**Pushed-and-not-ahead refuse (B.1 #12 belt-and-suspenders):** before invoking `git revert`, check whether the wave branch has an upstream and is not ahead:

```bash
UPSTREAM=$(git rev-parse --abbrev-ref @{u} 2>/dev/null || true)
if [ -n "$UPSTREAM" ]; then
  AHEAD=$(git log "${UPSTREAM}..HEAD" --oneline | wc -l | tr -d ' ')
  if [ "$AHEAD" = "0" ]; then
    echo "Refuse: wave branch '${slug}' is pushed and is not ahead of upstream ${UPSTREAM}." >&2
    echo "REVERT would rewrite shared history. Pushing during wave execution is forbidden by ADR-008." >&2
    # Re-prompt with REVERT removed from the menu.
    exit 2
  fi
fi
```

Otherwise, iterate `AFFECTED_TICKETS` (which holds ticket keys, one per line from `find-tickets-for-file`'s stdout). For each ticket key, look up its `commit_sha` from the manifest, refuse if absent or null, otherwise revert and persist:

```bash
# Substrate root: core/ here, .claude/ in a consumer project (ADR-031). Self-resolved
# because this gate-prompt body is read directly, not injected/rewritten.
SUBSTRATE=$([ -d .claude/scripts ] && echo .claude || echo core)
echo "$AFFECTED_TICKETS" | while IFS= read -r ticket_key; do
  [ -z "$ticket_key" ] && continue
  # Look up the ticket's commit_sha from the manifest.
  ticket_sha=$(jq -r --arg k "$ticket_key" \
    '.tickets[] | select(.key == $k) | .commit_sha // ""' \
    "${run_dir}/wave-manifest.json")
  if [ -z "$ticket_sha" ] || [ "$ticket_sha" = "null" ]; then
    echo "Refuse: ticket ${ticket_key} has no commit_sha (skipping; this should not happen for a ticket reaching end-of-wave gates)." >&2
    continue
  fi
  # Squash-merges are NON-merge commits — DO NOT use -m 1.
  git revert --no-edit "$ticket_sha"
  REVERT_SHA=$(git rev-parse HEAD)
  python3 "$SUBSTRATE/scripts/wave-manifest.py" update-ticket-status \
      "${run_dir}/wave-manifest.json" "${ticket_key}" reverted \
      --field reverted_in_commit="\"${REVERT_SHA}\""
done
```

CR-001 iter-2 fix: `AFFECTED_TICKETS` is the defined variable from Step 5.1 (holding ticket keys); the prior iter-1 draft mistakenly iterated an undefined `$AFFECTED_SHAS`. Multi-owner findings (multiple tickets owning the file) revert each owner's commit in turn; each `update-ticket-status` call uses the correct per-iteration `${ticket_key}`. Tickets without a `commit_sha` are skipped with a clean stderr message rather than crashing the loop — the case shouldn't occur in practice (a ticket without a commit cannot have a finding on its commit) but the defensive guard prevents an empty `git revert ""` invocation.

**Audit-trail invariant:** the original `commit_sha` is preserved on the ticket entry. The new `reverted_in_commit` field carries the revert SHA. Both fields coexist after revert; this is intentional (B.1 #6).

Append to `surface-log.md`: `<UTC timestamp>: REVERT finding <ID> from gate <g>; reverted commits <SHA-list> in <REVERT-SHA-list>.`

**FOLLOW-UP `<target>`:**

If `<target>` matches `^[a-z0-9][a-z0-9_-]*$` (a wave-slug shape; matches `WAVE_SLUG_RE` in `wave-manifest.py`):

- Resolve the target wave spec by glob (ADR-051: a wave spec lives in its epic folder, `docs/step-3-specs/<epic-slug>/waves/<wave-slug>/<wave-slug>.md`, not a flat `waves/` dir):
  ```bash
  TARGET_SPEC=$(ls docs/step-3-specs/*/waves/${target}/${target}.md 2>/dev/null)
  ```
  Validate exactly one match. If zero matches (or the target wave already built — its folder MOVED into the pipeline run, ADR-051 move-on-advance), re-prompt within the same loop iteration:
  > Target wave-slug `${target}` not found in `docs/step-3-specs/*/waves/`. Reply with an existing un-built wave-slug or `standalone`.

  Do NOT advance the loop iteration; emit a fresh Step 5.2 surface for the same finding. If more than one match, re-prompt asking the operator to disambiguate by epic (`<epic-slug>/<wave-slug>`).
- If exactly one: append the finding to `${TARGET_SPEC}` under a `## Follow-ups from prior waves` heading. **Idempotent on the heading literal** (mirrors V2-W3-T01 deferral-prompt augmentation): if the heading already exists, append the finding entry under it; otherwise, create the heading + first entry. Entry shape:

  ```markdown
  ### From wave ${slug}, finding ${finding-ID} (${gate})

  **File:** `${affected_source_file}`
  **Found at:** ${UTC-timestamp}
  **Severity:** BLOCKING (in source wave context)
  **Summary:** <finding-summary>
  **Suggested resolution:** <remediation-from-finding>
  ```

If `<target>` is `standalone`:

- Append to `${run_dir}/follow-ups.md` (create if absent) with the same structured entry shape, under a top-level `# Standalone follow-ups from wave ${slug}` heading.

Append to `surface-log.md`: `<UTC timestamp>: FOLLOW-UP finding <ID> → <target>.`

**END:**

Append to `surface-log.md`: `<UTC timestamp>: END finding <ID> (acknowledged, no action).`

After disposition: re-emit Step 5.2 surface for the next pending finding. Loop until pending queue is empty.

### Step 5.4 — Loop completion

When the pending queue is empty, log "All blocking findings dispositioned (`<N>` REVERT, `<M>` FOLLOW-UP, `<K>` END)" to `run-log.md`. Proceed to Step 6.

## Step 6 — Phase advancement

Advance `current_phase` to `done`. Mutate state file via the standard jq + tmp + mv pattern (mirrors `w-setup.md` Step 5):

```bash
STATE_FILE=".claude/agent-memory/active-runs/${session_id}-${slug}.json"
jq '.current_phase = "done"
    | .phase_history += [{phase: "done", entered_at: (now | todate)}]
    | .last_activity_at = (now | todate)' \
    "${STATE_FILE}" > "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "${STATE_FILE}"
```

Print final wave summary:

> Wave `${slug}` complete. End-of-wave gates: `<gate-list>`. Findings: `<N>` blocking (`<dispositions>`), `<M>` non-blocking (logged to run-log.md). Manual PR to main is the next step.

The wave-finalize phase does NOT auto-PR or auto-push. The user runs `git push` and opens the PR manually per ADR-008's branching contract.

---

## Constraints (binding)

1. **Matrix authority is `core/skills/batch-gate/SKILL.md` Step 2.** Do NOT inline a copy. The matrix table cached above in Step 2 is a reading convenience; the SKILL is canonical. Drift between this template and the SKILL is a defect.
2. **No `-m 1` on revert.** Squash-merges are non-merge commits. `git revert <sha>` is the correct command; `-m 1` fails on a non-merge.
3. **CANCEL semantics are documented for forward compatibility only** — v1 ships without a cancel window. The regex `^[Cc][Aa][Nn][Cc][Ee][Ll]\s*$` (whole-line, case-insensitive, optional trailing whitespace; substring matching forbidden) is the future-binding form once a turn-yielding-with-timeout primitive is available.
4. **Per-finding loop, NOT one-shot batch.** Mirrors W3-T02 deferral loop. Single-slot `surface-prompt.md` overwritten per iteration; loop state reconstructable from external files.
5. **Original `commit_sha` preserved on revert.** Add `reverted_in_commit` field; do NOT overwrite `commit_sha`. Schema addition documented in ADR-008 amendment log (2026-05-07).
6. **Once `done`, end-of-wave gates do NOT re-run.** The wave-finalize phase is terminal. Further gating is manual `/batch-gate`.
7. **Refuse REVERT on a pushed-and-not-ahead wave branch.** Pushing during wave execution is forbidden by ADR-008; the refuse-and-surface here is belt-and-suspenders.
8. **Direct gate dispatch, NOT `/batch-gate` Skill invocation.** The SKILL's hardcoded assumptions (`HHmm-BATCH-GATE/` folder, diff vs HEAD, `ungated_count` reset) are structurally incompatible with orchestrated-mode end-of-wave. The SKILL stays unchanged.
