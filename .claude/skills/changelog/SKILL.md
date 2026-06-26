---
description: Generate a changelog entry from recent git history following Keep a Changelog format
---

Generate a changelog entry for recent changes.

## Steps

1. Run `git log --oneline` from the last release tag (or last changelog entry) to HEAD
2. Categorize each commit:
   - **Added** — new features
   - **Changed** — changes to existing functionality
   - **Fixed** — bug fixes
   - **Removed** — removed features
   - **Security** — vulnerability fixes
   - **Deprecated** — soon-to-be-removed features
3. Write the entry in Keep a Changelog format:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- Description of new feature (#issue)

### Fixed
- Description of bug fix (#issue)
```

## Rules

- User-facing language (not commit messages verbatim)
- Link issue/PR numbers where applicable
- Skip internal refactors and chore commits unless they affect users
- Most recent version at the top

$ARGUMENTS
