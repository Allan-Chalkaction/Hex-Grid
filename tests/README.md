# Tests (CG-T10)

The project's first test harness (vitest). Two classes of test:

- `tests/unit/**` — pure logic, **no DB, no network**. Always run.
- `tests/integration/**` — run against the **local Supabase stack**. They
  self-skip (`describe.skipIf(!hasDb)`) when the env keys are absent, so
  `npm test` never hard-fails in a no-DB environment.

## Run the suite

Unit tests only (no DB needed):

```bash
npm test
```

Full suite **including** the live integration tests — export the local Supabase
keys into the env first (the integration helpers read `process.env`):

```bash
# Export only the three keys we need; the bare `supabase status -o env` output
# can be polluted by an informational "Stopped services:" line, so grep + eval.
set -a; eval "$(supabase status -o env 2>/dev/null \
  | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY)=')"; set +a
npm test
```

`API_URL`, `ANON_KEY`, `SERVICE_ROLE_KEY` are the well-known **local-dev demo
keys** — safe to export in your shell for a local test run, but they are NEVER
hardcoded in committed source. The integration tests read them from
`process.env`; the dummy `VITE_*` values the app singleton needs at import time
live in `vitest.config.ts` (`test.env`) and are non-functional placeholders.

## What's covered

| Test | AC | Notes |
|------|----|-------|
| `unit/customers.test.ts` | CR-002 / SA-005 | `isValidLatLng` bounds + the empty-string two-layer guard |
| `unit/csvImport.test.ts` | SA-004 / AC-009/013/017 | `csvCell` injection+RFC-4180; `importCsv` dedup / missing-column / unknown-column with an injected fake geocoder |
| `integration/rls-isolation.test.ts` | **AC-005** | two-tenant RLS isolation; anon sees zero |
| `integration/ewkt-roundtrip.test.ts` | **AC-021 / CR-003** | EWKT INSERT (place_site RPC) + UPDATE (PostgREST `.update()`) round-trip through `site_geo` |

### Not covered (deliberate)

- **AC-016 (geocode cache)** — populating `geocode_cache` is the **Edge Function's**
  job (`supabase/functions/geocode`). The local stack's `edge_runtime` service is
  **stopped** in this environment (the function is not served), and exercising it
  would also need Census network access. Out of low-cost scope for this harness.
- **React components** — no jsdom; UI rendering is intentionally not tested here.
  `outcomeLabel` (CustomerImport.tsx) was left unexported to avoid a react-refresh
  lint warning and pulling React into node tests.

## Notes

- Node 24 has global `File`/`Blob` but no `FileReader`; `tests/setup/env.ts`
  installs a minimal async `FileReader` polyfill so papaparse can parse a `File`
  under node. Test-only — no app runtime dependency.
- Integration tests create confirmed auth users + seed/teardown rows per run;
  teardown is robust (deletes tenants → cascades customer/site/membership, plus
  the auth users) so reruns stay clean.
