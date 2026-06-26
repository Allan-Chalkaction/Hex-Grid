# /ticket — Implement from Acceptance Criteria

Read acceptance criteria from a GitHub issue or description, create a feature spec, and queue it for implementation.

## Input

`$ARGUMENTS` should be one of:
1. **GitHub issue URL**: `https://github.com/org/repo/issues/123`
2. **Feature description**: Plain text describing what to build with acceptance criteria

## Process

### Step 1: Extract Acceptance Criteria

**If $ARGUMENTS is a GitHub URL:**

Use the GitHub MCP server to fetch issue details:
- Title
- Description/body
- Labels
- Acceptance criteria (look for checkboxes, "AC:", "Given/When/Then", or numbered requirements)
- Any linked issues or PRs

If GitHub MCP is not configured, inform the user:
> ⚠️ GitHub MCP server not configured. Add it to `.mcp.json` or paste the issue body directly:
> `/ticket <paste acceptance criteria here>`

**If $ARGUMENTS is plain text:**

Parse the text for:
- Feature name (first line or inferred from content)
- Requirements (bullet points, numbered lists, checkboxes)
- Constraints or edge cases mentioned

### Step 2: Create Feature Spec

Generate a spec file at `docs/step-3-specs/<feature-slug>.md`:

```markdown
# Feature: <Feature Name>

## Source
- GitHub Issue: <URL if applicable>
- Created: <timestamp>

## Overview
<1-2 sentence summary>

## Acceptance Criteria
- [ ] <criterion 1>
- [ ] <criterion 2>
- [ ] <criterion 3>

## Technical Approach
<Brief technical plan — which files to create/modify, patterns to use>

## Files to Create/Modify
- `client/src/pages/<page>.tsx` — New page component
- `client/src/hooks/use-<feature>.ts` — Data fetching hook
- `supabase/migrations/<timestamp>_<feature>.sql` — Schema changes (if needed)
- `client/client/src/schemas/<feature>.ts` — Zod validation (if forms involved)

## Edge Cases
<List edge cases identified from the acceptance criteria>

## Out of Scope
<Anything explicitly NOT included>
```

### Step 3: Queue for Pipeline

Update `docs/step-3-specs/_queue.json` to add the new spec:

```bash
# Read current queue
cat docs/step-3-specs/_queue.json

# Add new entry with status "ready"
```

Add entry:
```json
{
  "spec": "<feature-slug>",
  "status": "ready",
  "source": "<github-url or 'manual'>",
  "created": "<ISO timestamp>",
  "priority": "normal"
}
```

### Step 4: Summary

Output a summary:
```
✅ Ticket processed

📋 Spec: docs/step-3-specs/<feature-slug>.md
📊 Queue: Added to _queue.json (status: ready)
🔗 Source: <GitHub URL or "manual input">

Next steps:
- Review the spec: cat docs/step-3-specs/<feature-slug>.md
- Start implementation: /ship-it <feature-slug>
- Or refine the spec first: /plan-to-spec <feature-slug>
```

## Without GitHub MCP

If the GitHub MCP server is not available, the command still works with pasted text:

```
/ticket Add user avatar upload: users can upload a profile picture (max 5MB, jpg/png only),
it should crop to square, store in Supabase Storage, and display in the header nav.
Must work on mobile. Should show a loading spinner during upload.
```

The command parses this into acceptance criteria and generates the spec.
