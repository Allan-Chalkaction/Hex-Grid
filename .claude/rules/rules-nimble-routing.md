# Nimble Track Routing

**This file is symlinked into projects via setup.sh and overrides any nimble routing table in the project's own CLAUDE.md.**

Post mode-aware refactor, the nimble track collapses to a single full-stack implementer with no auto-routed quality gates. Universal implementation discipline (Multi-Fix Batch Isolation, Investigation-First Debugging) lives in `rules-implementation-discipline.md`.

## Nimble Routing Table

| Work type | Execution |
|-----------|-----------|
| Implementation work — UI, backend, migration, cross-cutting bug fix, or any change that touches source files | `implementer` (single full-stack agent, dispatched once with `isolation: "worktree"` by the nimble engine script, then a staleness-guarded integrate — ADR-046) |
| Docs, config, investigation, agent/skill/rule definitions | Orchestrator directly (no implementer dispatch) |

**Rule:** if a nimble run requires implementation work, the nimble engine (`core/scripts/workflows/nimble.js`, ADR-039) dispatches one `implementer` agent in a worktree and integrates the result. Docs, config, and infrastructure edits stay with the orchestrator.

**Disposition default (ADR-105).** Nimble routes through the **same** shared consolidated surface as `/orchestrated`, so the **default autonomous disposition** binds here identically: a batch-gate finding is a **decision the orchestrator makes** (APPLY → remediation / DEFER → log / DISMISS → note / load-bearing fork → best-judgment call + ADR if warranted), logged in `autonomous-decisions-log.md` — **not** a halt. The only nimble halt is an **execution-class block** (implementer-blocked / harness failure). The binding contract is single-sourced in `rules-orchestrated-mode.md` §§ "Consolidated gate surface → disposition" + "Decision log" — it is not re-authored here.

## Quality gates — manual only

Auto-routing of quality gates from the nimble flow is **removed**. Gates remain available manually:

- `/batch-gate` — run a configured gate sequence after one or more nimble runs.
- `@<agent-name>` — invoke any single agent on demand (e.g. `@code-reviewer review src/auth.ts`, `@security-auditor`, `@accessibility-auditor`, `@db-migration-reviewer`, `@dependency-auditor`, `@performance-reviewer`, `@ui-review`, `@e2e-test-writer`).

The track-selection hook lets `@`-prefixed prompts through unconditionally; the protocol gate hook (`require-protocol.sh`) honors bypass mode and the active-run state for protocol enforcement.

If a contextual gate would have run automatically pre-refactor (e.g. ui-review on UI work, security-auditor on migrations), the orchestrator MAY recommend it after the run completes — but does not dispatch it without the user's direction.
