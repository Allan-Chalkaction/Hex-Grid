# spec-conformance (integrated wave)

VERDICT: DRIFT



## Findings
- **AC-001** [medium · none · DEFER] INCONCLUSIVE on runtime; correct by inspection (migration L10 postgis; config.toml seed enabled; helper L68 before policies L121+). Resolve via live supabase db reset.
- **AC-002** [medium · none · DEFER] INCONCLUSIVE on live query; CONFORMS by source. site.geog geography(Point,4326) L36; attributes jsonb default '{}' L40; site_geog_gist L47; geocode_cache no tenant_id L52-59.
- **AC-003** [high · none · DEFER] INCONCLUSIVE on live two-tenant test; policy SQL CONFORMS. RLS on all 4 tables L93-96; membership_self_select keys off auth.uid() no subquery L114-116; geocode_cache shared L144-150; no anon policy. README L121-149 has the documented procedure floor.
- **AC-006** [medium · none · DEFER] INCONCLUSIVE on post-reset counts; CONFORMS by inspection. seed.sql upserts dev tenant, membership, self-contained auth.users L35-93; README L32-63 documents create-first ordering.
- **AC-008** [low · none · DEFER] INCONCLUSIVE on follow-the-steps; README CONFORMS with the 4 ordered quickstart steps L20-95.
- **AC-004** [low · none · DISMISS] CONFORMS on build (npm run build exit 0). MapShell openfreemap liberty, CONUS center, MapboxOverlay empty layer L26-34. Render half is ui-review.
- **AC-005** [low · none · DISMISS] CONFORMS. SiteList.tsx:30-33 calls supabase.from('site') on mount; App.tsx renders it behind AuthGate. Wired to consumer.
- **AC-007** [low · none · DISMISS] CONFORMS. auth.ts sole module touching supabase.auth; tenant.ts resolves from membership; README L96-111 documents the swap point.
- **AC-009** [high · none · DISMISS] CONFORMS. No anon policy; migration L73 search_path pinned, L78 revoke from public, L87 revoke from anon, L88 grant to authenticated.
- **AC-010** [high · none · DISMISS] CONFORMS. Only grep hit is package-lock integrity hash (false positive). .env.example names-only; .gitignore ignores .env; client reads import.meta.env.
- **TEST-COVERAGE** [low · none · DEFER] No app test suite ships, but spec sets a documented-psql-procedure floor (README L121-149) and AC-004 is build-verified. Forward-carry: add automated RLS isolation + empty-read smoke.
