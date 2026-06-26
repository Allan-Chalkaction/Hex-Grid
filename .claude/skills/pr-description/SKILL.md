---
description: Generate a PR description from branch diff with what/why/how-to-test sections
---

Generate a PR description for the current branch.

## Steps

1. Run `git log main..HEAD --oneline` to see all commits on this branch
2. Run `git diff main...HEAD --stat` for a file-level summary
3. Read changed files to understand the full scope
4. Write the PR description:

```markdown
## Summary
<1-3 bullet points explaining what and why>

## Changes
<grouped list of meaningful changes, not a file dump>

## Test plan
- [ ] <how to verify each change>

## Notes
<anything reviewers should pay attention to>
```

## Rules

- Title: under 70 characters, imperative mood (`feat: add user profile`, not `feat: added user profile`)
- Summary focuses on WHY, not WHAT
- Group related changes, don't list every file
- Test plan has concrete verification steps

$ARGUMENTS
