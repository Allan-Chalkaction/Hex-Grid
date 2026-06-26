---
description: "Orchestrates merging multiple feature branches/worktrees back to a base branch — thin door over core/scripts/merge-orchestrate.py. Performs the human halt surfaces, the Wave-1 agent gate, and the post-merge MOVE. Halts on any conflict or red gate — never auto-resolves, never proceeds past red."
---

## Merge Orchestrator (thin door over `merge-orchestrate.py`)

This skill lands a set of feature branches/worktrees back on a base branch one at a time, re-running quality gates against the merged state between every merge. It halts on the first sign of trouble — never auto-resolves a conflict, never proceeds past a red gate.

**Architecture (ADR-071 Part 2):** the deterministic flow (scan → preflight → init → per-branch loop with rebase-if-behind, squash-merge, post-merge typecheck+test) is owned by `core/scripts/merge-orchestrate.py`. The script makes the invariants **structural** — it physically cannot push, force, `reset --hard`, or auto-resolve a conflict. This skill is the operator-facing wrapper: it invokes the script, performs the human halt messages (for likely-non-developer operators), dispatches the Wave-1 agent gate after the script emits `AGENT_GATE_PENDING`, and performs the wave-end ADR-066 §5e post-merge MOVE.

The critical mental model: **integration is a serial, supervised process.** Worktrees give parallel writing; this skill gives controlled landing.

---

## Invariants — read these first

The script enforces them structurally; this list is for the operator's mental model.

1. **NEVER `git push --force` / `--force-with-lease`.** (script: `_refuse_forbidden`)
2. **NEVER `git reset --hard`.** (script: refused; uses `git rebase --abort` to leave the tree clean)
3. **NEVER auto-resolve a merge or rebase conflict.** (script: rebase conflict → `--abort` + halt non-zero)
4. **NEVER proceed past a red post-merge gate.** (script: halt + structured payload; this skill surfaces operator options)
5. **NEVER invoke an implementer agent.** This skill is purely orchestration over read-only agents and `git`.
6. **Squash-merge is the default.** Fast-forward is `--strategy=ff`; merge-commit is not supported (v1 scope).
7. **State writes are atomic** (`tmp + os.replace`). Resumption (`--resume`) is a first-class feature.
8. **Never push to a remote.** The user runs `git push` themselves after reviewing the final report.
9. **≤6 branches per run.** (script: refused above this; rules-git.md guidance)

### Trust boundary — `.claude/project-paths.sh`

The script's post-merge gate (typecheck + tests) discovers commands via `.claude/project-paths.sh` (Tier 1), falling back to `package.json` scripts (Tier 2). **`project-paths.sh` is sourced and its `TYPECHECK_CMD` / `TEST_CMD` values are passed to `subprocess.run(..., shell=True)`** — both files therefore form an **operator-trusted** boundary. Do NOT run `/merge-orchestrator` against a freshly-cloned untrusted repository without first reading `.claude/project-paths.sh` (or, absent that file, the `scripts.typecheck` / `scripts.test` entries in `package.json`). The same trust requirement applies to `/post-merge-gate`, which uses the same three-tier discovery. (SA-002)

---

## Invocation forms

- `/merge-orchestrator` — interactive: scan worktrees with `git worktree list`, prompt the user to confirm the branch set.
- `/merge-orchestrator branch-a branch-b branch-c` — explicit branch list.
- `/merge-orchestrator --batch-name <slug> branch-a ...` — name the run folder. Default is `HHmm-merge<N>`.
- `/merge-orchestrator --resume` — re-read the most recent `MERGE` run folder, continue from `merge-state.json`.
- `/merge-orchestrator --strategy=ff|squash` — override the default (squash).
- `/merge-orchestrator --dry-run` — run the conflict scanner only, no merging. Equivalent to `merge-orchestrate.py scan`.
- `/merge-orchestrator --base=<ref>` — override the base branch (default `main`).

---

## Step 0: Resolve invocation

If `--resume`:
1. Find the latest `docs/step-5-pipeline/*/HHmm-MERGE-*/` folder (most recent by mtime).
2. `python3 core/scripts/merge-orchestrate.py status --run-dir <found>` to read its state.
3. If halted with pending branches, present a one-line summary ("Resuming MERGE run from <date> — <N> branches remaining: <list>. Proceed?") and wait for user confirmation.
4. On confirm, invoke `python3 core/scripts/merge-orchestrate.py resume --run-dir <found>` and process its output per **Step 4**.
5. If complete, report so and exit. Do not start a new run from `--resume`.

If interactive (no args):
1. Run `git worktree list --porcelain`. Parse out branch names.
2. Present them: "I see these worktrees: <list>. Which should I merge? (`all` / `<list>` / `cancel`)"
3. On confirmation, treat as the explicit branch list.

