# Spec-Conformance — Wave 3 · Verdict: GAP · 22/24 CONFORMS, coverage complete (no AC dropped)
22 ACs CONFORMS. Two GAPs are missing TESTS on built-and-working behavior, not missing behavior:
- **AC-016 (MED, DEFER) — add-flow findConflicts-before-persist + dialog-gating: built (CustomerForm:174-212) but no component test.** Project ships zero *.test.tsx / RTL harness; the 36/36 vitest suite is DB-layer only. Grep conjunct passes; test conjunct absent.
- **AC-017 (MED, DEFER) — move-flow self-excluded findConflicts-before-updateSiteLocation + "Cancel writes nothing": built (CustomerList:499-514), RPC self-exclusion tested, component move-flow test absent.**
Notes: AC-002 backfill tested via tests/migrations/vertical-backfill.sql (docker exec, out-of-band, project convention). AC-018 "eight options" is a spec miscount — locked set is 7 (Off+6); implementation matches the enumerated set.
