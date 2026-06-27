# Migration verification scripts

Manual, dev-only SQL checks for behavior that the application test suite (`npm test`)
cannot reach because it runs against the already-migrated schema.

## `backfill-populated.sql`

Proves migration `0002` section 3 (the **expand-contract `site.customer_id` backfill**)
is correct on a **populated** `site` table — the production case W1 leaves behind, which
the migration's original empty-table guard aborted on.

Because `0002` is unmerged it can only ever be *applied* (never un-applied) to local dev,
so we cannot down-migrate to re-run section 3. The script instead works inside a single
transaction that **always rolls back**: it reconstructs the W1 state (a `site` table with
no `customer_id`, carrying rows across two tenants), runs the exact new section-3
DDL + backfill, asserts correctness, then `ROLLBACK`s — leaving the real schema untouched.

Assertions:
- **(a)** every site ends with a non-null `customer_id`;
- **(b)** each site maps to its own tenant's `'Unassigned'` placeholder (no cross-tenant leak);
- **(c)** the placeholder insert is idempotent via the `unique (tenant_id, name)` key.

### Run

A local Supabase must be running (`supabase start`). Then:

```bash
docker exec -i supabase_db_hex-grid psql -U postgres -v ON_ERROR_STOP=1 \
  < tests/migrations/backfill-populated.sql
```

A clean run prints the `OK (...)` notices and ends with `ROLLBACK`. Any failed assertion
raises an exception; with `ON_ERROR_STOP=1` the command exits non-zero.

> The container name `supabase_db_hex-grid` is the local Supabase Postgres container for
> this project (`docker ps` to confirm).
