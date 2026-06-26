---
name: graphiti-bulk-ingest
description: Bulk-ingest a glob of docs into the Graphiti memory graph in ONE scripted invocation via graphiti-ingest-doc.py - kills the orchestrator hand-feed-write_fact-per-chunk debt. Content-hash idempotent (re-ingest of unchanged content is a no-op); locked docs (step-6-done) re-ingest only on content change and supersede the prior episode. Triggers - "/graphiti-bulk-ingest", "bulk ingest these docs", "ingest a glob into graphiti".
user_invocable: true
---

# /graphiti-bulk-ingest — scripted bulk ingestion into the Graphiti graph

This is THE single scripted bulk-ingestion door. It calls `core/scripts/graphiti-ingest-doc.py`
over a **glob in ONE invocation** (the script accepts `nargs='+'` paths/globs) instead of looping
`write_fact` per chunk through the orchestrator. The script already section-chunks on `##`, strips
markdown noise verbatim, stamps provenance (`source_path` + heading anchor), is content-hash
idempotent (rides `graphiti_manifest`), and consults the lock-state index (`graphiti_lockstate`)
for skip-vs-supersede on locked docs.

> **Do NOT loop per file in the orchestrator.** Pass the glob through as a single argument set —
> the script expands it (`glob.glob`) and processes every match in one process. Hand-feeding chunks
> is exactly the debt this skill retires (ADR-098, AC-007).

## Usage

- `/graphiti-bulk-ingest '<glob>' --group-id <id>` — ingest every doc matching the glob.
- `/graphiti-bulk-ingest '<glob>' --group-id <id> --dry-run` — scrub + resolve + hash, no write.

## Invocation (the canonical call site — AC-007 wire-to-consumer)

Run the script ONCE with the glob and an **explicit, valid `--group-id`** (fail-closed — there is
NO default group_id; an invalid/derived-outside-projects id is quarantined to `NEEDS_TRIAGE`, never
silently defaulted):

```bash
python3 core/scripts/graphiti-ingest-doc.py '<glob>' --group-id <group-id> [--dry-run] [--min-chars N]
```

Worked examples:

```bash
# ingest all ADRs in one invocation (glob expanded by the script, not a per-file loop)
python3 core/scripts/graphiti-ingest-doc.py 'docs/decisions/ADR-*.md' --group-id claude-infra-adrs

# ingest a whole spec folder, dry-run first to preview the chunk/skip/written accounting
python3 core/scripts/graphiti-ingest-doc.py 'docs/step-3-specs/<epic>/**/*.md' --group-id <epic-group> --dry-run
```

## Behavior

- **One invocation, many files.** The glob is passed through; the script processes all matches in a
  single process. Never loop per file in the orchestrator.
- **Idempotent.** Re-running on unchanged content is a no-op — every chunk reports `skip` and the
  summary line shows `written=0` (the `(content_hash, group_id)` manifest gate + the lock-state
  `skip` decision). Exit code 0 on a clean run, 1 if any chunk failed.
- **Locked-doc supersede.** A doc under `docs/step-6-done/**` (locked) re-ingests only on content
  change; when its content changed, the new content has a new `content_hash`, so `write_fact` writes a
  **fresh episode** and Graphiti's bi-temporal model invalidates the contradicted prior facts —
  whole-doc supersession via temporal invalidation, not a manifest `update_uuid` rewrite (a changed
  hash never hits the manifest UPDATE arm). No line-level-delta machinery (deferred to Round-3 per ADR-097).
- **Reference-only output.** Every line carries title / heading / char-count / `source_path` —
  **never a document body** (ADR-074 content-free telemetry, ADR-076 dead-letter body-exclusion).

## Guardrails

- **Explicit `--group-id` required.** The script's `--group-id` is `required=True`. This skill MUST
  pass a real group id; it MUST NOT inject a hardcoded default that bypasses fail-closed. An invalid
  id quarantines (`NEEDS_TRIAGE` stderr line, references only) rather than writing to a wrong group.
- **Quote the glob.** Pass the glob single-quoted so the script (not the shell) expands it and the
  `nargs='+'` one-invocation property holds.
- **No body ever leaves the process.** Do not add any diagnostic that prints or records a document
  body — the bulk path is reference-only by contract (`security-auditor` gates this).
