# Security Audit — Wave 2 (customers-geocoding)

**Verdict: PASS_WITH_CONDITIONS** · `main..HEAD` (CG-T1..CG-T8). **No Critical, no High.** No tenant-bleed, auth bypass, injection, or secret exposure. RLS model, security_invoker view/RPC, pinned search_path, tightened EXECUTE grants, SSRF prevention (encodeURIComponent into fixed Census host), "never trust client coords" all correct.

## SA-001 — Edge Function tolerates missing/empty JWT; anon-rejection relies solely on platform default — MEDIUM · `_criterion_match_: none` · APPLY
`geocode/index.ts:147-155`; `config.toml` has no `[functions.geocode]` block. `authHeader = ... ?? ''` tolerated; only the platform default `verify_jwt=true` prevents anon invoke. If ever deployed `--no-verify-jwt`, becomes an open anon geocode proxy (Census quota burn on project IP).
**Remediation:** add `[functions.geocode] verify_jwt = true` to config.toml AND reject empty auth in code (`if (!authHeader) return 401`). Address before/at merge.

## SA-002 — Cross-tenant cache poisoning via shared `geocode_cache` — LOW · `_criterion_match_: none` · DEFER
`0001:142-149` policies; `geocode_cache` deliberately tenant-shared (ADR-001). Any authed user can write any `(hash,lat,lng)` via PostgREST; tenant B consumes poisoned mapping. Integrity-only, pre-existing W1 design — but W2 is first to persist sites from cached values, so impact now real.
**Remediation (discretion):** document residual risk, or move cache writes to service_role in the function + revoke broad insert from authenticated. Coordinate with ADR-001 owner.

## SA-003 — No rate limiting on geocode function — LOW · `_criterion_match_: none` · DEFER
`geocode/index.ts:137-279`. Per-request caps good (MAX_BATCH 100, CONCURRENCY 4) but no per-user/IP rate cap → sustained Census traffic risks 429 on shared IP.
**Remediation:** lightweight per-`auth.uid()` rate limit.

## SA-004 — CSV formula injection in downloadable error report — LOW · `_criterion_match_: none` · APPLY (quick)
`csvImport.ts:251-267`. `csvCell` RFC-4180-quotes but does not neutralize `=`/`+`/`-`/`@` formula triggers; opening report in Excel can execute. Largely self-inflicted (client-side, own import).
**Remediation:** prefix leading `=+-@`/tab/CR with `'` before quoting.

## SA-005 — `updateSiteLocation` EWKT interpolation has no internal coord validation — LOW (defense-in-depth) · `_criterion_match_: none` · APPLY (quick)
`customers.ts:114-127`. NOT SQL-injectable (PostgREST bound param + PostGIS EWKT parse). Current callers safe; exported helper performs no internal finite/WGS84-range check → a future caller could store malformed geometry (own tenant).
**Remediation:** guard `Number.isFinite` + WGS84 ranges inside the helper.

## SA-006 — `geocode_cache` upsert can fail under RLS on concurrent races — INFO · reliability not security
`geocode/index.ts:248-253`; cache has select+insert policies but no UPDATE policy → `ON CONFLICT DO UPDATE` denied on concurrent same-hash insert. Use DO NOTHING / ignoreDuplicates.

## SA-007 — CORS `*` on geocode function — INFO · acceptable (bearer-token auth, no credentials).

OWASP Top 10:2025: all Pass except SA-001 (A05/A07 defense-in-depth), SA-002 (A08 by design), SA-003 (A04). Secrets scan clean (anon key public by design; no service_role anywhere).
