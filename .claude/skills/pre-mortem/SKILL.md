---
description: Run a pre-mortem analysis to identify risks before shipping a feature or change
---

Run a pre-mortem analysis on this project or feature.

## Process

Imagine the feature/project has failed spectacularly 3 months after launch. Work backwards to identify what went wrong.

### Step 1: Identify Failure Modes

For each category, list what could go wrong:

- **Security** — Data breaches, auth bypasses, exposed secrets, missing RLS
- **Performance** — Slow queries, N+1 problems, large bundle, missing indexes
- **Reliability** — Unhandled edge cases, missing error states, race conditions
- **Usability** — Confusing flows, accessibility failures, broken mobile experience
- **Data** — Corruption, loss, privacy violations, incorrect aggregations
- **Operations** — Deployment failures, missing monitoring, no rollback plan
- **Scope** — Feature creep, unclear requirements, wrong assumptions

### Step 2: Rate Each Risk

| Risk | Likelihood | Impact | Priority |
|------|-----------|--------|----------|
| [risk] | High/Med/Low | High/Med/Low | 🔴/🟡/🟢 |

### Step 3: Mitigation Plan

For each 🔴 and 🟡 risk, propose a concrete mitigation:
- What to do before launch
- What to monitor after launch
- What the rollback plan is

## Output Format

```markdown
## Pre-Mortem: [Feature/Project Name]

### Top Risks
1. 🔴 [risk] — [mitigation]
2. 🔴 [risk] — [mitigation]
3. 🟡 [risk] — [mitigation]

### Full Risk Matrix
[table from Step 2]

### Recommendations
[prioritized action items to reduce risk before launch]
```

$ARGUMENTS
