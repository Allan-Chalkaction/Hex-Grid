---
description: "Infra upgrade — diagnose, then ACT. Runs /doctor, auto-fixes what's safe, and distributes the substrate to consumer repos via `setup.sh --refresh`. Halts on a broken substrate before distributing; never commits or pushes (operator-driven). Use after merging infra changes you want live everywhere. Triggers: '/upgrade', 'distribute infra', 'refresh consumers', 'push infra changes out', 'sync the substrate'."
---

# /upgrade — diagnose then act + distribute

The acting partner to `/doctor`. It runs the full diagnosis, then **does** the safely-actionable
work: fixes mechanical problems, applies CLAUDE.md drift corrections, and refreshes the substrate
into registered consumer repos so your infra changes go live everywhere — without you tracking which
repos need it.

**Boundaries (binding):** `/upgrade` MUST NOT `git commit`, `git push`, force-push, or open PRs —
those stay operator-driven (universal authorization rule). It also MUST NOT distribute a *broken*
substrate: if `/doctor`'s tests fail, it halts before touching any consumer.

Design + rationale: `docs/decisions/ADR-034-infra-doctor-upgrade.md`.

## Process

### Step 1 — Diagnose (run /doctor)

Run the `/doctor` skill in full (engine + CLAUDE.md drift). Capture the verdict and the action list.

### Step 2 — Gate: do not distribute a broken substrate

Read the engine's `DOCTOR VERDICT:` (re-run `bash core/scripts/infra-doctor.sh --strict` if needed —
`--strict` exits non-zero on any hard ISSUE).

- **Any failing synthetic test → HALT.** Report the failing test(s) and stop. Distributing a
  substrate whose own tests fail would propagate the breakage to every consumer. The operator fixes
  the test (or explicitly overrides) before `/upgrade` proceeds.
- Warnings (e.g. an unregistered hook) do **not** block distribution, but are surfaced for the
  operator — wiring a hook into `settings.json` is an operator decision (it changes enforcement
  behavior), so `/upgrade` recommends it rather than auto-wiring.

### Step 3 — Apply safe mechanical fixes

For each auto-fixable ISSUE the engine surfaced:
- **Non-executable hook** → `chmod +x core/hooks/<name>.sh`.
- Re-run `bash core/scripts/infra-doctor.sh --quiet` to confirm the fix cleared.

Do NOT auto-wire an unregistered hook or auto-fix anything that changes enforcement/behavior — surface
those for the operator with the exact recommended change. A **dead hook reference** (the canonical
settings template registers a hook whose `core/hooks/` file is gone) is likewise surface-only: it
edits enforcement wiring, so recommend the exact settings change rather than auto-editing.

### Step 4 — Apply CLAUDE.md drift corrections

For drift `/doctor` Step 2 found:
- **Safe corrections** (stale path, gone-script reference, an out-of-date decision-doc inventory row,
  a duplicated-rule section that should be a cross-reference) → edit `CLAUDE.md` directly.
- **Judgment calls** (a rule that genuinely changed meaning, a conflict needing a decision) → surface
  with a recommendation; do not guess.

### Step 5 — Distribute to consumer repos

Read `core/config/infra-consumers.json`. For each registered consumer the engine flagged as behind:

1. **Confirm the target list with the operator** before running `setup.sh` against other repos
   (it mutates files in those repos). Show the list + the exact commands.
2. For each confirmed consumer:
   ```bash
   ./setup.sh <consumer-path> --refresh
   ```
   Watch the output for `SKIP (local file exists)` lines — those paths have real (non-symlink) files
   that `--refresh` will NOT overwrite. Surface them: they are stale snapshots that must be removed
   for the symlink to land.
3. Validate each: `./setup.sh <consumer-path> --validate`.

If the registry is empty, report that and prompt the operator to populate it (paths of the repos to
keep in sync) — distribution can't proceed without it.

### Step 6 — Re-verify + report

Re-run `bash core/scripts/infra-doctor.sh`. Report:
- What was fixed (chmod, CLAUDE.md edits) and what was distributed (which consumers refreshed).
- The new verdict.
- Anything left for the operator (failing tests, hooks needing settings wiring, judgment-call drift).
- **Reminder:** `/upgrade` did not commit or push. If `core/` or `CLAUDE.md` changed, the operator
  commits/pushes; a consumer refresh creates symlinks in that repo (commit there if the consumer
  tracks `.claude/`).

## Scope

- Runs in the claude-infra repo. Never commits/pushes/PRs. Halts before distributing a substrate with
  failing tests. Confirms consumer targets before mutating other repos.
