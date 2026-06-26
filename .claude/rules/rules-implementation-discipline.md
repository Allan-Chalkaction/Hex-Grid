# Implementation Discipline (Universal)

These rules apply to implementation work in any track — pipeline, nimble, or
direct edits in bypass mode. They were originally located in
`rules-nimble-routing.md` (pre mode-aware refactor) but apply universally and
were relocated as part of OQ-4.

---

## Multi-Fix Batch Isolation

**BEHAVIORAL** — no hook.

When the user provides multiple fixes in a single prompt:

1. **One fix per implementer invocation.** Each fix gets its own agent call.
2. **Verify each fix independently.** Run `git diff --name-only` + typecheck + tests after each.
3. **Do not proceed to the next fix if the current fix fails verification.**
4. **Each fix gets its own run folder** with its own prompt.md and findings.
5. **Quality gates run once after all fixes are verified** (not per-fix).

## Investigation-First Debugging

**BEHAVIORAL** — no hook.

When debugging errors, MUST investigate before proposing fixes.

1. **Add debug logging or read real data FIRST.** Do not guess at root causes.
2. **Do not make repeated speculative fixes.** If your first fix doesn't resolve the issue, stop and investigate deeper.
3. **When asked to investigate, investigate independently.** Read code, query data, trace execution paths.

### Database bug chain audit

When a database operation is failing, audit the **full chain** in one pass:

1. Does the column/table exist in the current schema?
2. Are there correct unique constraints?
3. Are RLS policies correct for **all roles**?
4. Are there trigger conflicts or cascading issues?
5. Are foreign key references valid?

Do NOT fix one layer, wait for it to fail again, then fix the next. Audit everything upfront.

### Test-driven bug fixes

For non-trivial bugs:

1. Write a test that reproduces the exact failure
2. Run the test to confirm it fails
3. Implement the minimal fix
4. Run the test again to confirm it passes
5. Run related existing tests for regressions
