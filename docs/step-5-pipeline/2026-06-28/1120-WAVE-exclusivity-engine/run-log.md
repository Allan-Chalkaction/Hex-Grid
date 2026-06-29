# Run Log — Wave 3 (exclusivity-engine) · HGW-3
**Status: DONE on wave branch `feature/wave-exclusivity-engine` (8 ahead of main, awaiting operator wave→main PR).** typecheck 0, lint 0, 39/39 tests green (live local Supabase).

## What shipped
Per-site exclusivity zones (radius off/0.5–3 mi), within-vertical conflict detection via security_invoker RPCs (conflicts_at/site_conflicts, bidirectional max(A,B) ST_DWithin), circle zone rendering (deck.gl) + conflict surfacing, warn-with-confirm on add/move, customer.vertical promotion + backfill, and (CR-001) per-customer configurable exclusivity scope (competitor-only default + toggle for same-brand territory protection).

## Tickets (8)
EX-T1 migration 0003 + conflict RPCs + RLS/spatial tests · EX-T2 conflicts.ts seam + SiteGeo · EX-T3 vertical picker · EX-T4 radius picker · EX-T5 zones+conflictIds+map · EX-T6 warn-confirm dialog · EX-T7 configurable scope (CR-001, migration 0004) · EX-T8 batch-gate remediation.

## Gates (batch) → dispositions (ADR-105)
architect SOUND · security PASS · migration APPROVE · ui PASS-w/warn · spec 22/24 (test-only gaps) · perf HAS_ISSUES (ADR-anticipated) · a11y FAIL · code NEEDS_DISCUSSION.
- APPLIED (EX-T8): A11Y-001/002/003, ui M1, SA-001, MR-001.
- RESOLVED (EX-T7): CR-001 → configurable per-customer scope (competitor-only default).
- DEFERRED (findings/deferrals-log.md): PR-001/002 perf (single tenant_conflicts() RPC + GIST pre-filter; correct spec "10k"→"hundreds"); AC-016/017 component-test harness (RTL/jsdom); SA-002; ui-L2; arch is_zone_on fold; eslint-plugin-jsx-a11y.

## MCL integration (this session)
scripts/mcl-sync.py + .git/hooks/post-commit auto-flip ticket status from per-ticket commits → MCL tracked all 8 tickets live during the build.

## Next operator action
Push `feature/wave-exclusivity-engine` + open wave→main PR (operator authority). Pre-deploy: migrations 0003/0004 are additive (run cleanly on populated tables — unlike 0002, no guard).
