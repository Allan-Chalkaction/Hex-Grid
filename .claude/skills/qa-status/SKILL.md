---
description: "Show pending QA items or mark a run as QA-complete. Use to track what needs manual validation after pipeline and nimble runs."
---

## QA Status Tracker

Track which pipeline and nimble runs need manual validation. This skill reads and writes `docs/step-3-specs/_qa-tracker.json`.

**Invocation:**

- `/qa-status` — show all pending QA items
- `/qa-status complete <slug-or-number>` — mark a run as QA-complete
- `/qa-status all` — show both pending and completed items

---

## Argument Parsing

Parse `$ARGUMENTS` (trimmed, case-insensitive):

- **Empty or blank:** Action = `LIST_PENDING`
- **Starts with `complete`:** Action = `MARK_COMPLETE`, identifier = remainder after "complete" (trimmed)
- **Equals `all`:** Action = `LIST_ALL`
- **Anything else:** Action = `LIST_PENDING` (treat as filter — see Step 3)

---

## Step 1: Read the Tracker

Read `docs/step-3-specs/_qa-tracker.json`.

- If the file does not exist, print:
  ```
  No QA tracker found. Runs will appear here after pipeline or nimble work completes.
  ```
  Then stop.

- If the file contains invalid JSON, print:
  ```
  QA tracker exists but contains invalid JSON.
  Check docs/step-3-specs/_qa-tracker.json manually.
  ```
  Then stop.

The tracker has this structure:

```json
{
  "pending": [
    {
      "slug": "1422-NIMBLE-fix-avatar-crop",
      "title": "Fix avatar cropping on mobile profile page",
      "track": "nimble",
      "run_dir": "docs/step-5-pipeline/2026-03-18/1422-NIMBLE-fix-avatar-crop",
      "registered": "2026-03-18T14:25:00"
    }
  ],
  "complete": [
    {
      "slug": "1305-PIPELINE-auth-rewrite",
      "title": "New auth middleware with token rotation",
      "track": "pipeline",
      "run_dir": "docs/step-5-pipeline/2026-03-17/1305-PIPELINE-auth-rewrite",
      "registered": "2026-03-17T13:10:00",
      "completed": "2026-03-18T09:30:00"
    }
  ]
}
```

---

## Step 2: Execute Action

### LIST_PENDING

Display only `pending` items. If the pending array is empty, print:

```
Nothing pending QA. You're clear.
```

Otherwise, display the table (see Step 3).

### LIST_ALL

Display `pending` items first, then `complete` items (see Step 3).

### MARK_COMPLETE

The identifier can be:

1. **A number** (e.g., `3`) — match by position in the pending list (1-indexed, as shown in the table)
2. **A partial slug** (e.g., `fix-avatar` or `auth-rewrite`) — match any pending entry whose `slug` contains the string (case-insensitive)
3. **A title fragment** (e.g., `avatar cropping`) — match any pending entry whose `title` contains the string (case-insensitive)

**If zero matches:** Print `No pending item matches "{identifier}". Run /qa-status to see the list.` and stop.

**If multiple matches:** Print all matches with their numbers and ask the user to be more specific. Do not mark anything.

**If exactly one match:**

1. Remove the entry from `pending`
2. Add `"completed": "{current ISO timestamp}"` to the entry
3. Append it to `complete`
4. Write the updated tracker back to `docs/step-3-specs/_qa-tracker.json`
5. Print: `Marked as QA-complete: {title}`

---

## Step 3: Display Format

Print the pending table:

```
QA Pending
==========

 #  Track     Slug                              Title
 1  nimble    1422-NIMBLE-fix-avatar-crop        Fix avatar cropping on mobile profile page
 2  pipeline  1305-PIPELINE-auth-rewrite         New auth middleware with token rotation
 3  nimble    1510-NIMBLE-typo-landing           Copy fix on landing hero
```

Layout rules:
- `#` is the 1-indexed position in the pending list (used for `complete <number>`)
- Columns: `#`, `Track`, `Slug`, `Title`
- Two spaces between columns minimum; align columns by padding to the longest value in each
- Sort by `registered` ascending (oldest first — longest-waiting items at top)

If the user provided a non-command argument (not "complete", not "all"), treat it as a filter:
- Show only entries where `slug` or `title` contains the argument (case-insensitive)
- Prefix the table with: `Filtered by: "{argument}"`

**For LIST_ALL**, after the pending table, add:

```

QA Complete
===========

 #  Track     Slug                              Title                                       Completed
 1  pipeline  0930-PIPELINE-dashboard            Dashboard redesign                          2026-03-17
 2  nimble    1100-NIMBLE-button-fix             Fix submit button double-click              2026-03-17
```

- `Completed` column shows the date portion of the `completed` timestamp
- Sort by `completed` descending (most recently completed first)
- Show at most the 20 most recent completed items. If more exist, append: `({N} more completed items not shown)`

---

## Step 4: Summary Line

After the table(s), print a blank line followed by:

```
Summary: {N} pending, {M} completed
```

---

## Registration (for other skills — not executed by this skill)

Other skills (pipeline, nimble orchestrator) register entries by appending to the `pending` array in `docs/step-3-specs/_qa-tracker.json`. The registration format is:

```json
{
  "slug": "{run_folder_name}",
  "title": "{one-sentence description of what was built or fixed}",
  "track": "pipeline|nimble",
  "run_dir": "{full run_dir path}",
  "registered": "{ISO timestamp}"
}
```

**Rules for registering skills:**
- Create the file with `{"pending": [], "complete": []}` if it doesn't exist
- Read → append → write (never overwrite the whole file)
- The `title` must be a human-readable summary, not a slug or file path
- The `slug` is the run folder name (e.g., `1422-NIMBLE-fix-avatar-crop` or `0930-PIPELINE-dashboard`)

---

## Reminders

- This skill reads and writes ONLY `docs/step-3-specs/_qa-tracker.json`. It does not modify any other file.
- Do not call any network APIs or external services.
- If any entry is malformed (missing required fields), skip it gracefully and note "(malformed entry skipped)" in the table.