If explicit branch list:
1. The script's `init` step (Step 2) validates each branch resolves — there is no separate orchestrator-side validation.

## Step 1: Preflight + scan (delegated)

Run, in order, the script's read-only steps:

```bash
python3 core/scripts/merge-orchestrate.py preflight --base "$base" "$branch1" "$branch2" ...
python3 core/scripts/merge-orchestrate.py scan --base "$base" --run-dir "$run_dir" "$branch1" "$branch2" ...
```

- `preflight` exits non-zero on any hard failure (base unresolved, branch unresolved, working tree dirty). Surface the failures to the operator. **STOP** on non-zero. Do NOT auto-fix anything.
- `scan` writes `${run_dir}/conflict-scan.md` + `conflict-scan.json` and prints a final-line summary `SCAN: verdict=CLEAN|CAUTION|CONFLICTS red=N orange=N yellow=N green=N order=<comma-separated>`. **Read the markdown to the operator.**

If `--dry-run`: present the scan summary and exit. Do not proceed to merging.

If the scan verdict is `CONFLICTS`, require explicit user acknowledgment — accept "I read the conflicts, proceed" or equivalent. Do not accept a bare "go" / "yes" when reds are present.

## Step 2: Init the run (delegated)

```bash
python3 core/scripts/merge-orchestrate.py init --base "$base" --run-dir "$run_dir" --strategy "$strategy" "$branch1" ...
```

