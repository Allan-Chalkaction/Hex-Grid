---
description: "Analyze a completed pipeline run and surface optimization opportunities. Use after a pipeline completes to capture signal before the session ends."
---

## Retrospective: Post-Pipeline Run Analysis

Analyze a completed pipeline run and produce a structured optimization summary. This is a read-only analysis — no files are modified except writing `retrospective.md` to the run folder.

## Step 1: Identify the Run

Parse `$ARGUMENTS` to determine the target run:
- If a run_dir path or feature slug is provided, use it
- If no argument: read `docs/step-3-specs/_queue.json`, find the most recently updated entry with status `DONE` or `COMPLETE`, and use its `run_dir`
- If no completed run is found, report: "No completed pipeline run found. Provide a run_dir or feature slug." and exit.

Verify the run folder exists. If not, report the error and exit.

## Step 2: Gather Context

Read these files (skip any that don't exist — note which are missing):

1. `{run_dir}/progress.md` — gate iterations, phase outcomes
2. All files in `{run_dir}/findings/` — gate verdicts and findings
3. `docs/step-3-specs/_metrics.jsonl` — find the entry matching this run's slug
4. `.claude/skills/batch-gate/SKILL.md` — gate definitions (for context on what each gate catches)
5. `{run_dir}/spec.md` — original scope and acceptance criteria
6. `{run_dir}/cto-evaluation.md` — CTO verdict (if it exists)

## Step 3: Analyze

Evaluate the run across four dimensions. Skip any section with nothing actionable to report.

### 1. Gate Signal
- Gates that fired and passed cleanly on first iteration → candidate for demotion or scope narrowing (is the gate catching real issues for this type of work?)
- Gates that required remediation loops → what caused the failure? Is this a pattern the implementer should learn? Candidate for skill doc update or implementer prompt refinement.
- Gates that were skipped → were they correctly skipped per the gate matrix?

### 2. Spec/ADR Quality
- Decisions that were relitigated or changed during implementation (compare spec intent vs. what was actually built)
- Open questions in the spec that should have been pre-decided (caused implementation ambiguity)
- Scope drift: features added or removed vs. original spec acceptance criteria

### 3. Phase Efficiency
- Phases that consumed disproportionate effort relative to their scope
- Sequential work that could have been parallelized
- Agent re-invocations that indicate unclear instructions or missing context

### 4. Recommended Actions
- Concrete, prioritized list
- Each action names the specific file to change and what to change
- Focus on systemic improvements, not one-off fixes
- Examples: "Update `.claude/agents/implementer.md` to include [pattern]", "Add gotcha to `docs/skills/reference/common-gotchas.md`"

## Step 4: Write Output

Write `{run_dir}/retrospective.md` using this template:

```markdown
# Retrospective: [feature slug]

**Run:** [run_dir]
**Date:** YYYY-MM-DD
**Pipeline result:** [DONE/COMPLETE]
**Total gates run:** [N] | **Gates with remediation loops:** [N]

## Gate Signal

[Analysis or "All gates passed cleanly on first iteration. No signal."]

## Spec/ADR Quality

[Analysis or "Spec and ADR aligned with implementation. No drift detected."]

## Phase Efficiency

[Analysis or "All phases proportionate to scope."]

## Recommended Actions

1. **[Priority]** [File to change]: [What to change and why]
2. ...

(or "Clean run — no actions recommended.")
```

If the run was clean with nothing actionable, write a one-sentence retrospective and exit:

```markdown
# Retrospective: [feature slug]

**Run:** [run_dir]
**Date:** YYYY-MM-DD

Clean run — all gates passed first iteration, no scope drift, no inefficiencies detected.
```

## Step 5: Display

Print the full retrospective content to the terminal.

## Rules

- **Read-only** — the only file written is `{run_dir}/retrospective.md`
- **Direct and useful** — optimization signal only, not a celebration or post-mortem
- **Single run scope** — do not analyze trends across runs (metrics exist for that later)
- **No speculation** — only report what the artifacts show. If a file is missing, note it but don't guess what it contained.

$ARGUMENTS
