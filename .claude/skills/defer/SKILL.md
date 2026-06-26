---
name: defer
description: Drop a passed-over item into the ideas inbox (docs/step-1-ideas/) as a well-formed DEFER- file (ADR-087/089 - the deferrals silo merged into the inbox). Use when work is parked and must land somewhere durable and triageable. Triggers - "/defer", "defer this", "log a deferral", "drop this for later".
user_invocable: true
---

# /defer — write a deferral to the ideas inbox

`/defer` captures a passed-over item as one `DEFER-` file in `docs/step-1-ideas/`, the durable ideas inbox
(`docs/step-1-ideas/README.md` is the full convention; ADR-087 merged the old `docs/deferrals/` silo into it,
ADR-089 renamed it from `step-1-backlog`).
It is a **thin, single-file writer** — no JSON, no state machine, no hook. **Location is status (ADR-087):**
the file lives in the inbox because it is unprocessed; triage advances it with a `git mv`; git is the history.
The `DEFER-` prefix is the one surviving tag — it marks the file as carrying a source-run pointer.

> The ideas inbox is an interim dump. It is NOT the committed `docs/step-1-ideas/backlog/` shelf (ADR-089) — `/sweep`
> routes a triaged deferral onto a shelf with the operator's go; `/defer` only ever writes the inbox.

## Usage

- `/defer <title>` — minimal: writes a `DEFER-` file with today's date and a slug from the title.
- `/defer --infra <title>` — set `target: claude-infra` so the note is **harvested upstream** into the
  claude-infra substrate inbox (T17). Use this in a **consumer repo** when the deferral is a claude-infra
  defect/friction, not a local one. Without `--infra`, `target:` defaults to `this-repo`.
- `/defer <title> | bucket=<bucket> severity=med suggested=fix-batch why=<one line> requires=<condition>`
  — fill more fields, including the disposition bucket.

(Any unspecified field is left as a sensible default / a `<fill>` placeholder for the human to complete.)

## Capture-at-bucket (ADR-111)

`/defer` captures INTO a disposition bucket (the six-folder taxonomy, ADR-111). **The AUTHOR picks the
bucket; the tool NEVER infers or auto-classifies it.** The default is `needs-shaping/` (the on-conveyor
default capture target). The `DEFER-` prefix is preserved on the filename (it marks the deferral kind +
source pointer); the prefix and the bucket are orthogonal — a deferral lands as
`docs/step-1-ideas/<bucket>/DEFER-<date>-<slug>.md`.

## On invocation

1. **Parse** the title (required) and any `bucket` / `severity` / `target` / `why` / `requires` hints from the args.
   - `severity` ∈ {low, med, high} (default `med`).
   - `target` (default `fix-batch`).
   - `bucket` = the author-picked disposition bucket; **default `needs-shaping`** when the author does not
     pick one. Never infer it from the title — if unstated, it is `needs-shaping`, full stop.
2. **Compute the path:** `docs/step-1-ideas/<bucket>/DEFER-<YYYY-MM-DD>-<slug>.md`, where:
   - `<bucket>` = the author-picked bucket (default `needs-shaping`). `mkdir -p` the bucket dir if absent
     (on-conveyor buckets are created lazily — ADR-111).
   - `<YYYY-MM-DD>` = today (get it from `date +%F` via Bash — do NOT hardcode).
   - `<slug>` = the title lowercased, non-alphanumerics → `-`, collapsed, trimmed, capped ~6 words.
   - If a same-name file exists in that bucket, append `-2`, `-3`, … (don't overwrite).
3. **Determine `source`** from context where possible (best-effort, never block):
   - In an active run → the run-folder path (`docs/step-5-pipeline/.../<slug>/`).
   - Else if a relevant `file:line` or commit is known → use it.
   - Else → `cwd` (from `pwd`) + a short note. If genuinely undeterminable in a headless/fleet context, write
     `source: <unknown — set on triage>` rather than guessing wrong.
4. **Write** `docs/step-1-ideas/<bucket>/DEFER-<date>-<slug>.md` with the README schema:
   ```markdown
   # <title>
   - **deferred:** <YYYY-MM-DD> · **source:** <resolved source>
   - **severity:** <severity>
   - **target:** <this-repo | claude-infra>   # claude-infra when --infra was passed, else this-repo
   - **why deferred:** <why, or "<fill>">
   - **suggested target:** <suggested>
   - **requires:** <requires, or omit if not given>
   ```
   Use Bash + a heredoc to write it (so the date is resolved at write time), or the Write tool with an
   explicitly-resolved date — never a hardcoded date.
5. **Confirm** the path written: "Deferred → `docs/step-1-ideas/<bucket>/DEFER-<date>-<slug>.md`. Triage it
   later on `/sweep` — advancing is a `git mv` to the next step folder; a resolved one moves to `step-6-done/` (ADR-087)."

## Guardrails

- **One file, no state.** Do not create or touch any JSON, manifest, or hook.
- **Never overwrite** an existing deferral file — uniquify the slug.
- **Author picks the bucket; never infer it.** Default `needs-shaping/` when unstated.
- **Default-deny on a bad source** — write `<unknown — set on triage>` rather than a fabricated path.
- This skill only ever writes under `docs/step-1-ideas/` (now into a `<bucket>/` subfolder, ADR-111).
