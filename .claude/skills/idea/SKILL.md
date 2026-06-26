---
name: idea
description: Capture a proactive idea ("I want to build this eventually") into the ideas inbox (docs/step-1-ideas/) as a well-formed dated file (no prefix - ADR-087/089). Distinct from /defer (reactive, parked during work) and from the committed docs/step-1-ideas/backlog/ shelf. Triggers - "/idea", "capture an idea", "someday-maybe".
user_invocable: true
---

# /idea — drop a spark into the ideas inbox

`/idea` captures a proactive idea as one file in `docs/step-1-ideas/`, the ideas inbox (`docs/step-1-ideas/README.md`
is the full convention). A **thin, single-file writer** — no JSON, no state machine, no hook. **Location is status
(ADR-087):** the file lives in the inbox because it is unprocessed; advancing is a `git mv` to the next step
folder; git is the history. No `RAW-` prefix.

> The ideas inbox is an interim dump (zero commitment). It is NOT the `docs/step-1-ideas/backlog/` shelf — that's the
> operator's deliberate "we're doing this, just not now" decision state (ADR-089). `/idea` never writes there.

**Use `/idea` (not `/defer`) when** the spark is proactive — "I want to build/try Z eventually" — and did NOT
come out of active work. If you parked something *during* a task, that's a deferral (`/defer`).

## Usage

- `/idea <spark>` — minimal: writes a dated file into the default `needs-shaping/` bucket.
- `/idea <spark> | bucket=<bucket> area=<theme> value=<one line> size=m notes=<…>` — fill more fields,
  including the disposition bucket.

## Capture-at-bucket (ADR-111)

`/idea` captures INTO a disposition bucket (the six-folder taxonomy, ADR-111). **The AUTHOR picks the
bucket; the tool NEVER infers or auto-classifies it.** The default is `needs-shaping/` (the on-conveyor
default capture target). The valid on-conveyor buckets the author may pick: `needs-shaping/`,
`ready-to-build/`, `blocked-on-dependency/`, `already-done/`. (The off-conveyor lanes/shelves —
`chores/`, `parked/`, `backlog/` — are reached via `/sweep` verdicts, not direct `/idea` capture.)

## On invocation

1. **Parse** the spark (required) + any `bucket` / `area` / `value` / `size` / `source` / `notes` hints.
   - `size` ∈ {xs, s, m, l, xl} (optional gut-feel).
   - `bucket` = the author-picked disposition bucket; **default `needs-shaping`** when the author does not
     pick one. Never infer it from the spark text — if unstated, it is `needs-shaping`, full stop.
2. **Compute the path:** `docs/step-1-ideas/<bucket>/<YYYY-MM-DD>-<slug>.md` (no prefix — ADR-087):
   - `<bucket>` = the author-picked bucket (default `needs-shaping`). `mkdir -p` the bucket dir if absent
     (on-conveyor buckets are created lazily — ADR-111).
   - `<YYYY-MM-DD>` = today (from `date +%F` via Bash — never hardcode).
   - `<slug>` = spark lowercased, non-alphanumerics → `-`, collapsed, trimmed, ~6 words.
   - Uniquify (`-2`, `-3`, …) if a same-name file exists in that bucket; never overwrite.
3. **Write** `docs/step-1-ideas/<bucket>/<date>-<slug>.md` with the README schema:
   ```markdown
   # <spark>
   - **captured:** <YYYY-MM-DD> · **source:** <source, or omit>
   - **area:** <area, or omit>
   - **why / value:** <value, or "<fill>">
   - **rough size:** <size, or omit>
   - **notes:** <notes, or omit>
   ```
   Use Bash + a heredoc (date resolved at write time) or the Write tool with an explicitly-resolved date.
4. **Confirm** the path: "Captured → `docs/step-1-ideas/<bucket>/<date>-<slug>.md`. Shape it later in a
   jam (T13) or promote a ripe one via `/roadmap` (a `git mv` to the next step folder advances it — ADR-087)."

## Guardrails

- **One file, no state.** Do not create or touch any JSON, manifest, or hook.
- **Never overwrite** an existing idea file — uniquify the slug.
- **Author picks the bucket; never infer it.** Default `needs-shaping/` when unstated.
- This skill only ever writes under `docs/step-1-ideas/` (now into a `<bucket>/` subfolder, ADR-111).
