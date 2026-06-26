---
description: Quick dependency audit for vulnerabilities, outdated packages, and unused deps
---

Audit project dependencies for security, maintenance, and bloat concerns.

## Steps

1. **Security scan:**
   ```bash
   npm audit
   ```
   List all vulnerabilities by severity (critical, high, moderate, low).

2. **Outdated check:**
   ```bash
   npm outdated
   ```
   Flag packages more than 1 major version behind.

3. **License review:** Check `package.json` dependencies for license compatibility. Flag any GPL, AGPL, or unknown licenses.

4. **Bundle impact:** Identify the largest dependencies by checking import usage across the codebase. Flag any that are imported for a single utility.

5. **Unused dependencies:** Search for packages in `package.json` that have zero imports in `client/src/`.

## Output Format

```markdown
## Dependency Audit — [DATE]

### 🔴 Critical
- [package] — [issue and recommended action]

### 🟡 Attention
- [package] — [issue and recommended action]

### 🟢 Healthy
- [count] dependencies up to date, no known vulnerabilities

### Recommendations
1. [Prioritized action items]
```

$ARGUMENTS
