---
description: Generate a conventional commit message from staged changes
---

Generate a commit message for the current staged changes.

## Steps

1. Run `git diff --cached` to see staged changes
2. Run `git log --oneline -5` to match the repo's commit style
3. Write a message following Conventional Commits format:

```
<type>(<scope>): <short summary>

<optional body — explain WHY, not WHAT>
```

**Types:** `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`, `ci`, `style`

## Rules

- Subject line under 72 characters
- Imperative mood ("add", not "added")
- No period at end of subject
- Body wraps at 72 characters
- Reference issue numbers when applicable

$ARGUMENTS
