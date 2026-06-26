---
description: "Execute a batch of cosmetic UI changes (styling, spacing, copy, layout) on existing files with minimal ceremony. One run folder, one typecheck, one ui-review."
---

## Batch UI Tweaks

Fast path for cosmetic UI changes. The orchestrator executes changes directly (no agent delegation) and runs one consolidated ui-review at the end.

**Invocation:**

- `/batch-ui-tweaks` — parse items from the preceding message
- `/batch-ui-tweaks 1. Fix padding on card from p-4 to p-6  2. Change header text to "Overview"` — inline items

---

## Step 0: Parse and Qualify Items

Parse the user's list of UI changes from `$ARGUMENTS` or the preceding message. For each item, extract:

- **Target file(s)** — identify from the description (Glob if needed)
- **What to change** — the specific property, class, or text
- **Desired value** — what it should become

### Qualification test

Each item MUST pass ALL of the following:

1. **Existing files only** — target file(s) already exist. No new files created.
2. **Cosmetic-only** — the change modifies one or more of:
   - CSS/styling classes (Tailwind utilities, CSS modules, inline styles)
   - Spacing values (padding, margin, gap)
   - Color tokens
   - Typography (font-size, font-weight, line-height, text classes)
   - Copy/text strings (labels, headings, placeholder text, button text)
   - Layout properties (width, height, max-width, display, flex, grid, border-radius, opacity, visibility, overflow, z-index)
   - Static asset references (swapping one image/icon for another)
3. **No logic changes** — does NOT add or remove:
   - Event handlers (onClick, onChange, onSubmit, etc.)
   - State (useState, useReducer, store mutations)
   - Props (adding new props to a component signature)
   - Hooks (useEffect, useMemo, custom hooks)
   - Conditional rendering logic (new if/ternary blocks)
   - API calls or data fetching
   - Imports of new libraries or modules
4. **Scope limit** — touches at most 2 files per item (e.g., component + its style file)

**Note:** Changing *values inside existing* ternaries/conditionals is allowed (e.g., `isActive ? 'bg-blue-500' : 'bg-gray-200'` to `isActive ? 'bg-indigo-600' : 'bg-slate-200'`). The test is whether the *structure* changes, not whether the line contains logic.

### Display qualification table

Show:

```
| # | File(s) | Change | Qualified |
|---|---------|--------|-----------|
| 1 | src/components/Card.tsx | p-4 → p-6 | Yes |
| 2 | src/pages/Dashboard.tsx | "Dashboard" → "Overview" | Yes |
| 3 | (new file needed) | Add tooltip component | No — new file |
```

For each disqualified item, explain why and recommend: "Route through nimble individually."

If zero items qualify, stop: "No items qualify for batch-ui-tweaks. Route through nimble or pipeline."

If at least one item qualifies, proceed with qualified items only.

---

## Step 1: Load Minimal Context

Read only what's needed for cosmetic changes:

1. **CLAUDE.md** — already loaded by orchestrator
2. **Theme/token source of truth** — if the project has a CSS variables file, Tailwind config, or design token file referenced in CLAUDE.md or `.claude/agent-context/`, read it. This ensures token references are valid.
3. **`.claude/project-paths.sh`** — if it exists, source it to get typecheck/lint/test commands

Do NOT load:
- Agent-context overlay files
- Coding standards docs
- Module reference docs
- Spec, ADR, or ui-spec-addendum files

---

## Step 2: Create Batch Run Folder

Create the run folder and save the prompt:

```
docs/step-5-pipeline/YYYY-MM-DD/HHmm-NIMBLE-batch-ui-tweaks/
```

Where `YYYY-MM-DD` is today's local date and `HHmm` is the current local time (24h format).

Write `prompt.md` containing:
- The full list of items (qualified and disqualified)
- Qualification status for each
- Note which items are being executed

---

## Step 3: Execute Changes

For each qualified item, sequentially:

1. Read the target file
2. Make the change using Edit
3. Move to the next item immediately — no per-item verification

After ALL items are complete:

4. Run typecheck (once)
5. Run lint (once)
6. Run tests (once)

If any verification step fails:
- Identify which item(s) caused the failure
- Fix the issue
- Re-run the failing verification step
- If a fix requires structural changes (not cosmetic), report the item as "ejected during execution" and revert that item's changes

---

## Step 4: Show Diff

Run `git diff` and display the complete diff to the user. This is the review moment — the user sees all changes at once before the quality gate runs.

---

## Step 5: Quality Gate — ui-review

Run the `ui-review` agent once on all changed files. This is **mandatory** — it cannot be skipped.

Invoke via Agent tool with the ui-review agent. Include:
- The list of all changed files
- Context: "Batch cosmetic UI changes — review for token consistency, spacing scale, and accessibility regressions"

If ui-review returns **PASS** or **PASS_WITH_WARNINGS**: proceed to Step 6.

If ui-review returns **FAIL**:
- Display the findings
- Offer to fix the issues and re-run ui-review (one retry)
- If still failing after retry, present findings to the user for decision

---

## Step 6: Log and Track

All logging happens once for the entire batch:

1. **Run-log** — write `{run_dir}/run-log.md`:
   ```markdown
   # Batch UI Tweaks

   **Track:** Nimble
   **Date:** YYYY-MM-DD HHmm
   **Items submitted:** N
   **Items executed:** M
   **Items ejected:** N-M

   ## Changes Made
   - [item 1 summary] (file path)
   - [item 2 summary] (file path)

   ## Ejected Items
   - [item summary] — reason

   ## Agents Invoked
   - ui-review: [verdict]

   ## Decision Log
   - [Any non-obvious choices, or "None"]
   ```

2. **Findings** — write ui-review output to `{run_dir}/findings/ui-review.md`

3. **Sprint log** — append one entry to `docs/step-5-pipeline/YYYY-MM-DD/sprint-log.md`:
   ```
   - [x] Batch UI tweaks: {M} cosmetic changes ({comma-separated file list})
   ```

4. **QA tracker** — read `docs/step-3-specs/_qa-tracker.json`, append one entry to `pending`:
   ```json
   {
     "slug": "{run_folder_name}",
     "title": "Batch UI tweaks: {M} cosmetic changes",
     "track": "nimble",
     "run_dir": "{run_dir}",
     "registered": "{ISO timestamp}"
   }
   ```

5. **Nimble counter** — increment `ungated_count` by 1 in `docs/step-3-specs/_queue.json` (not by M — this is one logical batch)

---

## Step 7: Results

Display:

1. Summary table: item number, file, change, status (applied / ejected / fixed by ui-review)
2. ui-review verdict
3. If all passed: "Batch complete. {M} changes applied. Use `/commit-message` to commit."
4. If items were ejected: list them with routing recommendation

---

## Meta-Work Exclusion

This skill always touches source files, so `ungated_count` always increments by 1.

## Context Management

- Do NOT delegate to implementer or any other implementation agent
- Keep context lean — read only the files being changed + theme source of truth
- If the batch exceeds 20 items, suggest splitting into two invocations to manage context
