# Migration Re-Review (iter-2) — 0002 §3 populated-table backfill (CG-T11, 27b6f26)

**Verdict: APPROVE.** Prior MR zero-downtime/empty-table-guard finding **RESOLVED** — the populated-table case is now handled correctly (expand-contract: nullable add → per-tenant 'Unassigned' placeholder → SET NOT NULL) and proven by `tests/migrations/backfill-populated.sql` (2-tenant populated state: full backfill, no cross-tenant leak, idempotency, SET NOT NULL succeeds). Greenfield `db reset` applies cleanly; 24/24 tests pass. Schema-drift now consistent (`SiteGeo.customer_id: string` non-null matches SET NOT NULL).

## Advisory findings (none blocking; all `_criterion_match_: none`)

### MR-005 (Medium) — single-transaction holds ACCESS EXCLUSIVE on `site` for all of §3
The whole §3 runs in one txn, so the lock taken at ADD COLUMN is held through the UPDATE, SET NOT NULL scan, CREATE INDEX, and §§4-5 — a full read+write outage for the migration's duration on a LARGE table. **Acceptable at current scale** (site just post-W1, small; sub-second window). If `site` grows large, the true zero-downtime path is multi-migration: ADD COLUMN nullable → batched backfill in separate txns → `ADD CONSTRAINT CHECK(... IS NOT NULL) NOT VALID` → `VALIDATE CONSTRAINT` → `SET NOT NULL` (PG12+ skips scan) → `CREATE INDEX CONCURRENTLY`. **Disposition: NOTE/accept** — deliberate scale-appropriate choice.

### MR-006 (Low) — `'Unassigned'` is an unprotected magic string
Collides if a tenant has/creates a real customer literally named "Unassigned" (manual-add uses the same `onConflict=(tenant_id,name)`). Impact: cosmetic mis-grouping; no data loss, no cross-tenant leak. **Disposition: DEFER/accept** — harden later with a sentinel (`'(Unassigned)'`) or `is_placeholder` flag.

### MR-007 (Low) — placeholder inherits ON DELETE CASCADE footgun
The auto-created "Unassigned" customer is a normal, user-visible/deletable brand; deleting it cascades to delete all backfilled sites. Mitigated by the native `<dialog>` delete confirm (A11Y-002, states "deletes N sites"). **Disposition: DEFER/accept** — note in known-behaviors.

Validation checklist: all pass (expand-contract order, txn-safe, tenant-scoped, idempotent, completeness-before-NOT-NULL, RLS/place_site interaction clean, FK index present, reversibility note accurate, schema-drift consistent).
