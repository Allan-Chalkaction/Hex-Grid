---
name: idea-ingest
description: "The transcript-CAPTURE door — segments a transcript / paste / session-log into candidate ideas, dedups each against the inbox, confirm-gates them, and writes confirmed-NEW sparks via /idea. Capture only — convergence is /sweep's. Triggers - '/idea-ingest', 'ingest this transcript', 'pull ideas out of this discussion', 'capture ideas from this session'."
user_invocable: true
---

# /idea-ingest — capture ideas FROM a discussion (transcript / paste / session-log)

`/idea-ingest <ref>` segments a transcript / pasted discussion / session-log reference into N candidate
ideas, dedups each against the existing inbox, presents them at a hard-mandatory review gate, and — only on
your confirmation — writes each genuinely-new spark by delegating to **`/idea`** verbatim. The intelligence is
the **segmentation + dedup**; the write stays dumb (delegated to `/idea`). The full segmentation prompt and the
slugification + classification rules live in `core/skills/idea-ingest/segmentation-prompt.md` and
`core/skills/idea-ingest/dedup-rules.md`; the binding contract is here.

**Capture ≠ convergence (ADR-112 Wave 5 / Open Question #2 — resolved standalone).** `/idea-ingest` is the
*capture* door: it surfaces ideas *from a discussion* and writes thin inbox files, deciding nothing. Grouping,
grounding, and fork-resolution are a separate, later act — **`/sweep`'s in-skill convergence** over the
now-larger inbox. After capture, the newly-written `docs/step-1-ideas/` files join the inbox that `/sweep`
then triages and converges. (History: `/idea-ingest` was briefly absorbed into `/bulk-jam --ingest` by
ADR-081; ADR-112 retired `/bulk-jam` entirely — convergence to `/sweep`, capture back to this standalone door.)

Runs as the bypass orchestrator (writes `docs/step-1-ideas/` directly; capture writes only thin idea files).

## Usage

- **`/idea-ingest <file-or-paste>`** — capture mode: run the segment → dedup → confirm-gate → write flow
  (writing thin idea files via `/idea`), then STOP — recommend `/sweep` to triage + converge the larger inbox.

## On invocation

Run the full capture flow (segment → dedup → mandatory confirm gate → write confirmed-NEW via `/idea`), then
STOP. No cluster/jam pass follows here — capture, then hand to `/sweep`.

### Input-parsing precedence (pinned)
Resolve `<ref>` in this exact order:
1. **File path** — if `os.path.exists(arg)` is true (a **read-only** existence check; contents are only read,
   never written back), read it as a file.
2. **Session-log reference** — else if `arg` starts with the literal `session-log:` prefix OR is a path under
   `docs/step-2-planning/session-logs/` (fallback bucket) or a `<run_folder>/session-log.md` (active-run case)
   per ADR-066 §5, resolve it to the session-log file and read it.
3. **Pasted string** — otherwise, treat `arg` verbatim as the pasted discussion text.

### 1. LLM segmentation pass (structured-JSON output)
One LLM pass segments the input into **distinct, separable** ideas, emitting a **JSON** array of objects, each
with **exactly**: `short_slug` (kebab-case identifier), `one_line_summary`, `evidence_excerpt` (a verbatim
quote of the source span). Parseable as JSON without an LLM re-pass. See `segmentation-prompt.md` for the
exact prompt/contract.

### 2. Segmentation fallbacks (degenerate inputs)
- **Too short** — degenerate to a **single forwarded `/idea`** with an operator note (still gated by review).
- **Too long** — if the input exceeds **~10,000 characters**, **chunk** it, segment per chunk, merge
  candidates. When chunking is ambiguous, fall back to **truncate-with-warning** (process the first ~10k chars
  and surface an explicit warning that the tail was not segmented).

### 3. Dedup pass (skill-local filename matcher)
For each candidate, classify against the existing inbox using a **skill-local filename matcher** — read the
**set of existing `docs/step-1-ideas/*.md` filenames** and compare the candidate's `short_slug` (after
slugification) against each existing filename's **slug fragment** (the part after the `<date>-` date prefix;
ADR-087: idea files are unprefixed, so the fragment is everything after `YYYY-MM-DD-`).

