# Deferrals — Wave 1 (hex-grid-foundation)

DEFER ui-review/UIR-001,UIR-002,UIR-003,UIR-004 → wave-5 (reference-overlays): author ui-spec-addendum + token vocabulary; tokenize W1 literals; add hover states  [found_by=ui-review, at=2026-06-26T23:01:50Z]
DEFER spec-conformance/AC-001,002,003,006,008 → live-QA: run `supabase start` + `supabase db reset` + two-tenant RLS isolation & empty-read test (turns DRIFT→CONFORMS)  [found_by=spec-conformance, at=2026-06-26T23:01:50Z]
DEFER security/SA-001 → wave-2 (customers-geocoding): guard seed.sql so it aborts against a non-local DB  [found_by=security-auditor, at=2026-06-26T23:01:50Z]
DEFER tests/TEST-COVERAGE → standalone: automated RLS-isolation + empty-read smoke suite  [found_by=spec-conformance, at=2026-06-26T23:01:50Z]
