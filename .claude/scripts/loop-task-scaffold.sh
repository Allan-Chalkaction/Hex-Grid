#!/usr/bin/env bash
#
# loop-task-scaffold.sh — the mechanical core of the /loop-task wrapper (T6).
#
# The official ralph-loop plugin (/ralph-loop) defaults to UNLIMITED iterations
# (--max-iterations 0). /loop-task is the D-locked thin wrapper that (a) lands every
# bounded grind in our run-folder convention with a PRD + progress log, and (b)
# ENFORCES a sane max-iterations cap so a loop can never run away.
#
# This script does the deterministic part: it creates/populates the run folder and
# emits the exact `/ralph-loop ...` invocation the orchestrator should run. It does
# NOT call /ralph-loop itself (that is a slash command the orchestrator issues, and
# it requires the ralph-loop plugin to be enabled). Keeping the scaffold in a script
# makes the cap-enforcement + folder-shape MECHANICAL and TESTABLE without the plugin.
#
# Usage:
#   loop-task-scaffold.sh --run-dir DIR --task "TEXT"
#       [--max-iterations N] [--completion-promise TEXT]
#       [--prd-file FILE]            # use FILE as PRD.md instead of the --task body
#
# Defaults:
#   --max-iterations    : 5    (override with LOOP_TASK_DEFAULT_MAX_ITER)
#   --completion-promise: DONE
#
# Cap policy (the safety point):
#   - no --max-iterations given  -> inject the default (5). Never leaves it unset.
#   - --max-iterations 0         -> ALLOWED but loud: 0 means UNLIMITED in ralph; the
#                                   script warns on stderr and records it in the PRD.
#   - --max-iterations <neg|nonint> -> rejected (exit 2).
#
# Output: writes {run_dir}/{PRD.md,progress.md,prompt.md}; prints a JSON summary
# (run_dir, max_iterations, completion_promise, ralph_command) to stdout. Exit 0 ok,
# 2 on usage/validation error. Re-running overwrites PRD.md + prompt.md; progress.md is
# PRESERVED if it already exists (so a loop's iteration history is never clobbered).
set -uo pipefail

DEFAULT_MAX_ITER="${LOOP_TASK_DEFAULT_MAX_ITER:-5}"

die() { printf 'loop-task-scaffold: %s\n' "$*" >&2; exit 2; }

RUN_DIR=""; TASK=""; MAX_ITER=""; PROMISE="DONE"; PRD_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)            RUN_DIR="${2:-}"; shift 2 || die "--run-dir needs a value" ;;
    --task)               TASK="${2:-}"; shift 2 || die "--task needs a value" ;;
    --max-iterations)     MAX_ITER="${2:-}"; shift 2 || die "--max-iterations needs a value" ;;
    --completion-promise) PROMISE="${2:-}"; shift 2 || die "--completion-promise needs a value" ;;
    --prd-file)           PRD_FILE="${2:-}"; shift 2 || die "--prd-file needs a value" ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$RUN_DIR" ] || die "--run-dir is required"
if [ -z "$TASK" ] && [ -z "$PRD_FILE" ]; then
  die "one of --task or --prd-file is required"
fi
if [ -n "$PRD_FILE" ] && [ ! -f "$PRD_FILE" ]; then
  die "--prd-file not found: $PRD_FILE"
fi

# CR-001 (crit-3): PROMISE and RUN_DIR are interpolated into the emitted /ralph-loop invocation
# string (a slash-command line the operator pastes). An embedded " or \ would break out of the
# quoted argument and inject extra flags — e.g. a promise of `X" --max-iterations 0 "` would defeat
# the cap this wrapper exists to enforce. Reject them (matches the reject-on-bad-input cap policy).
# (--task is NOT interpolated into the command — it only lands in PRD.md via printf '%s' — so it
# does not need this guard.)
case "$PROMISE" in
  *\"*|*\\*) die "--completion-promise must not contain a double-quote or backslash (would corrupt the emitted /ralph-loop invocation)" ;;
esac
case "$RUN_DIR" in
  *\"*|*\\*) die "--run-dir must not contain a double-quote or backslash (would corrupt the emitted /ralph-loop invocation)" ;;
esac

# --- cap policy --------------------------------------------------------------
UNLIMITED_WARN=""
if [ -z "$MAX_ITER" ]; then
  MAX_ITER="$DEFAULT_MAX_ITER"            # never leave it unset
elif [ "$MAX_ITER" = "0" ]; then
  UNLIMITED_WARN="yes"                    # explicit unlimited — allowed but loud
  printf 'loop-task-scaffold: WARNING — --max-iterations 0 means UNLIMITED in ralph-loop. The loop will only stop on the completion promise (%s). This defeats the wrapper'\''s safety cap; pass a positive N unless you really want an unbounded grind.\n' "$PROMISE" >&2
