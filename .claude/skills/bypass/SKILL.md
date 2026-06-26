---
name: bypass
description: Talk to the orchestrator without starting a run — disables protocol gating so you can chat, ask questions, or invoke single agents. A first-class entry mode alongside /nimble, /orchestrated, /chain, /roadmap, /planner.
user_invocable: true
---

# Bypass Mode

`/bypass` is the "give the orchestrator direct authority" entry mode. It tells the system you don't want a structured run — no state machine, no plan steps, no enforced agent sequence. You're talking to the orchestrator directly, and it can edit code or delegate to any agent as it judges fit for the task. Full authority contract: `core/rules/rules-bypass-mode.md`.

This is one of the ways to start work in a session:

- `/nimble` — light engine preset for quick / single-feature work
- `/orchestrated <slug>` — heavy engine preset for a pre-decomposed wave of tickets
- `/chain a,b,c` — custom ordered agent chain on the engine
- `/roadmap` / `/planner` — advisor-only planning (no implementers)
- `/bypass` — just chat (this skill)

The track-selection hook (`require-track-selection.sh`) blocks bare prompts at the start of a session until you pick one of these. Once `/bypass` is on, that hook stops firing for the rest of the session.

## Usage

- `/bypass` or `/bypass on` — enable bypass mode
- `/bypass off` — disable bypass mode, re-enable the track-selection gate

## On Invocation

Parse the argument (default: "on" if no argument given).

### Enable (on)

1. Write the **session-scoped** bypass flag file (ADR-052). The flag is keyed to
   *this* session so a second session in the same repo can't read or wipe it. Use
   the session id from `$CLAUDE_CODE_SESSION_ID` (which equals the `.session_id`
   the gate hooks read on stdin). Write it with Bash so the variable expands:
   ```bash
   AM="$([ -n "$CLAUDE_PROJECT_DIR" ] && echo "$CLAUDE_PROJECT_DIR" || git rev-parse --show-toplevel)/.claude/agent-memory"
   mkdir -p "$AM"
   printf '{"enabled": true, "activated_at": "%s", "session_id": "%s", "reason": "%s"}\n' \
     "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CLAUDE_CODE_SESSION_ID" "<first 100 chars of user message>" \
     > "$AM/bypass-active-${CLAUDE_CODE_SESSION_ID}.json"
   ```
   (The legacy repo-global `bypass-active.json` is no longer honored by the gate hooks — do NOT write it.)

2. Confirm to the user: "Bypass mode active. No track gating — chat freely or invoke any agent directly. Run `/bypass off` to return to normal."

### Disable (off)

1. Remove **this session's** flag: `rm -f "$AM/bypass-active-${CLAUDE_CODE_SESSION_ID}.json"` (resolve `$AM` as in Enable). Do not touch other sessions' flags.
2. Confirm: "Bypass mode off. Next bare prompt will hit the track-selection gate."

## Behavior During Bypass

In bypass mode the orchestrator gains real authority — see `core/rules/rules-bypass-mode.md` for the full contract. Quick summary:

- **Direct source edits.** The orchestrator MAY edit source files itself for small, obvious changes (a 3-line bug fix, a typo, a config tweak). `block-source-edits.sh` short-circuits when this session's `bypass-active-<session_id>.json` is present.
- **`@<agent>` delegation.** Invoke any agent directly by name when specialist judgment is wanted (e.g., `@code-reviewer review src/auth.ts`, `@security-auditor`, `@performance-reviewer`).
- **Heuristic for which path to take.** Scope ≤ ~10 lines AND no specialist context required → direct edit. Otherwise → delegate.
- **No run state.** No run folder, prompt.md, or state file is created. Stop-points and scope-clarification rules still apply.
- **Track switch mid-session.** If you decide partway through that you want a structured run, type `/nimble` or `/orchestrated` — that starts a real run alongside bypass (bypass only removes gating, it doesn't prevent tracking).
- **Per-session only (truly session-scoped — ADR-052).** Bypass persists until `/bypass off` or this session ends. The flag is keyed to this session's id, so a *new* session starts un-bypassed without disturbing this one — and starting another session in the same repo no longer wipes your bypass. `session-cleanup.sh` clears only the starting session's own flag (plus a 24h orphan GC).

## When to use it

- Quick questions about the codebase ("what does this file do?", "where is X defined?")
- Pasting an error and asking for diagnosis before deciding what to do
- One-off agent invocations where you want to chain multiple `@<agent>` calls without keeping the protocol gate active for each one
- Exploration sessions that may or may not turn into work
