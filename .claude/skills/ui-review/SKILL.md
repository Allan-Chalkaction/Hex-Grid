---
description: Run a visual quality review checking design token compliance, typography, spacing, and UI spec fidelity
---

You MUST use the ui-review agent to perform this review. Do not attempt to perform the review yourself — invoke the agent.

Focus areas (if specified): $ARGUMENTS

If no specific focus area is given, run a full visual quality audit across all new/modified UI components.

## Before invoking the agent: Check for UI spec addendum

1. Read `docs/step-3-specs/_queue.json`
2. Find the most recently updated entry with status `DONE` that has a `run_dir` field
3. If found, check if `{run_dir}/ui-spec-addendum.md` exists
4. If the addendum is missing, warn: "No UI spec addendum found for this pipeline run. The review will use default visual standards."

## Invoke the ui-review agent

Pass to the agent:
- The run_dir path (if found)
- The list of files to review (from $ARGUMENTS or from `{run_dir}/progress.md`)
- Whether a ui-spec-addendum.md exists

## After the agent completes: Persist findings

1. Read `docs/step-3-specs/_queue.json`
2. Find the most recently updated entry with status `DONE` that has a `run_dir` field
3. If found, write the agent's findings to `{run_dir}/findings/ui-review.md` using this template:

```markdown
# UI Review Findings: [feature slug]

**Agent:** ui-review
**Date:** YYYY-MM-DD
**Verdict:** [PASS | PASS_WITH_WARNINGS | FAIL]

## Summary

[2-3 sentence summary from agent output]

## Findings

[Severity-classified findings from agent output, or "No findings -- clean pass."]
```

4. Create the `{run_dir}/findings/` directory if it doesn't exist
5. If no matching queue entry exists, skip persistence (findings are in conversation only)

## On FAIL verdict

If the ui-review agent returns FAIL, report the findings and ask the user whether to route back to the implementer for fixes or proceed to other quality gates.
