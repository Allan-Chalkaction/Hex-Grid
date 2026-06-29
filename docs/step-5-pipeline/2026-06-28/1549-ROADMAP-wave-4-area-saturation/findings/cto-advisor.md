# CTO Advisory — Wave 4 (area-saturation) · Recommendation: SIMPLIFY (GO with trimmed scope) · Confidence: High
The hex-grid payoff; right next wave (direct consumer of the just-merged W3 zones). Two facts collapse risk: (1) the coverage primitive is already shipped (W3 conflicts_at/ST_DWithin effective-radius rule); (2) the full tenant site_geo is already in App client memory → a client-side heatmap needs ZERO backend.

## Fork dispositions (pick-and-document)
- **Coverage metric → overlap-weighted (zone-count density); 0 = open.** Same compute cost as boolean; the gradient is why the view exists; gives prospecting for free.
- **Compute → client-side h3-js** (data already in memory; no backend/migration first cut). Server PostGIS-h3 deferred (ext not guaranteed; reserved as the >10k-site scale tripwire).
- **MVP scope → viewport heatmap + prospecting.** DEFER metro/ZIP aggregation to Wave 5 (W5 owns the ZIP overlay).
- **Per-vertical → yes, vertical selector** (OD-1; saturation only meaningful within a vertical).
- **self_conflict → IGNORE for saturation** (territory coverage is cross-customer; self_conflict gates self-pairwise conflict only). Confirm at spec.

## Risk / debt
Single concentrated risk: per-viewport H3 tessellation cell-count explosion at low zoom → MUST clamp resolution + cap cells + debounce moveend (the named performance gate). Debt: client-side JS duplicates the W3 SQL zone predicate → isolate in ONE shared helper (effectiveRadiusMi / coverage.ts) + parity test; revisit server-side at embed-harden/scale. Effort: Medium (3-5d). New dep: h3-js (H3HexagonLayer re-exported by deck.gl).
