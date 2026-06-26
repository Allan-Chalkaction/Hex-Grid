# graphiti-eval-set.jsonl — AUTHORED (W1T-T7), operator-ratify pending

**Status:** AUTHORED by AI (Claude), grounded by repo view (verify-by-view against CLAUDE.md, the ADR
index, and this session's Wave 0/1 findings). 12 records, `expected_facts` populated with distinctive
verifiable substrings. `judged_by` honestly labels the provenance (AI-drafted) rather than fabricating an
operator signature.

**Why AI-authored (operator asked):** the W1T-T7 contract defaulted `expected_facts` to operator-authored
to avoid a model grading recall against its own subjective notion of relevance. These 12 contexts are
**objective, verifiable repo facts** (ADR numbers, pins, conventions), not preferences — so AI authorship
grounded in source is appropriate and far better than leaving them empty. The operator should **ratify**
(skim + adjust any substring, replace `judged_by` with their own name if they want a human sign-off).

## AC-011 — satisfied
- `wc -l` ∈ [10,20]: 12 ✓ · `grep -c '"_comment"'`: 0 ✓ · throwaway `judged_by`: 0 ✓
- all 12 parse with the 5 keys ✓ · `expected_facts` non-empty (all 12) ✓
- `judged_by` = AI-drafted label (operator to ratify) — NOT a fabricated human name.

## T8-A re-baseline is BLOCKED on real data (empirically confirmed 2026-06-09)
`python3 core/scripts/graphiti-eval.py --fixture <this>` → **overall_recall = 0.0, all 12 missed.** The
`claude-infra-v2` group holds **none** of these facts because capture has run **dry-run** (the
`graphiti-capture-live` flag was never set), so nothing was ever written to the graph. T8-A's AC requires
a NON-degenerate baseline (≥1 recall@30 strictly between 0 and 1) — impossible against an empty group.

**So the real ordering is:** (1) flip capture live (T8-B) + run sessions so facts accumulate, OR seed
these facts deliberately via `graphiti-write` into the `claude-infra-v2` group; THEN (2) re-baseline
(T8-A) produces meaningful numbers. The eval set is correct and ready; it's the graph that's empty.
