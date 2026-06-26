# Artifact Surfacing — `SendUserFile` convention for notable artifacts

**BEHAVIORAL** (orchestrator-side) — paired with **ADR-080 D1** (the deterministic
move), **ADR-068** (the persist input-source extension that makes artifacts reliably land),
and **ADR-050** (its capture sibling).

`persist-run-artifacts.py` computes the **`notable: [...]`** array — the subset of its
`written` paths that are notable artifacts (jam READMEs; `docs/step-3-specs/**` roadmap/wave
specs + prompts; `docs/decisions/ADR-*.md`; end-of-run `run-log.md`; `locked.md`), with the
scratch exclusions (`findings/*`, manifests, fixtures, `docs/step-1-ideas/*` — the ideas inbox, ADR-087/089;
plus the legacy `docs/deferrals/OPEN-*`) enforced by
construction. **The source of truth for the allowlist is
`persist-run-artifacts.py::compute_notable` (ADR-080 D1) — not this file.** The orchestrator's
residual duty: after the persist script returns, `SendUserFile` every entry in `notable`
(one call per artifact, in order). The script still writes; the orchestrator still surfaces
(ADR-039 contract 2 unchanged).

## Cross-references

- **ADR-080 D1** — the allowlist-as-code move; `compute_notable` is the source of truth.
- **ADR-050** — capture sibling (off-engine `@`-agent reports land on disk). Now a hook arm
  (ADR-080 D2); see `core/hooks/sync-artifacts-post-agent.sh`.
- **ADR-068** — native-journal fallback in `persist-run-artifacts.py` (makes artifacts reliably land).
- **`core/rules/rules-artifact-sync.md`** — the run-artifact folder layout this convention surfaces from.
