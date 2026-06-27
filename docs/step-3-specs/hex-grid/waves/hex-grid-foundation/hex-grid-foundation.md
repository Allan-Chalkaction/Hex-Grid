# Wave 1 — hex-grid-foundation (Map shell + data foundation)

**Status:** building (live orchestrated run). **Slug:** `hex-grid-foundation` (matches the run slug so
MCL merges this plan with the live run).

Foundation wave: app loads, Supabase + PostGIS + RLS multi-tenancy stands up, app is tenant-scoped.

**Ships:** MapLibre CONUS basemap + deck.gl overlay; Supabase schema (tenant/membership/site/geocode_cache)
with per-table RLS + GIST index + seed; pluggable auth seam; tenant-scoped site fetch.

**Gates:** architect-review (ADR) · db-migration-reviewer (RLS) · code-reviewer · security-auditor.

Full spec: `docs/step-5-pipeline/2026-06-24/0917-PLANNER-hex-grid-map/wave-1-spec.md`.
