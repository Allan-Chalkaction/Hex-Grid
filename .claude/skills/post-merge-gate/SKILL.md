---
description: "After merging a branch into main locally, re-run quality gates against the merged state. Catches semantic conflicts that textual merge succeeded against. Read-only verification — never modifies code."
---

## Post-Merge Gate

After a feature branch has been merged into the base branch (locally), this skill re-runs typecheck, tests, and the read-only quality gate agents against the **merged state**. Its job is to catch the failure mode where two branches each pass their own gates and merge cleanly textually, but together break the codebase.

### When to use it

- **Automatically:** the `/merge-orchestrator` skill calls this after every successful merge.
- **Manually:** after you hand-merge a branch and want to verify nothing semantically broke before pushing.
- **NOT for pre-merge gating.** Use `/batch-gate` for that.

### Inputs

- `merged_branch` — the name of the branch that was just merged (string, required for findings labeling)
- `run_dir` — the run folder to write findings into. If invoked from `/merge-orchestrator`, the orchestrator passes its per-branch run dir (`{merge_run_dir}/per-branch/{branch}/`). If invoked manually, default to `docs/step-5-pipeline/YYYY-MM-DD/HHmm-AUDIT-post-merge-gate/`.

## Step 0: Sanity preconditions

Before doing anything else, verify:

1. **Working tree is clean.** `git status --porcelain` must produce empty output. If not, STOP. Report: "Working tree is dirty. Post-merge gate runs against the committed state of the base branch. Please commit or stash, then re-run."
2. **HEAD is on the base branch.** Read `rules-git.md` to confirm the project's base (default `main`). Run `git symbolic-ref --short HEAD`. If it doesn't match the base, STOP. Report: "HEAD is on `<branch>`, not `<base>`. Post-merge gate runs against the base branch with the merge already landed. Switch to `<base>` first."
3. **A recent merge commit exists.** `git log -1 --format='%s'` should show a merge or squash-merge of `merged_branch`. If it doesn't, warn but continue: "Most recent commit doesn't reference `<merged_branch>`. Continuing anyway, but verify the merge actually landed."

If any of (1) or (2) fail, do NOT attempt to fix. Stop and surface the issue.

## Step 1: Resolve project commands

Three-tier fallback. Try in order; first success wins:

1. **`.claude/project-paths.sh`** — if it exists, source it. Read `TYPECHECK_CMD`, `TEST_CMD`, `LINT_CMD`. If any are set (non-empty), use them.
2. **Project's `CLAUDE.md`** — if it has a "Build & Test Commands" or "Project Commands" section, parse the command lines.
3. **Auto-detect:**
   - `package.json` with a `typecheck` script → `npm run typecheck`. With `test` script → `npm test`. With `lint` → `npm run lint`.
   - `Makefile` with `typecheck`/`test`/`lint` targets → `make <target>`
   - `go.mod` present → `go vet ./...` and `go test ./...`
   - `pyproject.toml` or `setup.py` → `pytest` (if available), `mypy .` (if configured)

For any command that ends up unset after all three tiers, log "skipping {step} — no command configured" and continue. Do NOT fail the gate solely because a command isn't configured.

If nothing at all could be resolved (no typecheck, no test, no lint), proceed to Step 4 directly with a noted warning in the report: "Project has no detectable typecheck/test commands. Gate is reduced to code-reviewer only."

## Step 2: Determine review scope

Get the file list that the merge introduced into the base branch:

```bash
git diff --name-only HEAD~1..HEAD
```

(For squash-merges this is the merge commit itself; for merge commits use `HEAD^1..HEAD^2` if needed.)

Apply the same gate matrix as `/batch-gate` Step 2 — see `core/skills/batch-gate/SKILL.md` for the table. The matrix maps file patterns to required Wave 1 gates:

