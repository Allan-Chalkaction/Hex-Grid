# Live RLS verification — Wave 1 (hex-grid-foundation)

**Run:** 2026-06-27 · **Operator:** Allan · **Context:** closes the spec-conformance DRIFT
(the one forward-carried QA action item in `autonomous-decisions-log.md`).

The spec-conformance agent returned DRIFT only because, as a read-only agent, it could not
stand up a live DB to prove tenant RLS isolation end-to-end (AC-001/002/003/006/008 were
INCONCLUSIVE on live runtime, CONFORMS by source). This run executed that live test.

## Method

`supabase db reset` (rebuild schema from `0001_init_postgis_schema.sql` + `seed.sql`), then a
second test-only tenant + user were seeded as superuser, and the RLS policies were exercised by
dropping to the `authenticated` role with a simulated `request.jwt.claims->sub` (== `auth.uid()`)
per tenant, plus the `anon` role for the unauthenticated path.

- Tenant A / user A: seeded (`...a1` / `...d1`), 2 sites
- Tenant B / user B: test-only (`...a2` / `...d2`), 2 sites
- 1 shared `geocode_cache` row

## Results — all pass

| # | Test | Expected | Result |
|---|------|----------|--------|
| 1 | User A reads `site` / `tenant` / `membership` | only tenant-A rows | ✅ 2 A-sites, Dev Tenant only, own membership only |
| 2 | User B reads `site` / `tenant` | only tenant-B rows | ✅ 2 B-sites, Tenant B only |
| 3 | Authenticated role, empty JWT (no `sub`) | 0 rows everywhere | ✅ 0 / 0 / 0 |
| 4 | `anon` role (PostgREST unauthenticated) | 0 rows everywhere | ✅ 0 / 0 / 0 |
| 5 | `geocode_cache` (deliberately shared) | both tenants see the row | ✅ A=1, B=1 |
| 6 | User A inserts a tenant-B `site` | blocked by `WITH CHECK` | ✅ `new row violates row-level security policy for table "site"` |

## Conclusion

The RLS chain is verified live: per-tenant read isolation, deliberate `geocode_cache` sharing,
cross-tenant write prevention, and zero-leak on unauthenticated/empty contexts. The recursion-safe
`auth_tenant_ids()` SECURITY DEFINER helper behaves as designed (no policy recursion observed).

**spec-conformance DRIFT → CONFORMS.** No code change required.

> Test data note: a second tenant/user (`...a2` / `...d2`) now lives in the **local** dev DB from
> this test. A future `supabase db reset` clears it back to the single seeded dev tenant. No
> committed artifact or remote DB is affected.