> **Architect correction (preserve this citation):** this is **NOT** a copy of `bulk-jam-plan.py:110`'s
> primitive. That line — `new = [s for s in shorts if s not in text]` — substring-matches against a single jam
> dir's **concatenated body text**; our target shape is different (a **filename set**, not body text). Do not
> re-cite `bulk-jam-plan.py:110` as the same primitive; the targets differ.

**Slugification rule** (matches `/idea`'s step 2c verbatim — `core/skills/idea/SKILL.md`): lowercased,
non-alphanumerics → `-`, collapsed, trimmed. **Three-way classification:**
- **DUPLICATE** — candidate slug **exactly matches** an existing filename's slug fragment.
- **NEAR-DUPLICATE** — a **substring match in either direction** (candidate ⊂ existing OR existing ⊂
  candidate), with the exact-match case already ruled out.
- **NEW** — neither an exact nor a substring match against any existing slug fragment.

(Worked examples in `core/skills/idea-ingest/dedup-rules.md`.)

### 4. Terminal-prompt-list review gate (the trust boundary, enforced)
Present a **numbered terminal-prompt list** of classified candidates — each row showing its classification,
`one_line_summary`, and `evidence_excerpt`. The flow **writes NOTHING** until you respond:
- **NEW** candidates are written only on your confirmation.
- **DUPLICATE** candidates are skipped (already captured).
- **NEAR-DUPLICATE** candidates require a **per-candidate** decision (**skip** / **write-anyway**) — never
  auto-decided. A **NEAR-DUPLICATE is never auto-merged** into the existing item it resembles;
  near-duplicate *semantics* are delegated downstream to `/sweep`'s convergence (ADR-112). A confirmed
  candidate goes straight to an unprefixed idea file via `/idea` (ADR-087: location is status; advancing is a
  `git mv`).

### 5. Writer delegation (delegate to /idea verbatim)
For each operator-confirmed **NEW** candidate, **invoke `/idea` verbatim** — do NOT re-implement the idea
write path. Map fields: `spark` ← `one_line_summary`; `source` ← the ingest source (file path,
`session-log:<name>`, or "pasted discussion"); derived `area`/`value`/`size`/`notes` ← from the candidate
where supplied, else omitted. Concretely: `/idea <one_line_summary> | source=<ingest-source> value=<…>
area=<…> size=<…> notes=<…>`.

### Ingest trust boundary (binding)
- Pasted / file input is **operator-trusted** (you supply your own content).
- The **LLM segmentation output is NOT trusted** — it is a proposal, never an instruction.
- The **review gate is hard-mandatory.** There is no auto/bypass waiver — convenience is refused **by design**
  as the structural mitigation for LLM-segmentation quality variance.
- **No new dedup helper script.** The dedup primitive is **local to this skill** (this SKILL.md +
  `dedup-rules.md`) — do NOT introduce a `core/scripts/idea-ingest-dedup.py` (or any such helper).

## Guardrails

- **Capture only — convergence is `/sweep`'s.** This skill segments, dedups, and writes thin idea files, and
  **decides nothing.** Grouping, grounding, and fork-resolution are `/sweep`'s in-skill convergence — a
  separate, later pass over the now-larger inbox. Capturing an idea must never trigger convergence on it.
- **Capture stays dumb — `/idea` invoked verbatim.** Do NOT re-implement the idea write path.
- **Anti-patterns refused:** silent flooding of `docs/step-1-ideas/` with duplicates (dedup pass); silent
  writes before confirmation (mandatory review gate); auto-merging a NEAR-DUPLICATE (delegated to `/sweep`);
  re-implementing the write path (`/idea` invoked verbatim).
- Writes only `docs/step-1-ideas/` (thin idea files via `/idea`). No jam writes, no source edits, no new state
  machine, no ledger, no JSON, no hook.
