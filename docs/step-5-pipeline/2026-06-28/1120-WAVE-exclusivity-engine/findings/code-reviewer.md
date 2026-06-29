# Code Review — Wave 3 (exclusivity-engine) · Verdict: NEEDS_DISCUSSION
Faithful ADR-003 implementation across 24 ACs; one product-semantics fork blocks a clean APPROVE.

- **CR-001 (MED, _criterion_match_:none, ESCALATE) — same-vertical predicate flags a brand's OWN sibling sites as conflicts.** `0003 conflicts_at:114-124` joins customer + filters `c.vertical=p_vertical` with NO customer_id exclusion; self excluded only by `s.id<>p_exclude_id`. Two sites of the SAME customer are always same-vertical → any sibling pair within max(radius) is flagged "Conflict". For a multi-site brand this is pervasive false positives. BUT whether same-customer pairs should conflict is a product decision ADR-003 never addressed (competitor-only exclusivity vs franchise-territory incl. same-brand). Needs operator/architect call → likely an ADR-003 amendment + `p_customer_id` exclusion param + regression test.
- **CR-002 (LOW, DEFER) — App.computeConflicts fires N findSiteConflicts RPCs per data change** (App.tsx:28-53). Within ADR latitude; route to perf follow-up.
- **CR-003 (LOW, DISMISS) — add/move aborts on conflict-CHECK error** (CustomerForm:214, CustomerList:516). Defensible safety default; AC-024 non-blocking governs disposition not error handling.
- **CR-004 (nit, DISMISS) — add path geocodes twice** (preview + persist); relies on cache-first idempotency, documented in-comment.
- **CR-005 (nit, DISMISS) — Conflict.distance_mi/radius_mi typed number but PostgREST numeric→string**; consumers coerce via Number(). Cosmetic.
Convention compliance: all PASS (seam discipline, migration discipline, security_invoker preserved, additive SiteGeo, W2 a11y reuse, deck.gl pattern). Test coverage strong on DB layer; same-customer case untested (CR-001).
