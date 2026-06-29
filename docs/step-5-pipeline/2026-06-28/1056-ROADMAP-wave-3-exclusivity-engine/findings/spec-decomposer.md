# Spec-Decomposer — Wave 3 (exclusivity-engine): 6 tickets

Graph: EX-T1[] → EX-T2[T1] → EX-T3[T2] → EX-T4[T2,T3] → EX-T5[T2,T4] → EX-T6[T2,T3,T5]. Acyclic; all 24 ACs covered.

| Ticket | Title | depends_on | planned_files | ACs | gates |
|--------|-------|-----------|---------------|-----|-------|
| EX-T1 | Migration 0003 (customer.vertical + backfill; recreate site_geo +3 fields; conflicts_at + site_conflicts security_invoker RPCs + grants) + RLS/spatial vitest integration tests + harness | — | 0003_exclusivity_engine.sql, src/lib/exclusivity.integration.test.ts, src/test/integration-setup.ts, vitest.config.ts | AC-001..012 | db-migration-reviewer, security-auditor, performance-reviewer, architect-review |
| EX-T2 | Conflict seam conflicts.ts (findConflicts/findSiteConflicts) + SiteGeo +3 fields + updateSiteRadius | EX-T1 | src/lib/conflicts.ts, src/lib/customers.ts, src/lib/conflicts.test.ts | AC-013,014,015 | code-reviewer, architect-review |
| EX-T3 | Customer vertical picker — controlled `<select>` on add (CustomerForm) + edit reveal (CustomerRow); writes customer.vertical | EX-T2 | CustomerForm.tsx, CustomerList.tsx, customers.ts, index.css | AC-019 | code-reviewer, accessibility-auditor, ui-review, architect-review |
| EX-T4 | Per-site radius `<select>` (Off/0.5..3 mi) in SiteRow → updateSiteRadius → onChanged | EX-T2, EX-T3 | CustomerList.tsx, index.css | AC-018 | code-reviewer, accessibility-auditor, ui-review |
| EX-T5 | siteZonesLayer (ScatterplotLayer) + conflictIds derivation in App + MapShell mount (under pins) + zone-status row surfacing | EX-T2, EX-T4 | siteZonesLayer.ts, MapShell.tsx, App.tsx, CustomerList.tsx, index.css | AC-021,022,024 | code-reviewer, accessibility-auditor, ui-review, performance-reviewer |
| EX-T6 | Warn-with-confirm conflict dialog on add + move (findConflicts wired into both write paths; native `<dialog>`) | EX-T2, EX-T3, EX-T5 | CustomerForm.tsx, CustomerList.tsx, index.css | AC-016,017,020,023,024 | code-reviewer, accessibility-auditor, ui-review, architect-review |

## Orchestrator notes
- **Amend-planned-files (not scope shift):** `src/App.tsx` added in EX-T5 — App owns the lifted `sites` state and must also own/thread `conflictIds` (conflict is pairwise/dynamic, not a view column).
- **Test harness:** EX-T1 stands up `vitest.config.ts` + `src/test/integration-setup.ts`. (Note: harness already exists from W2 CG-T10 — the builder should EXTEND it, not recreate.) RLS-scoped integration tests need a live Supabase/PostGIS target (available locally).
- **Within-wave shared sinks** (customers.ts, CustomerList.tsx, CustomerForm.tsx, index.css) serialized safely by the depends_on chain under one sequential wave writer.
- Threshold semantic locked: bidirectional `max(A.radius,B.radius)` point-in-zone (not A+B).
