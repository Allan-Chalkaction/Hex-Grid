---
name: loop-task
description: "Run a bounded, test-verifiable grind — /loop-task scaffolds a PRD + progress log, caps iterations, then hands off to the ralph-loop plugin. For get-the-suite-green, mechanical migrations, lint cleanup — NOT design/ambiguous work."
user_invocable: true
---

## Run a bounded grind (`/loop-task` — the Ralph wrapper)

`/loop-task` is the thin wrapper (D-locked, T6) over the official Anthropic **`ralph-loop`**
plugin (`/ralph-loop`). Ralph is a Stop-hook loop that re-feeds the same prompt back each
iteration until a completion promise appears or a max-iterations cap is hit. We do **not**
hand-build a loop — we adopt the plugin and wrap it so every grind:

1. lands in our run-folder convention with a durable **PRD.md** + **progress.md** (not chat
   history), and
2. **always has a max-iterations cap** — ralph defaults to `--max-iterations 0` (UNLIMITED),
   which is the foot-gun the wrapper exists to prevent.

**Use it for:** "get the suite green," mechanical migrations, lint/format cleanup, codemod
sweeps — anything with an automated pass/fail check. **Do NOT use it for** design or ambiguous
work (that's a `/chain` or `/orchestrated` job). Pairing pattern: **plan via a chain → hand the
bounded ticket to `/loop-task` → batch-gate at the end.**

### 0. Pre-flight — the plugin must be enabled

`/loop-task` requires the `ralph-loop` plugin (pinned in `core/config/required-plugins.json`).
Check + enable if needed:

```bash
./switch-infra.sh status        # the "Required plugins" section reports ralph-loop's enable state
```

If it reports `NOT-ENABLED`, install/enable it via Claude Code's plugin manager — **run `/plugin`**
and enable `ralph-loop` from the `claude-plugins-official` marketplace (Claude Code owns plugin
enablement; the substrate never edits `~/.claude/settings.json` itself). Then re-run `status`.

### 1. Scaffold the run folder (via the helper — **Bash**, not the Write tool)

> **Substrate path resolution (consumer-safe — ADR-031).** The scaffold helper lives at
> `core/scripts/…` when dogfooding inside claude-infra, but at `.claude/scripts/…` in a consumer
> repo (where `core/` is absent — it is symlinked under `.claude/`). A bare `core/…` path does NOT
> resolve in a consumer; the block below resolves the prefix first.

```bash
SLUG="<kebab, <=4 words>"; D="docs/step-5-pipeline/$(date +%Y-%m-%d)/$(date +%H%M)-LOOP-$SLUG"
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
$S/loop-task-scaffold.sh --run-dir "$D" \
  --task "<the bounded task + its automated pass/fail check>" \
  --max-iterations <N> \
  --completion-promise "DONE"
```

- `--max-iterations` is **optional**; omit it to take the enforced default (**5**; override the
  default with `LOOP_TASK_DEFAULT_MAX_ITER`). The scaffold NEVER leaves the cap unset.
- `--max-iterations 0` is accepted but prints a loud UNLIMITED warning — only use it when you
  genuinely want an unbounded grind.
- Pass `--prd-file FILE` to use a pre-written PRD instead of the inline `--task` body.
- Using **Bash** (the helper writes the folder, not the Write tool) keeps the v1 auto-fire hook
  (`sync-artifacts-post-agent.sh`, PostToolUse on Write) from triggering the legacy state machine.

The helper writes `PRD.md` (task + completion criteria + the verifying command), `progress.md`
(the iteration log ralph appends to), and `prompt.md` (the launch record). It prints a JSON
summary whose **`ralph_command`** is the exact invocation to run next.

### 2. Hand off to `/ralph-loop`

Run the `ralph_command` the scaffold printed — it is a ready-to-paste `/ralph-loop "<prompt>"
--max-iterations N --completion-promise "DONE"`, with the prompt already pointing ralph at
`PRD.md` + `progress.md`. Ralph then loops in the current session: each iteration it works the
task, runs the verifying command, appends to `progress.md`, and only emits the promise when the
PRD's completion criteria are genuinely met (or it stops at the cap).

> **Command namespacing:** Claude Code namespaces plugin commands as `<plugin>:<command>`, so this
> appears in the picker as **`ralph-loop:ralph-loop`** (cancel: `ralph-loop:cancel-ralph`, help:
> `ralph-loop:help`). The short `/ralph-loop` form the scaffold emits resolves to it — both work.
>
> Monitor: `grep '^iteration:' .claude/ralph-loop.local.md` · cancel: `/ralph-loop:cancel-ralph` (or `/cancel-ralph`).

### 3. Batch-gate at the end (the pairing pattern)

Ralph grinds; it does not review. When the loop completes, run the quality gates over the result
— `/batch-gate`, or a `/chain code-reviewer,spec-conformance` — then commit. A bounded grind is
"done" only after it passes its verifying command **and** the gate.

## Why a wrapper (not raw /ralph-loop)

Raw `/ralph-loop` works, but (a) it leaves no run-folder artifact, so the grind's intent + progress
live only in `.claude/ralph-loop.local.md`, and (b) its default is unlimited iterations. The wrapper
fixes both: durable PRD/progress in the dated run folder, and a cap that is always set. See
`docs/conventions/ralph-and-loop-task.md` for the full fit + safety guidance and ADR-042 for the
decision.
