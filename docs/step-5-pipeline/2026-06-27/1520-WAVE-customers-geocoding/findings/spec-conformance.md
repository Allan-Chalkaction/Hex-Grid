# Spec-Conformance Audit — Wave 2 (customers-geocoding)

**Verdict: GAP** · scope `git diff main..HEAD` (CG-T1..CG-T8). `tsc --noEmit` clean (AC-020).

Coverage check: **complete** — union of all tickets' acceptance[] covers all 21 spec ACs; none unclaimed.
Per-AC: 18 CONFORMS, 1 GAP (AC-005), 2 DRIFT (AC-012, AC-021).

**Systemic note:** project has no automated test harness; spec's test-named verifications (AC-005/009/016/021) cannot run. Statically-confirmable behaviors rated CONFORMS on implementation; AC-005 is the exception (runtime security property).

## AC-005 — GAP — HIGH · `_criterion_match_: crit-1` · APPLY
Cross-tenant isolation: structural mechanism present + correct (`customer` 4-policy RLS keyed `auth_tenant_ids()` `0002:50-67`; `site_geo` `security_invoker` `0002:95`; no anon policy). But the spec-mandated seeded two-tenant integration test does not exist (no test runner/files). Highest-stakes property ships unverified at runtime.
**Remediation:** minimal harness + seeded two-tenant RLS test (A sees only A across `customer`/`site_geo`; unauth→zero). If out of wave scope, DEFER with explicit dossier — do not let the security proof silently drop.

## AC-012 — DRIFT — MEDIUM · `_criterion_match_: crit-1` · DEFER
3/4 failure classes correct (timeout→retry, rate-limit→backoff, no-match→manual; `CustomerForm.tsx:35-49`). `ambiguous` has no candidate-list recovery (falls to manual); Edge Function never emits `ambiguous` (`geocode/index.ts:104-106`). Pick-candidate affordance absent end-to-end.
**Remediation:** ranked candidates + pick-candidate UI, or record scoped deferral acknowledging top-match collapse.

## AC-021 — DRIFT — LOW · `_criterion_match_: none` · DEFER
Substantive standard met — RPC fallback taken for inserts (AC permits). Divergence is internal inconsistency: migration reframes `place_site` as DEFAULT for inserts yet move/edit persist via raw EWKT (`customers.ts:121,150`). No documented round-trip verification.
**Remediation:** verify EWKT update round-trips, or route updates through RPC; document the result.

## CONFORMS (18): AC-001,002,003,004,006,007,008,009,010,011,013,014,015,016,017,018,019,020
(full evidence per AC retained from agent run — migration shape, geocoder seam, Edge Function caps, reactive pins, CSV import 1:1 report, RLS-scoped CRUD, deterministic cache, dedup, forward-only reverse, a11y/useId/role=alert, SiteList deleted, tsc clean).
