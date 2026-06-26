---
paths:
  - "**"
---

# Git Convention Rules

## Branch Naming
- `feature/` — new features (e.g., `feature/user-profiles`)
- `fix/` — bug fixes (e.g., `fix/login-redirect`)
- `chore/` — maintenance tasks (e.g., `chore/update-deps`)
- `docs/` — documentation only (e.g., `docs/api-reference`)
- `refactor/` — code restructuring (e.g., `refactor/auth-flow`)
- Use kebab-case after the prefix
- NEVER commit directly to `main` or `master`

## Commit Message Format (Conventional Commits)
```
type(scope): description

[optional body]

[optional footer(s)]
```

### Types
- `feat` — new feature (triggers minor version bump)
- `fix` — bug fix (triggers patch version bump)
- `docs` — documentation only
- `style` — formatting, no code change
- `refactor` — code change that neither fixes nor adds
- `perf` — performance improvement
- `test` — adding or updating tests
- `chore` — build process, tooling, dependencies
- `ci` — CI/CD changes

### Scope
Optional, in parentheses: `feat(auth): add OAuth login`
Use component/feature name: `auth`, `dashboard`, `api`, `db`, `ui`

### Description
- Lowercase first letter
- No period at end
- Imperative mood: "add" not "added" or "adds"
- Max 72 characters

### Breaking Changes
- Add `!` after type: `feat(api)!: change response format`
- Or add `BREAKING CHANGE:` footer

## PR Requirements
- Title follows commit format: `feat(auth): add OAuth login`
- Description includes: what changed, why, how to test
- Link related issues: `Closes #123`
- Squash merge to main (single clean commit)

## NEVER
- Never force push (`git push --force`) — use `--force-with-lease` if absolutely necessary
- Never commit directly to main
- Never commit `.env` files, secrets, or credentials
- Never commit `node_modules/`

## Merge Orchestration

When landing multiple feature branches (or worktrees) back to the base branch, use `/merge-orchestrator`. **The invariants below are made STRUCTURAL by `core/scripts/merge-orchestrate.py` (ADR-071 Part 2)** — the script physically cannot push, force, `reset --hard`, or auto-resolve a conflict. They apply to any multi-branch integration whether the orchestrator is invoked or the work is done by hand.

- **Default merge strategy is squash.** One clean commit per feature on `main`. Fast-forward is opt-in (`--strategy=ff`).
- **Never auto-resolve a merge or rebase conflict, even if it looks trivial.** Halt and ask. The wrong choice silently ships wrong behavior. *(Script: `_refuse_forbidden` + `git rebase --abort` on conflict → tree left clean → halt non-zero with structured payload.)*
- **Never proceed past a red post-merge gate.** Either revert (`git revert -m 1 <merge_sha>`) or stop and fix forward. *(Script: branch stays merged with `post_gate_verdict: "red"`; revert is an operator choice the skill surfaces — script never auto-reverts.)*
- **Never `git reset --hard`** to undo a merge — always `git revert`. Reset is destructive and silent. *(Script: `_refuse_forbidden` rejects `reset --hard`; uses `merge --abort` / `rebase --abort` for cleanup.)*
- **Never push during a merge run.** The user reviews the final report and runs `git push` themselves. *(Script: `_refuse_forbidden` rejects any `git push`.)*
- **Rebase before merging when the branch is behind base.** If the rebase has conflicts, the user resolves them; the orchestrator aborts the rebase and waits. *(Script: `merge-next` rebases-if-behind, aborts on conflict, halts.)*
- **Run `/post-merge-gate` after every merge.** Catches semantic conflicts that merged textually-cleanly. *(Script: runs typecheck+tests against the merged state automatically; emits `AGENT_GATE_PENDING` for the orchestrator to dispatch the Wave-1 agent gate.)*
- **Don't batch more than ~6 branches per merge run.** Above that, split into separate runs. *(Script: refuses >6 branches structurally.)*

The corresponding tooling:
- `core/scripts/merge-orchestrate.py` — deterministic engine (scan/preflight/init/merge-next/status/resume); the structural invariant enforcer (ADR-071 Part 2).
- `/merge-orchestrator` — thin operator-facing door over the script: human halt surfaces, Wave-1 agent gate dispatch on `AGENT_GATE_PENDING`, ADR-066 §5e post-merge MOVE.
- `@merge-conflict-scanner` — semantic/coherence read ("do these merge cleanly but COHERENTLY?"). Textual detection moved into `merge-orchestrate.py scan`; the agent is now scoped to the narrative semantic analysis only.
- `/post-merge-gate` — re-runs typecheck, tests, and Wave 1 gate agents against the merged state.

## Wave branch hygiene

When the orchestrator pushes a wave branch (per the per-ticket backup pattern) or the operator opens a wave→main PR (operator-only at wave-end):

### Verify-remote-before-PR

Before invoking `gh pr create` for a wave→main PR, verify the wave branch exists on origin:

```bash
if [ -z "$(git ls-remote --heads origin "feature/wave-${slug}")" ]; then
  echo "ERROR: wave branch feature/wave-${slug} not on origin." >&2
  echo "Push first: git push -u origin feature/wave-${slug}" >&2
  exit 1
fi
```

This rule emerged from a real failure mode where `gh pr create` failed silently (or with a confusing error) because the wave branch was local-only after a multi-session run.

### Per-ticket push pattern

After each successful per-ticket commit on the wave branch (under the engine the `integrate` step merges each ticket's worktree commit by SHA — ADR-040; the v1 `t-commit` squash-merge is retired), the orchestrator pushes the wave branch:

```bash
git push origin "feature/wave-${slug}"
```

This is push-without-force; never `--force-with-lease` in this path. Failures surface — they typically indicate divergence (someone pushed to the wave branch from another session, which is a real problem worth halting on).

### Wave branch deletion

After wave→main merge:
- **Post-merge MOVE** (ADR-066 §2): `/merge-orchestrator` Step 5e performs `git mv docs/step-5-pipeline/<date>/<HHmm>-WAVE-<slug>/ docs/step-6-done/<date>/<HHmm>-WAVE-<slug>/` under the same operator-authorized merge action — no new authority, no new hook. Missing-source tolerance: a missing run folder logs a warning and continues; the merge to main is not blocked. Forward-only: backfill of historical merged runs is out of scope. See `core/skills/merge-orchestrator/SKILL.md` Step 5e and `docs/step-6-done/README.md` for the full contract.
- Delete locally: `git branch -D feature/wave-${slug}`.
- Delete remote: `git push origin --delete feature/wave-${slug}`.

Do NOT delete the wave branch before main merge confirms — a failed PR or revert needs the wave branch intact.

### Cross-reference

For the full build flow (per-ticket → wave-end → main PR), see `CLAUDE.md` "Build Flow Conventions".