elif ! printf '%s' "$MAX_ITER" | grep -Eq '^[0-9]+$'; then
  die "--max-iterations must be a non-negative integer (got: $MAX_ITER)"
fi

mkdir -p "$RUN_DIR" || die "cannot create run dir: $RUN_DIR"

# --- PRD.md ------------------------------------------------------------------
PRD_PATH="$RUN_DIR/PRD.md"
if [ -n "$PRD_FILE" ]; then
  cp "$PRD_FILE" "$PRD_PATH"
else
  {
    printf '# Loop task — PRD\n\n'
    printf '## Bounded task\n\n%s\n\n' "$TASK"
    printf '## Loop control\n\n'
    printf -- '- max-iterations: %s%s\n' "$MAX_ITER" "$([ -n "$UNLIMITED_WARN" ] && printf ' (UNLIMITED — no cap)' || true)"
    printf -- '- completion-promise: `%s`\n\n' "$PROMISE"
    printf '## Completion criteria (be specific — the promise may ONLY be emitted when ALL are true)\n\n'
    printf -- '- [ ] The bounded task is complete by its own automated pass/fail check.\n'
    printf -- '- [ ] The verifying command exits 0 (record it below).\n\n'
    printf '## Verifying command\n\n```\n# e.g. the test/lint/build command that defines "done"\n```\n\n'
    printf '## Emitting the completion promise (READ — this is how the loop exits)\n\n'
    printf 'The ralph Stop-hook scans only the **last text block** of your final message and looks for\n'
    printf 'the promise wrapped in literal `<promise>...</promise>` tags. To exit the loop when done:\n\n'
    printf -- '1. Wrap the promise in tags: `<promise>%s</promise>` (the inner text must match exactly).\n' "$PROMISE"
    printf -- '2. Emit it as the **final thing in your message** — its own closing line, with **no prose,\n'
    printf '   tool calls, or other text after it** (trailing content becomes a separate "last block" and\n'
    printf '   the hook will miss the tag, so the loop runs to the iteration cap instead of exiting).\n'
    printf -- '3. NEVER emit the promise unless every completion criterion above is genuinely true.\n'
  } > "$PRD_PATH"
fi

# --- progress.md (iteration log; ralph re-feeds the same prompt each pass) ----
PROG_PATH="$RUN_DIR/progress.md"
if [ ! -f "$PROG_PATH" ]; then
  {
    printf '# Loop task — progress log\n\n'
    printf '_Append one entry per ralph iteration: what you tried, what the verifying command returned, what is left._\n\n'
    printf -- '- iteration 0 (scaffold): run folder created; awaiting first ralph pass.\n'
  } > "$PROG_PATH"
fi

# --- the /ralph-loop invocation the orchestrator should run ------------------
# The prompt points ralph at the PRD + progress log so every iteration is grounded
# in the durable run folder, not chat history.
RALPH_PROMPT="Work the bounded task defined in ${RUN_DIR}/PRD.md. Each iteration: make progress, run the PRD's verifying command, and append an entry to ${RUN_DIR}/progress.md. Only when EVERY completion criterion in PRD.md is genuinely satisfied (the verifying command exits 0), exit the loop by emitting the promise wrapped in literal tags — <promise>${PROMISE}</promise> — as the FINAL text of your message, with nothing after it (no prose or tool calls after the tag, or the Stop-hook scans the wrong block and the loop will not exit). Never emit the promise if the criteria are not met."
RALPH_CMD="/ralph-loop \"${RALPH_PROMPT}\" --max-iterations ${MAX_ITER} --completion-promise \"${PROMISE}\""

# --- prompt.md (records the launch + the exact invocation) -------------------
{
  printf '# loop-task launch\n\n'
  printf -- '- run-dir: %s\n' "$RUN_DIR"
  printf -- '- max-iterations: %s\n' "$MAX_ITER"
  printf -- '- completion-promise: %s\n\n' "$PROMISE"
  printf '## Ralph invocation\n\n```\n%s\n```\n' "$RALPH_CMD"
} > "$RUN_DIR/prompt.md"

# --- JSON summary (machine-readable for the skill / tests) -------------------
python3 - "$RUN_DIR" "$MAX_ITER" "$PROMISE" "${UNLIMITED_WARN:-}" "$RALPH_CMD" <<'PY'
import json, sys
run_dir, max_iter, promise, unlimited, ralph_cmd = sys.argv[1:6]
print(json.dumps({
    "run_dir": run_dir,
    "max_iterations": int(max_iter),
    "unlimited": bool(unlimited),
    "completion_promise": promise,
    "prd": f"{run_dir}/PRD.md",
    "progress": f"{run_dir}/progress.md",
    "ralph_command": ralph_cmd,
}, indent=2))
PY
