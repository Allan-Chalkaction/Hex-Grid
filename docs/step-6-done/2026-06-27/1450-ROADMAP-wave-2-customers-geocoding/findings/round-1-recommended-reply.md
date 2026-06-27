# round-1-recommended-reply

_Persisted by the orchestrator from the roadmap workflow return (FLAG-1: scripts have no FS access; agents cannot Write)._

Self-QA of `# Wave: customers-geocoding` — verify-by-view against /Users/allanmittelstaedt/Desktop/Dev/hex-grid.

SCHEMA — PARSEABLE. Header `# Wave: customers-geocoding`, Protocol version 3, Has UI true. 8 `### CG-TN:` tickets; all six keys single-hyphen (depends_on, planned_files, acceptance, gate_recommendations, manual_review_required, description); every planned_files non-empty. DAG acyclic: T1[],T2[],T3[T2],T4[T1,T3],T5[T4,T6],T6[T4],T7[T5,T6],T8[T1]. AC coverage complete — all 21 ACs defined in docs/step-5-pipeline/2026-06-27/1450-ROADMAP-wave-2-customers-geocoding/spec.md (AC-001..AC-021) are referenced exactly by the ticket set; no orphan, no dangling reference.

VERIFY-BY-VIEW — CLAIMS ACCURATE.
- CG-T8 replace target `new MapboxOverlay({ layers: [] })` is verbatim at src/components/MapShell.tsx:33.
- CG-T1 references to 0001 all hold: site_tenant_{select,insert,update,delete} shape, auth_tenant_ids() SECURITY DEFINER helper, geocode_cache + geocode_cache_insert (authenticated), DELIBERATE-NO-ANON posture, site.exclusivity_radius_mi present and left untouched (supabase/migrations/0001_init_postgis_schema.sql).
- CG-T6/T7 a11y pattern (useId, role=alert, .field/.form-error) present in src/components/AuthGate.tsx.
- App.tsx renders SiteList; SiteList.tsx exists (CG-T7 supersede/delete target valid). auth.ts/tenant.ts seam exists (CG-T3). EWKT POINT(lng lat) order correct.

SHARED-SINK SOUND under one-implementer-per-wave (ADR-062/063): 0002_*.sql authored by CG-T1, conditionally appended by CG-T4 (serialized via depends_on [CG-T1]); index.css authored by CG-T6, final pass by CG-T7 (serialized via depends_on [CG-T6]). Single sequential writer dissolves within-wave hazard.

THREE MINOR DESCRIPTION INACCURACIES (non-blocking, CONTINUE-class — do not affect graph/planned_files/build output):
1. CG-T6 cites `#555` as an existing src/index.css literal — not present (real literals: #1a73e8, #b00020, #ddd); #555 appears nowhere in src/.
2. CG-T7 parenthetical "Shares index.css with CG-T6/CG-T5" contradicts CG-T5's own body ("no index.css edit here"; its planned_files excludes index.css). Only CG-T6 shares the sink.
3. CG-T7 "darken the link-as-body-text blue" implies a pre-existing body-text blue; index.css currently uses #1a73e8 only for the focus outline — the remediation is forward-looking for surfaces authored in this wave (fine, just phrased as if a literal exists).

RECOMMENDATION: LOCK. Spec is structurally sound, schema parseable, claims verified, AC coverage 21/21. Fold the three tunings or record as open refinements. Side note: confirm the build's source-of-truth artifact — the canonical wave skeleton at docs/step-3-specs/hex-grid/waves/customers-geocoding/customers-geocoding.md is still a 41-line fat skeleton; detailed ACs live in the ROADMAP spec.md.
