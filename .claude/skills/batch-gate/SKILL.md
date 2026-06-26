---
description: "Run quality gates on accumulated ungated changes (nimble + pipeline), then suggest commit."
---

## Batch Gate: Quality-Gate Nimble Work

Run quality gates on all changes accumulated since the last commit (nimble track work). This is the safety net for work that bypassed the full pipeline.

## Step 0: Read Batch State

Read `ungated_count` from `docs/step-3-specs/_queue.json`:

```bash
jq -r '.ungated_count // 0' docs/step-3-specs/_queue.json
```

If the value is `0`, report: "No ungated tasks. Nothing to gate." and exit. Do not run any gates.

If the value is greater than 0, note the count — it will be referenced in the findings header.

## Step 1: Identify Changes

1. Run `git diff --name-only HEAD` to get all modified files (staged + unstaged)
2. Run `git diff --name-only --cached` to get staged-only files
3. If no changes exist, report: "No uncommitted changes to gate. Nothing to do."
4. Read `docs/step-5-pipeline/YYYY-MM-DD/sprint-log.md` (where `YYYY-MM-DD` is today's date) — display today's entries as context for what was done. If the date folder or sprint log file doesn't exist, note that no sprint log entries exist for today.

## Step 2: Determine Required Gates

### Project layout overlay (A1)

The matrix below uses path patterns derived from claude-infra's original consumer (a Supabase + React + Playwright project). Other projects (e.g., Mission Control, an Electron + better-sqlite3 app) have different layouts. Each project MAY define overlay tokens that the matrix consumes; defaults match the original Supabase shape.

If `.claude/agent-context/batch-gate.md` exists in the project, read it and use the overlay tokens defined there. Otherwise use the defaults below.

| Token | Default | Description |
|---|---|---|
| `MIGRATIONS_PATTERN` | `supabase/migrations/` | Path prefix for SQL / schema migrations. Triggers `db-migration-reviewer` + `security-auditor`. |
| `EDGE_FUNCTIONS_PATTERN` | `supabase/functions/` | Path prefix for serverless / edge handlers. Triggers `security-auditor`. |
| `DATA_HOOKS_PATTERN` | `client/src/hooks/use-*.ts(x)` | Glob for data-layer hooks. Triggers `performance-reviewer`. |
| `E2E_CONFIG_PATTERN` | `playwright.config.*` | Glob for the project's e2e harness config. Presence (anywhere in the project) gates `e2e-test-writer`. |

A project's overlay file might look like:

```markdown
# batch-gate overlay (Mission Control)

MIGRATIONS_PATTERN=apps/desktop/src/main/db/migrations/
EDGE_FUNCTIONS_PATTERN=
DATA_HOOKS_PATTERN=apps/desktop/src/renderer/hooks/use-*.ts(x)
E2E_CONFIG_PATTERN=apps/desktop/playwright.config.*
```

Empty overlay value → the corresponding row is suppressed (e.g., MC has no edge-functions surface, so `EDGE_FUNCTIONS_PATTERN=` disables that row).

### Quality gate matrix — the deterministic floor is `batch-gate-matrix.py` (F9, ADR-126)

**The surface→agent selection is a DETERMINISTIC decision script, not an LLM inference (F9 contract,
ADR-126).** `core/scripts/batch-gate-matrix.py` is the executable form of the matrix below — given the
changed-file set + the resolved overlay tokens, it prints `{decision: [agents], reason, confidence}` with
**zero LLM in its body**. The skill **acts on the script's `decision` array as the floor gate set** — it does
NOT re-derive the gate selection by judgment alongside the script. Run it (ADR-031 path resolution):

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
FILES=$(git diff --name-only HEAD | paste -sd, -)
# pass the resolved overlay tokens (defaults are the original Supabase shape; a consumer overrides via the
# .claude/agent-context/batch-gate.md tokens read above — empty value suppresses that row):
python3 "$S/batch-gate-matrix.py" select --files "$FILES" --repo-root . \
  --migrations "${MIGRATIONS_PATTERN:-supabase/migrations/}" \
  --edge "${EDGE_FUNCTIONS_PATTERN:-supabase/functions/}" \
  --data-hooks "${DATA_HOOKS_PATTERN:-client/src/hooks/use-*.ts*}" \
  --e2e "${E2E_CONFIG_PATTERN:-playwright.config.*}"
```

The `decision` array IS the gate set Step 3 runs. The matrix below is the human-readable specification the
script implements (its `reason` field cites which row fired); read it to understand the verdict, but the
**script's verdict is the floor the skill acts on** (the F9 wire-to-consumer contract, ADR-126 D-2 — not a
parallel LLM call that re-decides). Apply the matrix below using the resolved overlay values:

| Condition | Required Gates |
|-----------|---------------|
| Always | code-reviewer |
| Any UI surface (visual ext `.tsx/.jsx/.vue/.svelte/.css/.scss` or a `components/app/pages/ui` dir) | + ui-review — **auto-added** by the orchestrated engine's deterministic `hasUiSurface` floor (ADR-104), not a manual selection. Add it by hand only for an off-engine `/batch-gate` over UI files. |
| Any file matching `${MIGRATIONS_PATTERN}` | + db-migration-reviewer, + security-auditor |
| Any file matching `${EDGE_FUNCTIONS_PATTERN}` | + security-auditor |
| `package.json` was modified | + dependency-auditor |
| Any file matching `${DATA_HOOKS_PATTERN}` | + performance-reviewer |
| 10+ files changed | + performance-reviewer |
| Any `.tsx` with visual output modified or created AND `${E2E_CONFIG_PATTERN}` exists in the project | + e2e-test-writer |

Display the list of gates that will run and why; include the overlay file path if one was consulted.

**Note:** qa-tester is available on request (`"write unit tests for this"`) but is NOT a default gate — e2e-test-writer provides more valuable coverage for solo/small team workflows. e2e-test-writer runs when any `.tsx` with visual output is touched (new or modified) and Playwright is configured.

## Step 3: Run Gates

Run gates in two waves:

**Wave 1 (read-only gates):** Run sequentially using the Agent tool with the appropriate `subagent_type`: code-reviewer, ui-review, security-auditor, db-migration-reviewer, dependency-auditor, performance-reviewer (whichever were selected in Step 2).

**Wave 2 (test-writing gates, runs last):** After all Wave 1 gates complete, run qa-tester and e2e-test-writer (if selected). These run last because they write test files and should test the final state of the code.

For each gate invocation:
- Include the list of changed files
- Instruct the agent to review the changes
- Extract the verdict (APPROVE/PASS/PASS_WITH_CONDITIONS/FAIL/REQUEST_CHANGES)

After each gate, display: `{agent-name}: {VERDICT}`

If a gate returns FAIL or REQUEST_CHANGES with blocking severity:
- Display the findings
- Record NEEDS_REVISION in the findings file
- Continue to remaining gates (do not halt — collect all findings before stopping)

After all gates have run, if any returned FAIL or NEEDS_REVISION:
- Say: "One or more gates require revision. See findings. Fix issues, then run `/batch-gate` again."

## Step 4: Batch Gate Artifact Folder

The batch gate run folder follows the nimble run folder convention:

```
docs/step-5-pipeline/YYYY-MM-DD/HHmm-BATCH-GATE/
  run-log.md
  findings/
    code-reviewer.md
    security-auditor.md
    [other gates].md
```

Where:
- `YYYY-MM-DD` is today's date
- `HHmm` is the approximate start time of the `/gate-batch` invocation (24h format)
- `BATCH-GATE` is the fixed folder name for all batch gate runs

Create the date folder and run folder if they don't exist. Write `run-log.md` using this template:

```markdown
# Batch Gate

**Track:** batch
**Date:** YYYY-MM-DD HHmm UTC
**Trigger:** /gate-batch
**Ungated tasks at start:** N

## What Changed
- [summary of files gated, from git diff]

## Agents Invoked
- [agent-name]: [verdict] — [one-line summary]

## Decision Log
- [Any non-obvious choices made, or "None"]
```

Write gate findings to `{run_dir}/findings/{agent-name}.md` using the Findings Template below.

**Note:** Individual nimble task run folders (non-batch-gate) use the same base convention (`HHmm-NIMBLE-task-name/`) but with a task-specific name instead of `batch-gate`.

## Step 5: Counter Reset

After all gates complete — regardless of whether any gate failed — reset `ungated_count` to 0 in `docs/step-3-specs/_queue.json`:

Read the current file, set `ungated_count` to `0`, and write it back. The counter resets unconditionally so the developer is not stuck in a loop re-gating the same batch.

If any gate returned FAIL or NEEDS_REVISION, the findings file already captures that status. The developer can review findings and decide whether to revise before committing, without needing the counter to remain elevated.

## Step 6: Results

After all gates complete and the counter is reset:

1. Display a summary table (agent name, verdict, finding count)
2. If all gates passed: "All gates passed. `ungated_count` reset to 0. Use `/commit-message` to commit, or stage specific files first."
3. If any gate failed: "One or more gates require revision. See findings in `{run_dir}/findings/`. `ungated_count` has been reset to 0."

## Meta-Work Exclusion

The ungated work counter (`ungated_count`) is NOT incremented for tasks that only touch meta-work files. A task is meta-work if ALL files it touched match these patterns:

- `.claude/**` — agent definitions, hooks, skills, commands, settings
- `*.md` — any markdown file anywhere in the project (covers `docs/**/*.md`, `CLAUDE.md`, skill files, etc.)

If even one file falls outside these patterns, the counter increments by 1 after the sprint log entry is appended.

Examples:

| Task | Files Touched | Increments? |
|------|--------------|-------------|
| Update implementer agent | `.claude/agents/implementer.md` | No (`.claude/**`) |
| Fix hook script | `.claude/hooks/suggested-next-step.sh` | No (`.claude/**`) |
| Add sprint log entry | `docs/step-5-pipeline/2026-03-13/sprint-log.md` | No (`*.md`) |
| Remove console.log | `client/src/App.tsx` | Yes |
| Update skill + fix component | `.claude/skills/batch-gate/SKILL.md`, `client/src/components/Foo.tsx` | Yes (Foo.tsx is product code) |

## Findings Template

After EACH gate completes, extract the verdict (APPROVE, PASS, PASS_WITH_CONDITIONS, FAIL, REQUEST_CHANGES, REJECT) and write findings to `{run_dir}/findings/{agent-name}.md`.

Findings must contain enough context for an implementer in a **fresh session** (no prior conversation context) to act on every finding without guessing. Persist the agent's evidence and remediation — do not summarize it away.

```markdown
# [Agent Name] Findings: [feature slug]

**Agent:** [agent-name]
**Date:** YYYY-MM-DD
**Verdict:** [verdict extracted from output]
**Review iteration:** 1
**Scope:** [list of files the agent actually reviewed, one per line with `-` prefix]
```

**Summary** (required): 2-4 sentences covering what was reviewed, overall assessment, and finding counts by severity.

**Per-finding format** (required for each finding):

```markdown
### [ID] ([Severity]): [Short title]

**File:** `path/to/file.ext` (line ~N)
**Rule/Standard:** [What standard, convention, or rule is violated — e.g., "WCAG 2.2 1.4.3", "RLS subquery form (CLAUDE.md)", "OWASP A01:2021"]
**Evidence:**
[The problematic code, 1-8 lines, fenced in a code block with language tag]
**Why it matters:** [One sentence — the consequence if unfixed: data leak, broken a11y, perf regression, convention drift, etc.]
**Remediation:**
[The specific fix — exact code, SQL, or config to change, fenced in a code block]
```

**Field requirements by severity:**

| Severity | File + line | Rule/Standard | Evidence | Why it matters | Remediation |
|----------|-------------|---------------|----------|----------------|-------------|
| Critical / Blocking | Required | Required | Required | Required | Required |
| High | Required | Required | Required | Required | Required |
| Medium | Required | Recommended | Recommended | Required | Recommended |
| Low / Nit / Suggestion | Required | Optional | Optional | Optional | Optional |

For Low/Nit/Suggestion findings, a one-line format is acceptable:
```markdown
- **[ID] (Low):** `path/to/file.ext` — [description and optional fix]
```

**Clean pass section** (optional, encouraged): If the agent reported areas that passed cleanly, include a `## Clean` section listing what was checked and passed. This confirms scope coverage.

**Notes:**
- Create `{run_dir}/findings/` directory on first write if it doesn't exist.
- "No findings — clean pass." is valid for the Findings section when the verdict is APPROVE/PASS with zero issues.

## Context Management

- Do NOT read source code files yourself — let the gate agents read what they need
- Keep conversation output to verdicts and findings — no analysis prose
- This skill should complete in one pass; if context is a concern, run fewer gates