This creates `${run_dir}/merge-state.json` atomically (state file schema in the script's module docstring) and writes `${run_dir}/prompt.md`. The script refuses to clobber an existing state file unless `--force`.

## Step 3: Confirm or override the merge order

Display the recommended order from `conflict-scan.md` (already written by the script in Step 1).

> Confirm or override the order:
> - `go` / `proceed` — use the recommended order
> - `<branch-1> <branch-2> ...` — re-invoke `init --force` with this exact order
> - `skip <branch>` — re-invoke `init --force` without this branch
> - `cancel` — abort the run

(Override / skip both re-run `init --force` with a different branch list so the script's state matches.)

## Step 4: Per-branch loop (delegated, agent-gate orchestrated)

Repeat until the script reports `status=complete`:

```bash
python3 core/scripts/merge-orchestrate.py merge-next --run-dir "$run_dir"
```

Interpret the script's final line:

- **`status=clean branch=<X> merge_sha=<SHA>`** + an `AGENT_GATE_PENDING branch=<X> merge_sha=<SHA>` line above it:
  - The script has landed the branch cleanly and run typecheck + tests against the merged state. Both green.
  - The orchestrator now invokes the Wave-1 gate AGENTS against the merged state — see **Step 4a** below.
  - After the gate completes green, proceed to **Step 5 (post-merge MOVE)** for this branch, then loop.
  - If the agent gate returns RED, halt with the same operator options as the script's `post_merge_gate_red` halt (revert / fix-forward / abort). See **Step 4c**.

- **`status=skipped branch=<X> (no diff vs base)`**: the branch had an empty diff. Note in the run log; loop to the next branch (the script will pick it up).

- **`status=halted reason=rebase_conflict branch=<X>`** + a `HALT-PAYLOAD: {...}` JSON line:
  - The script has aborted the rebase (tree left CLEAN), recorded `conflict_files` to state, and exited non-zero.
  - Perform **Step 4b — rebase-conflict surface** below.

- **`status=halted reason=post_merge_gate_red branch=<X>`**:
  - The script's typecheck or tests failed against the merged state. The branch IS merged (sha recorded); the gate failed.
  - Perform **Step 4c — red gate surface** below.

- **`status=complete`**: every branch terminal. Proceed to **Step 6: Final report**.

### Step 4a — Wave-1 agent gate after AGENT_GATE_PENDING

The script handles typecheck + tests. **The agent gate is the orchestrator's job** (the script does not dispatch agents — ADR-039 contract 2).

Invoke `/post-merge-gate` Step 4 directly (the gate matrix selection + Wave-1 agent fan-out), passing:

- `merged_branch`: the branch from the `AGENT_GATE_PENDING` line.
- `run_dir`: `${run_dir}/per-branch/<branch>/`.

`/post-merge-gate` writes per-agent findings to `${run_dir}/per-branch/<branch>/post-merge-gate-findings/<agent>.md` and emits a final `VERDICT: GREEN | RED`.

- **GREEN** → proceed to Step 5 (post-merge MOVE), then continue the per-branch loop.
- **RED** → perform Step 4c (red gate surface).

### Step 4b — Rebase-conflict surface (operator-friendly halt)

The HALT-PAYLOAD JSON gives you `branch`, `conflict_files`, and `run_dir`. Surface to the operator:

> **Halted on `<branch>`: rebase conflict.**
>
> `<branch>` has changes that overlap with `<base>`'s recent changes. Git can't decide which side to keep without a human eye on it.
>
> **The working tree is clean** — I aborted the rebase to leave nothing half-done. No commits landed.
>
> Conflicting files:
> - `<file1>`
> - `<file2>`
>
> How would you like to proceed?
>
> **(a) Resolve outside this session.** I'll wait. Open the files, do the rebase manually (or in your editor), commit. Then re-run `/merge-orchestrator --resume` and I'll pick up from here.
>
> **(b) Skip this branch.** Mark it `skipped` and continue with the next. You'd come back to it later.
>
> **(c) Abort this run.** Stop entirely. Branches already merged stay merged.

Wait for the user. Do not proceed.

If the user chooses (b): write `merge-state.json` to set this branch's `status: "skipped"` (atomic — use Python or `jq + mv`, NEVER hand-edit), then loop.

If (c): write `merge-state.json` `halted: true`, `halt_reason: "aborted_by_user"`. Stop.

### Step 4c — Red post-merge-gate surface

Two sub-cases: the script's typecheck/test gate is red, OR the orchestrator's agent gate (Step 4a) is red. Same operator surface:

> **Halted on `<branch>`: post-merge gate is RED.**
>
> The merge succeeded (commit `<sha>` is on `<base>`) but the merged state failed quality checks:
> - [list of failures: typecheck / tests / per-agent verdicts]
>
> Full report: `${run_dir}/per-branch/<branch>/post-merge-gate-report.md`
>
> How would you like to proceed?
>
> **(a) Revert this merge.** I'll run `git revert -m 1 <merge_sha>` (creating a new commit that undoes this one). The branch stays unmerged. We continue with the next branch. *(Constraint: only safe if no other commits exist after this merge. If you've added commits since, you'll need to fix forward instead.)*
>
> **(b) Fix forward.** Pause this run. You fix the issue in a separate session, commit. Then re-run `/merge-orchestrator --resume` and I'll re-run the gate to verify before continuing.
>
> **(c) Abort this run.** Stop. Branches already merged stay merged. This one is left as merged-but-failing on `<base>` — you'll need to revert or fix manually before pushing.

Wait for the user.

**Special case for revert (option (a)):** only attempt if `git rev-list HEAD~1..HEAD` matches the recorded merge commit (no commits since). Otherwise refuse and force (b) or (c). **NEVER use `git reset --hard` to undo a merge — always `git revert`.**

## Step 5: Post-merge MOVE — pipeline → done (ADR-066 §5e)

Fires AFTER Step 4a returned GREEN for the just-merged branch. Under the same operator-authorized merge action — no new authority, no new hook, no orchestrator-autonomous moves on merges this skill didn't perform.

**Applicability:** the just-merged branch is a WAVE branch named `feature/wave-<slug>`. Any other branch (`fix/...`, `chore/...`, `docs/...`, etc.) is NOT subject to the MOVE — skip Step 5 and continue.

**The move:** locate the source run folder and `git mv` it whole to `step-6-done/`:

```bash
slug="${branch#feature/wave-}"
src=$(find docs/step-5-pipeline -maxdepth 2 -type d -name "*-WAVE-${slug}" | head -1)

if [ -z "$src" ] || [ ! -d "$src" ]; then
  echo "post-merge MOVE: source run folder missing for wave-${slug} — logged, continuing." \
    >> "${merge_run_dir}/merge-state-notes.md"
  # ADR-066 §2 "Tolerance": missing-source is logged, NOT blocking.
else
  date_dir=$(basename "$(dirname "$src")")
  run_name=$(basename "$src")
  dst="docs/step-6-done/${date_dir}/${run_name}"
  mkdir -p "$(dirname "$dst")"
  git mv "$src" "$dst"
  git commit -m "chore(done): MOVE ${run_name} to docs/step-6-done/ post-merge (ADR-066 §2)"
fi
```

Update `merge-state.json` for this branch — append `post_merge_move: "moved"` or `"absent-tolerated"` to its branch entry (atomic write via the script's own state-mutation flows; if hand-mutating, use Python + `tmp + os.replace`).

**MAY delegate to the close-out verb:** this MOVE is the same operation `core/scripts/closeout-run.py` performs (ADR-087 D2.3), so Step 5e MAY call `python3 core/scripts/closeout-run.py <src_run_folder> --skip-scope-check` to do the `git mv` + `run-log` close line + waiting-on-you render, then commit the result itself. The contract above is unchanged — applicability (WAVE branch only), missing-source tolerance, and the operator-authorized merge action all still bind; closeout-run.py is just the shared mover. **Pass `--skip-scope-check`:** Step 5e is a *post-merge* housekeeping MOVE — the wave already shipped to `main`, so the ADR-103 W3 OUT-bookend scope gate (which is for the *building* run's own close-out, holding a wrap that left scope on the floor) does not apply and must not hold the post-merge move.

**Forward-only:** backfill of historical merged runs is out of scope (ADR-066 §2 "starts empty and accumulates forward").

## Step 6: Final report

After every branch reaches a terminal status, write `${run_dir}/final-report.md`:

```markdown
# Merge Orchestrator: Final Report

**Run:** <batch-name>
**Date:** YYYY-MM-DD HHmm UTC → HHmm UTC (duration)
**Base:** <base>
**Strategy:** squash
**Status:** COMPLETE | HALTED | ABORTED

## Outcomes

| Branch | Status | Merge SHA | Post-gate | Notes |
|--------|--------|-----------|-----------|-------|
| feature/foo | done | abc1234 | green | — |
| feature/bar | reverted | def5678 | red (typecheck) | reverted by user |
| feature/baz | blocked | — | — | rebase conflict; user chose to resume later |

## What landed on `<base>`

- [list of merge SHAs that survived the run]

## What did NOT land

- [skipped, blocked, or reverted branches with one-line reason each]

## Recommended next steps

- If complete and clean: review the diff (`git log <base> ^origin/<base>`) and push when ready (`git push origin <base>`). DO NOT auto-push.
- If branches blocked: list each with `${run_dir}/per-branch/<branch>/`. After resolving, re-invoke with `--resume`.
- If reverts happened: open a follow-up to fix-forward those branches.
```

Display a one-paragraph summary in the conversation. Reference the report path. Do not push.

## Resumption semantics

`--resume` re-enters the script's loop. The script honors:

- Branches with `status: "done"` — skipped (already merged).
- Branches with `status: "skipped"` or `"reverted"` — terminal, skipped.
- Branches with `status: "blocked"` — re-attempted starting at rebase.
- Branches with `status: "pending"` — processed in order.

The script clears its `halted` flag on `resume` and tries to make progress. If the underlying problem is unresolved, it halts again with the same payload.

## Halt-message style guide (preserve this — the operator is likely a non-developer)

Every halt message must:

1. **Lead with what happened in plain English.** "A conflict means two branches both changed the same lines in opposite ways."
2. **Show the file:line and a 1–8 line excerpt of the actual conflict** when surfaceable from the script's HALT-PAYLOAD or the per-branch report.
3. **Offer options as labeled choices**, never as "fix it / try again."
4. **Avoid jargon-only error messages.** "Rebase conflict" is fine if you explain it; bare "rebase failed" is not.
5. **Never imply the orchestrator can auto-resolve a conflict if asked nicely.** The constraint is structural — the wrong choice silently ships wrong code.

## What this skill does NOT do

- Auto-resolve any conflict (textual or otherwise) — the script refuses structurally.
- Push anything to any remote — the script refuses structurally.
- Revert without explicit user confirmation.
- `git reset --hard` under any circumstance — the script refuses structurally.
- Invoke implementer agents.
- Modify feature branches' source files (rebase happens in-script; conflicts cause `--abort`).
- Close PRs, comment on PRs, or interact with GitHub.
- Increment `ungated_count` in any queue manifest.

## Cross-references

- **Script:** `core/scripts/merge-orchestrate.py` (the deterministic engine — read its module docstring for the full state schema + subcommand contracts).
- **ADR-071** (`docs/decisions/ADR-071-concurrency-reconvergence-model.md`) — Part 2 doctrine this implements.
- **`/post-merge-gate`** — invoked in Step 4a for the Wave-1 agent gate.
- **`@merge-conflict-scanner`** — scoped to the semantic/coherence read; textual detection moved into `merge-orchestrate.py scan` (`git merge-tree`). Invoke the agent only when the operator asks "do these merge cleanly but COHERENTLY?"
- **`rules-git.md`** — Merge Orchestration invariants section; references ADR-071.
- **ADR-066 §2 / §5e** — post-merge MOVE contract.

## Context Management

- Don't re-read source files in the orchestrator; let `merge-orchestrate.py` and `/post-merge-gate` do their reading.
- After each branch's outcome, summarize to a one-line entry in the conversation; detail goes in `${run_dir}/per-branch/<branch>/`.
- Hard recommendation: more than **6 branches in one run** is too many. The script refuses above 6 (rules-git).
- If context approaches 60% mid-run, write a checkpoint note in `${run_dir}/checkpoint.md` and offer to resume in a fresh session via `--resume`.