- Always: `code-reviewer`
- Visual `.tsx` (JSX, not hooks/utils): `+ ui-review`
- `supabase/migrations/`: `+ db-migration-reviewer`, `+ security-auditor`
- `supabase/functions/`: `+ security-auditor`
- `package.json` modified: `+ dependency-auditor`
- `client/src/hooks/use-*.ts(x)`: `+ performance-reviewer`
- 10+ files changed: `+ performance-reviewer`

Display the gate set and why.

**Wave 2 (test-writers) is intentionally skipped.** Post-merge is not the right moment to be writing new tests. If test gaps exist, the user can run `/batch-gate` after to add them.

## Step 3: Run typecheck and tests first

These are cheap, decisive signals. A red typecheck makes every gate's review noisy.

1. Run `TYPECHECK_CMD`. Capture exit code, stdout, stderr.
2. Run `TEST_CMD`. Capture exit code, stdout, stderr.
3. Run `LINT_CMD` if set. Capture exit code, stdout, stderr.

If typecheck OR tests fail (non-zero exit):
- STOP. Do NOT run agent gates.
- Write `{run_dir}/post-merge-gate-report.md` with the failure (command, exit code, last 50 lines of output).
- Output `VERDICT: RED` and report which step failed.

If lint fails, that's not blocking on its own — record it and continue.

## Step 4: Run Wave 1 gates

For each selected gate, invoke via the Agent tool. The agent prompt should include:

- The merged branch name
- The list of files in the merge (from Step 2)
- An explicit framing: "This is a post-merge review. The branch `<merged_branch>` was just merged into `<base>`. Review the merged state on `<base>`, not the source branch."

Run sequentially (Wave 1 only), each writing findings to `{run_dir}/post-merge-gate-findings/<agent-name>.md` using the `/batch-gate` Findings Template (do not re-implement; reuse).

After each gate, display: `{agent-name}: {VERDICT}`

If a gate returns FAIL or REQUEST_CHANGES with blocking findings: do not halt the gate sequence — collect all findings before stopping. (Same pattern as `/batch-gate`.)

## Step 5: Aggregate verdict

Compile a final report at `{run_dir}/post-merge-gate-report.md`:

```markdown
# Post-Merge Gate Report

**Merged branch:** <merged_branch>
**Base branch:** <base>
**Merge commit:** <SHA>
**Date:** YYYY-MM-DD HHmm UTC

## Pipeline checks

| Check | Command | Result |
|-------|---------|--------|
| Typecheck | `<cmd>` | ✅ pass / ❌ fail / ⚠ skipped |
| Tests | `<cmd>` | ✅ pass / ❌ fail / ⚠ skipped |
| Lint | `<cmd>` | ✅ pass / ⚠ warn / ❌ fail / ⚠ skipped |

## Quality gates

| Agent | Verdict | Blocking findings |
|-------|---------|---------------------|
| code-reviewer | APPROVE / REQUEST_CHANGES | 0 / N |
| (others) | ... | ... |

## Findings

(For each agent that reported issues, link to its findings file under `{run_dir}/post-merge-gate-findings/<agent>.md`.)

## Verdict

GREEN | RED

(One line of explanation.)
```

**GREEN** = typecheck pass + tests pass + every gate APPROVE/PASS.
**RED** = anything else.

If RED, list the failing layers in order — typecheck first, then tests, then per-gate failures — so the orchestrator (or human) can decide what to do.

## Step 6: Output

Last line of your output:

```
VERDICT: GREEN
```
or
```
VERDICT: RED
```

If RED, the next line should summarize: `Failed: typecheck | tests | <gate-name>(s)`.

## What this skill does NOT do

- Modify code. Ever.
- Commit or push.
- Revert the merge. (The orchestrator decides revert vs. fix-forward; this skill only reports.)
- Run Wave 2 test writers.
- Update the project's `ungated_count`. Post-merge gating is a separate event from nimble debt accumulation.
- Auto-resolve anything.

## Context Management

- Do NOT read source files yourself. Each gate agent reads what it needs.
- Keep your own output to verdicts and the report's structured fields. No analysis prose in the conversation.
- This skill should complete in one pass. If context is a concern, run fewer gates by tightening the file scope in Step 2.
