# Bypass Mode — Orchestrator Authority

`/bypass` is one of the session entry modes (alongside `/nimble`, `/orchestrated`, `/chain`, `/roadmap`, `/planner`). It removes protocol gating and grants the orchestrator direct authority for tasks that don't warrant a structured run.

## Authorities granted

In bypass mode, the orchestrator MAY:

1. **Edit source files directly.** For small, obvious changes — a 3-line bug fix, a typo, a config tweak, a one-line condition update — the orchestrator edits files itself rather than dispatching an implementer agent. The `block-source-edits.sh` hook short-circuits when this session's `bypass-active-<session_id>.json` is present.

2. **Delegate to any single agent via `@<agent-name>`.** For tasks that warrant specialist attention (security review, performance audit, test generation, accessibility audit), the orchestrator invokes the named agent directly. Native Claude Code `@`-prefix syntax; the track-selection hook already lets `@`-prefixed prompts through.

The orchestrator picks between (1) and (2) per task. Heuristic: scope ≤ ~10 lines AND no domain-specialist context required → direct edit. Otherwise → delegate.

## Authorities NOT granted

In bypass mode, the orchestrator MUST NOT:

- Skip exploration or scope-clarification when the task is non-trivial. The investigation-first and multi-fix batch-isolation discipline (currently in `rules-nimble-routing.md`) still applies — it is universal good practice, not a Nimble-specific protocol.
- Edit `.claude/agent-memory/active-runs/*.json` directly — that path is gated by `block-active-runs-edits.sh`, which does NOT honor bypass.
- Bypass user authorization for shared-state operations: pushing, force operations, posting to external services, modifying production. Bypass is a working-tree authority, not a permission to act on the user's behalf in shared systems.
- Skip the user's stop-points or scope-clarification rules. `rules-stop-points.md` and `rules-orchestrator-behavior.md` Scope/Intent rules apply unchanged.

## Hook short-circuits that honor bypass

| Hook | How it honors bypass |
|---|---|
| `block-source-edits.sh` | Reads this session's `.claude/agent-memory/bypass-active-<session_id>.json`; exits 0 early if `enabled: true`. |
| `require-protocol.sh` | Same bypass short-circuit pattern — exits 0 when this session's flag is active, skipping all protocol checks. |
| `require-track-selection.sh` | Lets `@`-prefixed prompts through unconditionally; this session's flag also disables the gate for bare prompts. |

Each reader derives `<session_id>` from the `.session_id` it receives on stdin (which equals the orchestrator's `$CLAUDE_CODE_SESSION_ID`). When adding a new bypass authority, update this file's "Authorities granted" section AND add the corresponding hook short-circuit (mirror the session-scoped flag read pattern).

## Bypass state (session-scoped — ADR-052)

- File: `.claude/agent-memory/bypass-active-<session_id>.json` — **keyed to the session**, so concurrent sessions in one repo have independent bypass state and a new session's start cannot wipe a running session's flag (the bug ADR-052 fixes). The legacy repo-global `bypass-active.json` is **no longer honored** by any reader.
- Schema: `{"enabled": true, "activated_at": "<ISO timestamp>", "session_id": "<id>", "reason": "<first 100 chars of user message>"}`
- Lifecycle: written by `bypass/SKILL.md` (`/bypass on`) to the session-scoped path, removed by `/bypass off`. At SessionStart `session-cleanup.sh` clears **only the starting session's own** flag (fresh start), removes the legacy repo-global file, and GCs scoped flags older than 24h. Other sessions' flags are left intact. Per-session, not persistent.

## Authoring bypass-mode tickets

When authoring paste-into-fresh-session ticket prompts for bypass-mode work, use the canonical structure + autonomy framing in `core/skills/bypass-mode-prompt-authoring/SKILL.md`. The skill provides the standard 9-section template, the canonical standing-instructions language, and the four-tier halt-protocol framework (Tier 0/1/2/3 per ADR-014).
