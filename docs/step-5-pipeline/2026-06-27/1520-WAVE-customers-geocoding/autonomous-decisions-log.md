# Autonomous Decisions Log — Wave 2 (customers-geocoding)

Run: docs/step-5-pipeline/2026-06-27/1520-WAVE-customers-geocoding · ticket key HGW-2
Disposition basis: ADR-105 default autonomous disposition (judgment-class → dispose+log+continue; only execution-class blocks halt). Bypass active for the remediation dispatch.

## ✅ FORKS RESOLVED (operator authorized "handle the test and verification"; local Supabase available)

### FORK-1 — Test harness / AC-005 cross-tenant RLS proof (CR-004, AC-005, crit-1) → RESOLVED (harness built, test passes)
- **Initial decision:** deferred (no test infra; treated as scope expansion).
- **Resolution:** Operator authorized handling it. Stood up the project's first test harness (vitest, commit CG-T10 `c498267`) and wrote the seeded two-tenant RLS integration test. Ran against the live local Supabase: **AC-005 PASS** — user A sees only tenant A's `customer`+`site_geo` rows, user B only B's, anon sees ZERO. The cross-tenant security property is now proven AND guarded by an automated regression test.
- **Outcome:** the crit-1 gap is closed, not deferred.

### FORK-2 — EWKT update round-trip / persistence-seam consistency (CR-003, AC-021) → RESOLVED (verified YES)
- **Initial decision:** deferred (needed a live Supabase).
- **Resolution:** Local Supabase reset to apply 0002; AC-021 integration test exercises the real PostgREST `.update({ geog: 'SRID=4326;POINT(lng lat)' })` path (exactly `updateSiteLocation`'s mechanism) and reads back `site_geo`. **PASS** — lat/lng round-trip to 5 decimals; the `place_site` RPC insert path likewise round-trips. **The EWKT UPDATE works through PostgREST — no code change / no follow-up migration needed.** The seam inconsistency CR-003 flagged is benign.
- **Note:** applying 0002 locally required `supabase db reset` (operator-approved) because the 4 pre-existing local `site` rows tripped 0002's empty-table guard — a live demonstration of the MR zero-downtime finding (still deferred for production: a populated-table rollout needs a backfill plan).

## ✅ JUDGMENT-CLASS — APPLY (remediated in commit ca47e1f, CG-T9)
Dispatched one remediation implementer (worktree, ff-merged). All verified: typecheck 0, lint 0.
- CR-001 (HIGH) attributes data-loss on re-import → non-destructive dedup.
- CR-002 (MED) empty lat/lng → 0,0 → reject empty/whitespace + WGS84 range guard.
- SA-005 (LOW) internal coord validation in `updateSiteLocation`.
- CR-006 stable React key for site rows.
- SA-001 (MED) `verify_jwt=true` in config.toml + reject empty JWT in geocode function.
- SA-004 (LOW) CSV formula-injection neutralization in error report.
- A11Y-001 (HIGH) focus first input on SiteRow mode switch.
- A11Y-002 (MED) native `<dialog>` delete confirm.
- A11Y-003 (MED) pre-seeded aria-live regions.
- A11Y-004 (MED) `<main>` landmark.
- A11Y-005 (MED) import outcome label+glyph mapping.
- A11Y-008/010/011 + L-1 glyphs, useId progress bar, map role=application.
- ui-review H-1, M-1..M-7 (light), L-4 + A11Y-006/007/009 — index.css token cleanup.

## ⏸️ JUDGMENT-CLASS — DEFER (logged, see deferrals-log.md)
CR-005/AC-012 (ambiguous→pick-candidate); SA-002 (cache poisoning, ADR-001 design); SA-003 (rate limiting); SA-006 (cache UPDATE policy); MR-001 (composite tenant↔customer FK); MR-002/003/004 (index/anon-revoke/cascade); CR-009 (partial-failure state); M-5 full forms-into-dialog restructure; L-2/L-3 (status wording / pin minor).

## Gate verdicts (post-remediation context)
db-migration-reviewer APPROVE · security-auditor PASS_WITH_CONDITIONS (SA-001 now fixed) · accessibility-auditor PASS_WITH_CONDITIONS (A11Y-001 now fixed) · code-reviewer REQUEST_CHANGES (CR-001/002 now fixed; CR-003/004 deferred) · spec-conformance GAP (AC-005 deferred, AC-012 deferred, AC-021 deferred) · ui-review FAIL (token drift now fixed).
