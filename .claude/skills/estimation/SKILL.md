---
description: Estimate work effort using a structured framework with complexity, risk, and unknowns
---

Estimate the work described below using a structured framework.

## Steps

1. **Understand scope:** Read the task description. Identify all components: frontend, backend, database, testing, documentation.

2. **Break down into subtasks:** List every discrete piece of work.

3. **Estimate each subtask** using T-shirt sizes:
   - **XS** (< 1 hour) — config change, copy update, simple fix
   - **S** (1-4 hours) — single component, simple endpoint, straightforward test
   - **M** (4-8 hours) — feature with multiple components, new DB table + RLS + migration
   - **L** (1-3 days) — cross-cutting feature, new pattern establishment, complex state
   - **XL** (3-5 days) — major feature, architectural change, multi-system integration

4. **Identify risks** that could inflate the estimate:
   - Unknowns or dependencies on external systems
   - Areas of the codebase you haven't touched before
   - Need for new patterns or library evaluation

## Output Format

```markdown
## Estimate: [Task Name]

| Subtask | Size | Notes |
|---------|------|-------|
| [subtask] | M | [why] |

**Total: [range]** (e.g., "M-L, likely 1-2 days")

### Risks
- [risk and potential impact on timeline]

### Assumptions
- [what you're assuming to reach this estimate]
```

Task: $ARGUMENTS
