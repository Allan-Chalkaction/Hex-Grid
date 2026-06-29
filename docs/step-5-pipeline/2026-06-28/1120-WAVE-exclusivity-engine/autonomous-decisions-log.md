# Autonomous Decisions Log — Wave 3 (exclusivity-engine)
Disposition basis: ADR-105. Bypass active. Gate verdicts: architect SOUND · security PASS · migration APPROVE · ui PASS_WITH_WARNINGS · spec GAP (tests only) · perf HAS_ISSUES (ADR-anticipated) · code NEEDS_DISCUSSION (1 fork) · a11y FAIL (small fixes).

## 🔺 LOAD-BEARING FORK — SURFACED to operator (not auto-decided)
- **CR-001 — same-customer self-conflict semantics.** The within-vertical predicate flags a brand's OWN sibling sites as conflicts (no customer_id exclusion). Genuinely ambiguous: competitor-only exclusivity (exclude same-customer = bug fix) vs franchise-territory protection (same-brand franchisees SHOULD not overlap = keep). ADR-003 never addressed it. Surfaced for the operator's product call; resolution → conflicts_at predicate change + ADR-003 amendment + regression test if "exclude" chosen.

## ✅ APPLY — mechanical remediation (one pass, pending operator answer on CR-001 to fold in)
- A11Y-001 (HIGH) delete dialog accessible name (useId+h2+aria-labelledby).
- A11Y-002 (MED) delete dialog default focus → Cancel.
- A11Y-003 (MED) pre-seed 3 aria-live regions.
- ui M1 (MED) .confirm-dialog h2 → 1.1rem.
- SA-001 (LOW) isValidLatLng guard in findConflicts.
- MR-001 (LOW) data-loss caveat comment on 0003 reverse path.

## ⏸️ DEFER — logged (forward-carryable; wave-scale is fine)
- PR-001 + PR-002 (perf): dynamic-threshold seq-scan + N-RPC fan-out → single tenant_conflicts() RPC w/ constant GIST pre-filter. ADR-anticipated; high-value but wave-scale (hundreds) acceptable. **Correct spec scale claim "10k"→"hundreds".**
- AC-016/AC-017 (spec GAP): add/move wiring is built + RPC-tested; missing COMPONENT tests need an RTL/jsdom harness (infra expansion, like the W2 harness decision).
- CR-002 (=PR-002), SA-002 (raw error→UI), CR-003/004/005, PR-003/004/005/006, ui L2, architect 3 Lows (incl. move-path is_zone_on fold — latent, no W3 control), eslint-plugin-jsx-a11y (open since W2).
