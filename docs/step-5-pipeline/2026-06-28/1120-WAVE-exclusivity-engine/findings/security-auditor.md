# Security Audit — Wave 3 · Verdict: PASS (no Critical/High, no criterion match)
Load-bearing control correct: both RPCs + recreated site_geo are `security invoker` (no definer slip), pinned search_path, grants revoke public/anon + grant authenticated (mirror place_site). Cross-tenant isolation inherited from 0001/0002 RLS via invoker; tested (AC-012 + rls-isolation). No injection (EWKT is a bound RPC param), no secrets, warn-confirm carries NO security control.
- **SA-001 (LOW, APPLY) — findConflicts builds EWKT without the isValidLatLng guard updateSiteLocation uses** (conflicts.ts:42). Not injectable; both current callers pre-validate. Mirror the SA-005 precedent: guard inside findConflicts.
- **SA-002 (LOW, DEFER) — raw PostgREST error.message surfaced to UI** (conflicts.ts:48,63; W2 seam pattern). Optional: map to generic message + log detail.
- **SA-003 (INFO, DEFER) — whole-tenant N-RPC fan-out** (App.tsx) — perf domain, not security.
- **SA-004 (INFO) — warn dialog correctly non-security.** OWASP Top 10:2025 all PASS/NA except A09 (SA-002 low). Secrets scan clean.
