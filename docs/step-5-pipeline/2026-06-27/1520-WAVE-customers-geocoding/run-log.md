# Run Log — Wave 2 (customers-geocoding) · HGW-2

**Status: DONE (on wave branch — awaiting operator wave→main PR).**
Branch `feature/wave-customers-geocoding`, 10 commits ahead of main. typecheck 0, lint 0.

## What happened
- Resumed a v1-era orchestrated wave: all 8 tickets (CG-T1..CG-T8) were already committed in dependency order; build verified healthy.
- Ran the wave-end batch-gate: code-reviewer ∥ spec-conformance ∥ security-auditor ∥ db-migration-reviewer ∥ accessibility-auditor ∥ ui-review. Reports persisted in `findings/`.
- Gate verdicts: db-migration-reviewer APPROVE · security-auditor PASS_WITH_CONDITIONS (no Critical/High) · accessibility-auditor PASS_WITH_CONDITIONS · spec-conformance GAP · code-reviewer REQUEST_CHANGES · ui-review FAIL (token drift).
- Disposed per ADR-105: APPLY findings remediated in one implementer pass (commit `ca47e1f`, "CG-T9"); forks + low items deferred (`findings/deferrals-log.md`). Full record: `autonomous-decisions-log.md`.

## Commits
```
c498267 CG-T10: test harness (vitest) + AC-005 RLS isolation + AC-021/CR-003 EWKT round-trip + unit tests
ca47e1f CG-T9: batch-gate remediation (CR-001/002, A11Y-001..011, SA-001/004/005, ui-review tokens)
d7ec556 CG-T8 .. 17cf47b CG-T1 (8 wave tickets)
303df21 docs(roadmap): graduate wave 2
```

## Verification (CG-T10 — operator authorized)
- First test harness stood up (vitest). **24/24 tests pass** on the integrated wave branch.
- **AC-005 cross-tenant RLS isolation: PASS** (4 integration tests, live local Supabase) — the crit-1 security proof is now automated, not just structural.
- **CR-003/AC-021 EWKT UPDATE round-trip: verified YES** through real PostgREST — no code/migration change needed.
- Local DB required `supabase db reset` to apply 0002 (4 pre-existing site rows tripped the empty-table guard — live proof of the MR zero-downtime finding).

## Open follow-ups (still deferred — see deferrals-log.md)
- ambiguous→pick-candidate geocode recovery (AC-012); MR-001 composite tenant↔customer FK; SA-002/003/006 cache/rate-limit hardening; **MR zero-downtime: a populated-table 0002 rollout needs a backfill plan**; misc low items.

## Next operator action
Open the wave→main PR (operator-only, shared-state floor) when ready. Before `gh pr create`, push the wave branch to origin.
