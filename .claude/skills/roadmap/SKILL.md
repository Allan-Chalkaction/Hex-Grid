---
name: roadmap
description: Start an iterative planning session — epic→wave-roadmap (Phase E) or wave→spec+prompts (Phase W). Runs an advisor funnel autonomously to a finalized artifact (--attended halts per round for tuning). A first-class entry mode alongside /nimble, /orchestrated, /chain, /bypass, /planner.
user_invocable: true
---

# Roadmap Mode — iterative epic & wave planning

`/roadmap` codifies the working front-half planning loop: turning an epic intent into a **wave roadmap**, then turning each wave entry into a buildable **wave spec + prompts**. It is advisor-only (orchestrator + advisor agents, no implementers) and — as of ADR-054 — **autonomous-to-completion by default**: it runs the advisor funnel straight through, self-QAs via the planner enrichment, and finalizes the canonical artifact in one pass, exactly like `/orchestrated` runs straight to a built wave. Use `--attended` when you want the legacy round-by-round tuning halts.

This is one of the ways to start work:

- `/nimble` — light engine preset for quick / single-feature work
- `/orchestrated <slug>` — heavy engine preset; autonomous wave execution (builds a planned wave)
- `/chain a,b,c` — custom ordered agent chain on the engine
- `/bypass` — just chat; no protocol, no run folder
- `/planner [slug]` — repo-aware planning partner (advisor-only)
- `/roadmap` — iterative planning (this skill) — the input to `/orchestrated`

**Contract:** `core/rules/rules-roadmap-mode.md`. **Rationale:** `docs/decisions/ADR-030-roadmap-mode.md`. **Methodology source-of-truth:** `docs/handbook/wave-4-planning-narrative.md`.

> As of **ADR-054**, `/roadmap` runs **autonomously to completion** like every other v2 mode (ADR-029) — a single forward pass (no human-tuning rounds), self-QA'd by the planner enrichment, finalized to the canonical artifact. The legacy round-boundary-halt behavior (ADR-030) is preserved behind `--attended`. *Within* the pass it is autonomous (no mid-funnel pickers); the ONLY stops are the ADR-018 interrupts (1/2/3/5). See the rules file.

## Usage

- `/roadmap` — **Phase E** (epic → wave roadmap), **autonomous**: ingests jam-seeded intent (or an epic intent paste), runs the funnel, finalizes `docs/step-3-specs/<epic-slug>/roadmap.md`. Errors if a feasibility claim is detected in a paste; halts to ask which epic if multiple roadmaps already exist.
- `/roadmap wave-N` — **Phase W** (wave N → spec + prompts), **autonomous**. Requires an existing wave roadmap.
- `/roadmap <epic-slug> wave-N` — Phase W, disambiguated when multiple roadmaps exist.
- `/roadmap --attended …` — opt into the legacy round-by-round tuning loop (halts at each round boundary for operator lock/tune). Any of the forms above accepts the flag.
- `/roadmap <slug>` — **resume** an in-progress roadmap run (any session, including fresh).
- `/roadmap off` — end the session (removes the state file).

## State-awareness routing (do this first, every invocation)

```
parse args
  │
  ├─ "off"          → run "End" below.
  │
  ├─ no wave arg
  │    ├─ an in-progress ${SESSION_ID}-*.json roadmap state file already exists  → RESUME (read its run_dir).
  │    ├─ a ROADMAP run folder exists for the named/implied epic                  → present it; ask "tune this roadmap, or name a wave to plan?"
  │    ├─ a jam exists at docs/step-2-planning/jam-<implied-slug>/                        → Phase E, SEEDED FROM THE JAM (step 1a — no paste demanded).
  │    └─ otherwise                                                               → Phase E (new epic; intake paste required — step 1b).
  │
  └─ wave arg (e.g. "wave-4")
       ├─ no wave roadmap exists anywhere     → HALT: "Cannot plan a wave without a roadmap. Run `/roadmap` (Phase E) first."
       ├─ exactly one roadmap exists          → Phase W against it.
       └─ multiple roadmaps exist             → HALT: "Which epic does wave-4 belong to? Re-run as `/roadmap <epic-slug> wave-4`."  (session-start halt, not a mid-round picker)
```

Discover existing roadmaps by globbing `docs/step-3-specs/*/roadmap.md` (locked outputs — each lives inside its epic's spec folder `docs/step-3-specs/<epic-slug>/`) and `docs/step-5-pipeline/*/*-ROADMAP-epic-*/` (in-progress runs). *(A consumer repo may still carry a legacy `docs/step-3-specs/roadmaps/*.md`; the discovery also globs that path defensively so existing artifacts keep working. claude-infra's own roadmaps use the `docs/step-3-specs/<epic-slug>/roadmap.md` shape — ADR-051 §7.)*

Also glob `docs/step-2-planning/jam-*/` for a jam matching the implied epic slug — a converged jam brief is the **preferred intent source** for Phase E (the jam→roadmap intent handoff, ADR-051 §8). A jam whose brief is operator-shaped is already the epic intent; Phase E seeds from it rather than demanding a re-paste of work the jam already holds.

## On Invocation

### Phase E — epic → wave roadmap

1. **Source the intent — jam-first, then paste.** Two paths; take (1a) whenever a jam exists.

   **1a. Jam-seeded (preferred — the jam→roadmap intent handoff, ADR-051 §8; SCRIPT-CAPTURED as of ADR-065).** Glob `docs/step-2-planning/jam-<epic-slug>/` (and a fuzzy match on the topic words). **If a jam exists, the ENGINE captures intent from it** — you do NOT author the intent doc. Resolve the jam slug, announce which jam you're using — *"Seeding intent from `docs/step-2-planning/jam-<slug>/`. Say `paste instead` to override, or name a different jam."* — and dispatch the engine with `intentSource: "capture"` + `jamSlug` (§ "Engine dispatch"). The engine's `intent-capture` step dispatches `pm-spec` to read the jam (`README.md` → `index.md` fallback + every `source/*.md`) and ground it by-view; the orchestrator persists the captured `intent.md` from the return (ADR-039 contract 2). The feasibility-claim guard is satisfied by the engine's verify-by-view at capture time. Do NOT write `round-0-intent.md` and do NOT demand a paste when a jam exists. *(Caveat: if the brief is a thin stub rather than a converged shaping brief, flag at round 1 like a thin Phase-W skeleton — proceed best-effort, do not silently treat a stub as a full intent.)*

   **1b. Paste (no jam matched — back-compat escape hatch).** The operator should have pasted an epic intent in the §"Intake template" shape. **The `[CC to verify]` feasibility guard applies to THIS paste path only:** if any feasibility claim is present (a sentence asserting how existing code is structured — specific files, channels, functions, tables, or shipped capabilities), HALT and ask the operator to re-author that sentence as a `[CC to verify]` deferral. This is a session-start halt, before any round runs — it stops claude.ai's code-blindness from contaminating the roadmap. Do NOT proceed against a paste carrying feasibility claims. Dispatch the engine with `intentSource: "curated"` and the verbatim paste as `intent` (§ "Engine dispatch") — the curated short-circuit pays zero capture dispatches.

   > **Curate-once + pass-by-path + bounded-read (ADR-115 D4 / AC-014; ADR-082/083 token discipline).** The
   > advisory funnel hands advisors a jam/spec **PATH**, not the full inlined jam content. On the jam-seeded
   > path (1a) this is already operationalized: the dispatch carries `jamSlug` + `intentSource:"capture"`, and
   > the engine's `intent-capture` step reads the jam **by path** (`README.md` → `index.md` + every
   > `source/*.md`) — the orchestrator never round-trips the jam body through its own context. **Bounded-read is
   > capture fidelity, NOT lossy summarization:** the read is bounded to the jam folder, but the converged jam's
   > **resolved forks must survive** (a converged jam RESOLVES its forks — `core/skills/sweep/SKILL.md` §"Jam
   > convergence" — and that resolution is exactly what the by-path capture must preserve). The mirror of this
   > principle in the orchestrated jam→build-direct path is documented in `core/skills/orchestrated/SKILL.md` §1.5.
   > **FS-less relaxation (AC-015):** the by-path/run-folder handoff is DECIDED — `docs/decisions/ADR-115`
   > (Accepted, carrying ADR-113 D2): the engine performs no FS I/O; agents use the run folder as intra-run
   > scratch bounded to `${runDir}`, never canonical `docs/step-3-specs/**`. The general PLANNED-path
   > ADR-finalize-outside-the-preamble *code* is installed by W4, not here.

2. **Create the run folder:**
   ```bash
   DATE=$(date +%Y-%m-%d); TIME=$(date +%H%M)
   RUN_DIR="docs/step-5-pipeline/${DATE}/${TIME}-ROADMAP-epic-${EPIC_SLUG}"
   mkdir -p "${RUN_DIR}/findings"
   ```
   **Intent is no longer hand-authored here (ADR-065).** On the jam-seeded path (1a) the engine captures intent and the orchestrator persists `intent.md` from the return. On the paste path (1b) the verbatim paste rides through as the `intent` arg (`intentSource: "curated"`). Either way the orchestrator does not write the intent doc — the engine's `intent-capture` step + persist own it.

3. **Write `${RUN_DIR}/prompt.md` with the Write tool** (NEVER a shell heredoc — the observer hook that auto-creates the state file fires on the Write tool, not on Bash; process-narrative Part 7 #3). Include a ticket-key-shaped label if the operator gave one. **Record the mode:** if the operator passed `--attended`, write a line `attended: true` in `prompt.md`; otherwise the run is autonomous (the default — ADR-054). The hook creates the state file with `track:"roadmap"`, `current_phase:"round-loop"`.

4. **Dispatch the roadmap Workflow engine** with `phase:"E"` (§ "Engine dispatch" below). The engine runs the funnel (research → cto-advisor → author → planner self-QA → finalize) **and then, autonomously, FANS OUT** — it runs the full Phase-W funnel for EVERY authored wave, **sequentially** (each wave sees the prior waves it builds on), all inside the one Workflow run (ADR-058). So a single `/roadmap` (Phase E) plans the whole epic end-to-end: `roadmap.md` + one `waves/<wave>/` spec per wave. The return carries `roadmapMarkdown` + `waves[]`; `persist_roadmap` writes them all in **one** persist call. **You do NOT hand-drive the funnel or author the draft** — that is the whole point (ADR-055). *(Fan-out is autonomous-only; `--attended` Phase E stops at the roadmap round. To author the roadmap without fanning out, pass `fanOut:false`.)* Persist the return, `rm` the state file, present.

### Phase W — wave → spec + prompts

1. **Create the run folder** and snapshot the wave's roadmap entry:
   ```bash
   RUN_DIR="docs/step-5-pipeline/${DATE}/${TIME}-ROADMAP-wave-${N}-${WAVE_SLUG}"
   mkdir -p "${RUN_DIR}/findings"
   ```
   Write `${RUN_DIR}/round-0-intent.md` = the named wave's fat skeleton extracted from the roadmap. Write `prompt.md` with the Write tool (as in Phase E step 3).
   If the roadmap entry is **thin** (a one-line stub, not a fat skeleton), proceed best-effort and flag at round 1: "this wave's skeleton was thin; consider a Phase E pass to fatten it." Do NOT silently run a mini-Phase-E.

2. **Dispatch the roadmap Workflow engine** with `phase:"W"` + `waveSlug` (§ "Engine dispatch" below). The engine runs the Phase-W funnel **inside the Workflow script** — `cto-advisor → architect-review → [ui-spec] → pm-spec(authors the spec) → spec-decomposer(slices into tickets[] — the ONE canonical slicer, ADR-044/047/048) → graph-validate → pm-spec(renders the parseable `# Wave:` schema from that binding slice, no re-slice) → planner self-QA → finalize` — and returns `waveSpecMarkdown` + `wavePromptsMarkdown` + `tickets`. The slice is owned by `spec-decomposer` (not pm-spec freehand), mirroring `/orchestrated`'s planning portion so a roadmap-authored wave carries the same ADR-048 shared-sink / ADR-044 AC-coverage guarantees the build path would (ADR-058). `persist_roadmap` writes them to the wave folder and **runs the `wave-manifest.py write-from-plan` schema-parse check** so the `/orchestrated` handoff stays frictionless. You do NOT hand-drive the funnel. *(Standalone Phase W is the same funnel a single fan-out iteration runs.)*

   **Output-format contract (binding — the engine's `pm-spec` agent honors this):** the canonical `<wave-slug>.md` MUST be the **parseable `# Wave:` ticket schema** that `core/scripts/wave-manifest.py write-from-plan` consumes (see `docs/step-3-specs/_wave-template.md`): `# Wave: <wave-slug>` header, optional `**Protocol version:** 3`, a `## Tickets` section of `### KEY: title` blocks each carrying `depends_on` / `planned_files` (non-empty) / `gate_recommendations` / `manual_review_required` / a `description` literal block. **Ticket keys MUST match `^[A-Z][A-Z0-9]*-[A-Z0-9]+$` — single hyphen only** (`SSM-T1`, never `SSM-101-T1`). Co-locate in `docs/step-3-specs/<epic-slug>/waves/<wave-slug>/`: the schema `<wave-slug>.md` + the build prose `<wave-slug>-prompts.md`.

### Engine dispatch (ADR-055 — the orchestrator's whole runtime job)

Roadmap runs as a **Workflow script** (`core/scripts/workflows/roadmap.js`) on the same substrate as
`/orchestrated`, so it shows in `/workflows` and the orchestrator carries **zero funnel ceremony**. After the
scaffolding above (intent sourced, `${RUN_DIR}` created, `prompt.md` written; Phase E intent is engine-captured or rides through as the `intent` arg — ADR-065; Phase W snapshots the wave skeleton), the
orchestrator's entire remaining job is **one Workflow call + one persist call + teardown + present**:

1. **Resolve the script path** (ADR-031): `.claude/scripts/workflows/roadmap.js` if it exists, else
   `core/scripts/workflows/roadmap.js`.
2. **Invoke the `Workflow` tool** with that `scriptPath` and `args`. Two shapes by intent source (ADR-065):

   **Jam-seeded (1a) — engine captures intent:**
   ```json
   {
     "runDir": "${RUN_DIR}",
     "repoRoot": "<abs repo root>",
     "phase": "E",
     "epicSlug": "<epic-slug>",
     "waveSlug": null,
     "intentSource": "capture",        // engine dispatches pm-spec to read+ground the jam
     "jamSlug": "<jam-slug>",           // resolves docs/step-2-planning/jam-<jamSlug>/ (nullable)
     "intent": "",                      // empty — capture populates it
     "attended": false                 // true only if prompt.md carries `attended: true`
   }
   ```

   **Paste (1b) — verbatim curated intent, zero capture dispatch:**
   ```json
   {
     "runDir": "${RUN_DIR}",
     "repoRoot": "<abs repo root>",
     "phase": "E",                     // or "W"
     "epicSlug": "<epic-slug>",
     "waveSlug": null,                 // Phase W: "<wave-slug>"
     "intentSource": "curated",        // short-circuit; the paste flows through verbatim
     "jamSlug": null,
     "intent": "<verbatim epic intent paste>",
     "attended": false
   }
   ```
   *(Phase W dispatches as today — `intentSource` is a Phase-E concern; the wave's fat skeleton rides through as `intent` and `runPhaseW` never reaches the capture call.)*
   The script runs the funnel autonomously and returns `{ track:"roadmap", phase, epicSlug, roadmapMarkdown +
   waves:[{slug,waveSpecMarkdown,wavePromptsMarkdown,tickets}] (Phase E fan-out) | waveSpecMarkdown+wavePromptsMarkdown
   (standalone W), findings, criterionFindings, surfaceRequired }`. *(Phase E with `fanOut:false` returns `waves:[]`.)*
3. **Persist the return** (FLAG-1 — scripts have no FS access; the orchestrator writes): write the return to a
   tmp JSON, then run (substrate path per ADR-031):
   ```bash
   S="$([ -d .claude/scripts ] && echo .claude || echo core)/scripts"
   python3 "$S/persist-run-artifacts.py" --run-dir "${RUN_DIR}" --slug "${SLUG}" --return-file /tmp/roadmap-return.json
   ```
   `persist_roadmap` writes `findings/*`, `round-1-draft.md`/`locked.md`, and the **canonical**
   `docs/step-3-specs/<epic>/roadmap.md` (E) **plus one `docs/step-3-specs/<epic>/waves/<wave>/{<wave>.md,-prompts.md}` per
   fanned-out wave** (each schema-parse-checked), or just the single wave folder (standalone W), plus the thin
   manifest. **One persist call writes the whole epic** — the orchestrator does not loop. The persist return's
   `waves[]` lists each wave's canonical path + `schema_ok`.
3b. **Stage the Draft ADR — `docs/step-3-specs/<epic>/adr.md` (VPH-W4A / ADR-116 D1 half-a; Phase E only).**
   The forward-referenced ADR is **authored here, at lock** — not by the architect-pre pass `/orchestrated`
   skips on a PLANNED build (that skip is the dogfood drop ADR-116 closes). Write `docs/step-3-specs/${EPIC_SLUG}/adr.md`
   with `**Status:** Draft`, **UNnumbered** (no `ADR-NNN`), and **decisions pre-filled from the resolved forks**
   the funnel settled (one `### D-n` block per resolved fork, sourced from `locked.md` / the round drafts). The
   decisions travel **with the spec** so a PLANNED build inherits them. This is explicitly **NOT** a premature
   full-ADR leap: no number is claimed and the status is **never** `Accepted` here — numbering + `Accepted` is
   `/orchestrated`'s build-start finalize job (half-b, atomic via `claim-id.py`; ADR-072 — never hand-numbered).

   **CR-005 — scaffold REAL `### D-n` decision blocks, not a placeholder comment.** Before staging, collect the
   forks the funnel actually resolved from the locked artifact (`locked.md`'s `## Resolved forks` / `## Source
   disposition` content, falling back to the highest `round-N-draft.md`) — emit **one `### D-n: <decision>` block
   per resolved fork** so "decisions travel with the spec" actually holds. The lock step fills each block's body
   (the decision + its rationale one-liner) from the resolved fork; an empty placeholder comment is NOT acceptable
   (it would finalize into a contentless ADR at build). The shell below scaffolds the blocks from a `RESOLVED_FORKS`
   array the lock step populates (`"D-1: <decision text>"` per entry); if the funnel resolved zero forks (rare),
   emit a single explanatory block rather than an empty comment.
   **Stage-only** (`git add`, never commit):
   ```bash
   EPIC_DIR="docs/step-3-specs/${EPIC_SLUG}"
   ADR_DRAFT="${EPIC_DIR}/adr.md"
   # RESOLVED_FORKS: one "D-n: <decision>" entry per fork the funnel settled, sourced from locked.md's
   # '## Resolved forks' / '## Source disposition' (fallback: the highest round-N-draft.md). The lock step
   # populates this from the round artifacts — it is NOT hand-invented here.
   if [ ! -f "${ADR_DRAFT}" ]; then          # idempotent: a re-lock never re-stamps an existing draft
     mkdir -p "${EPIC_DIR}"
     {
       echo "# ADR (Draft) — ${EPIC_SLUG}"
       echo
       echo "**Status:** Draft"             # UNnumbered + Draft — /orchestrated build-start claims the number + marks Accepted (ADR-116 D1 half-b)
       echo "**Date:** $(date +%Y-%m-%d)"
       echo
       echo "## Decisions (pre-filled from the resolved forks)"
       echo
       if [ "${#RESOLVED_FORKS[@]}" -gt 0 ]; then
         for fork in "${RESOLVED_FORKS[@]}"; do
           # fork = "D-n: <decision text>" — split on the first ': ' into label + decision.
           label="${fork%%: *}"; decision="${fork#*: }"
           echo "### ${label}: ${decision}"
           echo
           echo "_(resolved at /roadmap lock from the funnel; rationale travels with the spec into the build-finalized ADR — ADR-116 D1.)_"
           echo
         done
       else
         echo "### D-1: (no forks required resolution)"
         echo
         echo "_(the funnel settled with no open forks; the build-finalized ADR records the approach as-planned.)_"
         echo
       fi
     } > "${ADR_DRAFT}"
   fi
   git add "${ADR_DRAFT}"
   ```
   *(Skip on standalone Phase W and the paste path with no epic folder — there's no epic root to stage into; the
   draft is an epic-level artifact written once at the Phase-E lock. The build-start finalize tolerates its
   absence — a NOT-PLANNED or draftless build authors the ADR inline via architect-pre as today.)*
4. **Auto-graduate + the two INSEPARABLE reconciliations (VPH-W1B / ADR-114 D2; Phase E + jam-backed only).**
   The conveyor auto-advances at the plan-lock seam: the jam graduates step-2 → step-3 and the two reconciliations
   that make the move safe run **as ONE sequence with no early exit between them** — `graduate → coverage-reteach →
   citation-repoint`. The skill makes it impossible to graduate without also reteaching coverage + repointing
   citations (the move-and-break failure — move the jam, then glob the now-empty old path and pass vacuously — is
   structurally prevented because the coverage check runs AFTER the move, against the GRADUATED path). Skip this whole
   step for the paste path (`intentSource:"curated"`, no jam) and for standalone Phase W (no epic roadmap.md).
   `EPIC_SLUG` = the return's `epicSlug`; `JAM_DIR` = the jam dir from intake step 1a.

   **4a. Graduate (merge-into-existing).** The roadmap engine's persist step (4 above) already wrote
   `docs/step-3-specs/${EPIC_SLUG}/roadmap.md` + `waves/<wave>/` during this run — so the graduation target already
   exists non-empty and the per-wave reshape is already done. Graduate in **merge-into-existing** mode: it skips the
   non-empty refusal, moves only the jam's residual top-level entries that do NOT collide (`source/`, the
   `README.md`/`index.md` brief, any `decomposition/` — preserving persist's `roadmap.md` + `waves/`), skips the
   reshape because `waves/` already exists, and rmdir's the emptied jam dir:
   ```bash
   S="$([ -d .claude/scripts ] && echo .claude || echo core)/scripts"
   python3 "$S/graduate-jam.py" --slug "${EPIC_SLUG}" --target orchestrated --into-existing
   ```
   Idempotency: a re-lock where the jam is already merged (source absent, target populated) is treated as
   already-graduated — skip-and-continue to 4b/4c, never error the whole lock (`graduate-jam.py` handles this).

   **4b. Reteach the source-coverage gate (ADR-103 W2 IN bookend) — AFTER graduation, against the GRADUATED path.**
   After 4a the decided-idea sources live at `docs/step-3-specs/${EPIC_SLUG}/source/*.md` (they rode along in the
   move). `roadmap-source-coverage.py` globs `<arg>/source/*.md`, so pass the **graduated** path as the `<jam-dir>`
   positional and run the check **AFTER the move** — ordering is load-bearing: a check against the pre-move jam path
   would pass vacuously once the move emptied it (the silent coverage hole). The HARD gate stays hard:
   ```bash
   GRADUATED_DIR="docs/step-3-specs/${EPIC_SLUG}"          # NOT the pre-move jam path
   ROADMAP_MD="docs/step-3-specs/${EPIC_SLUG}/roadmap.md"
   python3 "$S/roadmap-source-coverage.py" check "${GRADUATED_DIR}" "${ROADMAP_MD}"; RC=$?
   ```
   - **RC=0** — every decided source is accounted for (or no jam applies). Proceed to 4c.
   - **RC=2** — GAP. **HALT — do NOT teardown, do NOT present a clean lock.** The unaccounted source slugs are on
     stderr. Perform the single consolidated surface (`SURFACE_TYPE: validate-fail`): name them and ask the operator
     to re-run with each dispositioned (`## Source disposition` → `wave:<slug>` | `non-goal` | `defer:<target>`) or
     confirm the drop. The state file stays (run remains open for disposition).
   - **RC=3 (or any other non-zero, non-2 code)** — usage/IO error or unanticipated failure (the checker collapses
     IO failures to 3, but treat the branch fail-closed regardless): surface as `SURFACE_TYPE: unknown`, **do NOT
     teardown** (SA-001 — a completeness gate must never reach a clean lock on a code it didn't recognize).
   This is the **single hard gate** (ADR-103 one-hard-gate principle) — rare, pre-lock, decisive.

   **4c. Repoint citations.** By-path jam citations in the locked `roadmap.md` (`docs/step-2-planning/jam-${EPIC_SLUG}/...`)
   dead-link after the move. Rewrite them to `docs/step-3-specs/${EPIC_SLUG}/...` and **stage only** (`git add`, never
   commit):
   ```bash
   ROADMAP_MD="docs/step-3-specs/${EPIC_SLUG}/roadmap.md"
   if [ -f "${ROADMAP_MD}" ]; then
     python3 - "${ROADMAP_MD}" "${EPIC_SLUG}" <<'PY'
   import sys
   md, slug = sys.argv[1], sys.argv[2]
   src, dst = f"docs/step-2-planning/jam-{slug}/", f"docs/step-3-specs/{slug}/"
   with open(md, encoding="utf-8") as f: t = f.read()
   n = t.count(src)
   if n:
       with open(md, "w", encoding="utf-8") as f: f.write(t.replace(src, dst))
   print(f"repointed {n} jam citation(s) in {md}")
   PY
     git add "${ROADMAP_MD}"
   fi
   ```
   After lock, `grep -rn 'step-2-planning/jam-${EPIC_SLUG}' "${ROADMAP_MD}"` returns nothing live.

   **Inseparability (AC-009).** 4a → 4b → 4c run as one sequence in this finalize path with no early exit between
   them. The `--attended` arm (Exit contract §6, two-step lock) routes through this same finalize — its lock step
   performs the identical graduate+reteach+repoint sequence before declaring lock. All verbs are stage-only (ADR-105:
   `git mv` / `git add` only; never commit/push/`reset --hard`). Path-safety preserved (ADR-049: slug validated, both
   endpoints realpath-bounded, subprocess arg-list — handled inside `graduate-jam.py`).
5. **Teardown:** `rm -f .claude/agent-memory/active-runs/${SESSION_ID}-${SLUG}.json` (Bash, not Edit/Write —
   the active-runs guard blocks the tools).
6. **Present the completion report** — name the canonical `roadmap.md` path AND **each fanned-out wave spec**
   (`docs/step-3-specs/<epic>/waves/<wave>/`, with its `schema_ok` from the persist return), the shape (waves +
   ejected items), open refinements (if any), and the next step. **The PRIMARY recommendation is the default
   all-waves-straight epic build `/orchestrated <epic-slug>`** (ADR-112 Wave 2 — front-loaded; builds every wave
   in dependency order in one run). Offer `/orchestrated <wave-slug>` only as the **secondary** granular option
   (build a single wave at a time). The waves are already planned. **If `surfaceRequired` is true** (a genuine ADR-018 interrupt — e.g. a wave's
   funnel halted the fan-out, or `--attended`), do NOT teardown/finalize —
   perform the single consolidated halt per the surface protocol and let the operator decide (attended:
   lock/tune; interrupt: resolve).

> **`--attended` runs** return `surfaceRequired:true` + `surfaceType:"roadmap-round"` WITHOUT finalizing — the
> orchestrator presents the round boundary (draft + the self-QA recommended reply) and the operator
> `lock`/tunes per §"Per-round protocol"/§"Exit contract". The interactive multi-round loop stays
> orchestrator-mediated (it is inherently interactive); the autonomous default is the engine's single pass.

### End (`/roadmap off`)

```bash
STATE_FILE=".claude/agent-memory/active-runs/${SESSION_ID}-${SLUG}.json"
rm -f "${STATE_FILE}"   # Bash rm -f, NOT Edit/Write — block-active-runs-edits.sh blocks the tools, not Bash.
```
Confirm: "Roadmap session ended. Run folder + drafts persist at `${RUN_DIR}` for review or resume."

## Per-round protocol (§5) — `--attended` mode only

> **Autonomous mode (default) does NOT use this loop.** It runs the funnel once and proceeds straight to finalize (§6 autonomous path) — no round boundary, no operator tuning. The section below governs only `--attended` runs.

1. Run the round's funnel autonomously to completion. Mid-round interrupts are ONLY ADR-018 criteria 1/2/3/5. Defensible-options → pick-and-document.
2. Write `round-N-draft.md` to disk.
2b. **Round-boundary enrichment (ADR-035 — kill the relay).** Dispatch the `planner` subagent (read-only, `subagent_type: "planner"`) on `round-N-draft.md` + the tuning prompts → it re-verifies the load-bearing findings by view and writes `findings/round-N-recommended-reply.md`: a paste-ready recommended answer to every tuning prompt + a `LOCK`/`CONTINUE` recommendation. It recommends only — it never locks, advances, or edits the draft. Benign failure: if it produces nothing, present un-enriched (today's behavior). Resume-safe: if the file already exists, re-present, don't re-dispatch. Full contract: `core/config/phases/roadmap/round-loop.md` § "Round-boundary enrichment".
3. Present: a one-paragraph "what changed from round N-1" (if N>1); the draft inline (or pointer if very large); **the choices you made this round, with rationale** (operator review of pre-made choices — NOT blocking pickers); the **`## Recommended reply (planner) — paste-ready`** section (from step 2b); explicit tuning prompts ("is the wave 3/4 split right?", "did we miss a boundary?", "any waves to reorder?").
4. Halt at the round boundary — END THE TURN. Wait for operator input. The enrichment never auto-locks or advances; the exit is still operator lock (ADR-030 preserved).
5. On input:
   - **lock** ("locked"/"approved"/"go") → exit contract below.
   - **tuning text** → write `round-N-operator-input.md` (verbatim quote + your interpretation), run round N+1. Re-run the research pass ONLY if the tuning changed scope; else reuse round-0 research.
   - **"edit the roadmap directly"** (Phase E) → operator hand-edits `round-N-draft.md`; read the diff and treat it as the round-(N+1) input.
   - **override of a specific choice** → note it in the operator-input file; round N+1 incorporates it.

> Soft cap: at ~10 rounds, surface "this is taking many rounds — consider whether the intent needs revising." No hard cap.

## Exit contract (§6)

**Autonomous mode (default — ADR-054):** the funnel's single pass flows straight into finalize with **no operator confirm**. After the planner self-QA, copy the (tuned) draft → `locked.md`, write the canonical destination (Phase E → `docs/step-3-specs/<epic-slug>/roadmap.md`; Phase W → the wave folder with the schema-parse sanity check), `rm -f` the state file, and present the finished artifact as a completion report. Writing the canonical planning doc is an orchestrator-permitted `docs/**` write — no shared-state gate. `CONTINUE`-class planner tunings that aren't mechanically applied are recorded as an `## Open refinements (planner)` section in the finalized doc (not another round). The phase file is authoritative for the autonomous finalize.

**`--attended` mode — two-step lock (legacy ADR-030):**

1. Copy the locked `round-N-draft.md` → `${RUN_DIR}/locked.md`.
2. Stage the canonical destination — **everything lives inside the epic's spec folder `docs/step-3-specs/<epic-slug>/`** (the fold-in of the old `roadmaps/` + `waves/` split into one per-epic folder; ADR-051):
   - Phase E → `docs/step-3-specs/<epic-slug>/roadmap.md` (the epic "map"). `mkdir -p docs/step-3-specs/<epic-slug>` first.
   - Phase W → the wave's own folder `docs/step-3-specs/<epic-slug>/waves/<wave-slug>/`: `<wave-slug>.md` (parseable `# Wave:` ticket schema — see the Output-format contract in step 2) **and** `<wave-slug>-prompts.md` (per-ticket build prose), plus `<wave-slug>.spec.md` if there's long-form spec narrative. `mkdir -p docs/step-3-specs/<epic-slug>/waves/<wave-slug>` first. Before declaring lock, sanity-check that the schema parses: `python3 "$([ -d .claude/scripts ] && echo .claude || echo core)/scripts/wave-manifest.py" write-from-plan docs/step-3-specs/<epic-slug>/waves/<wave-slug>/<wave-slug>.md /tmp/_wavecheck.json` must exit 0 (the `$(…)` resolves the substrate path in both consumer and claude-infra contexts — ADR-031).
3. Present a **one-screen diff** between the destination's previous state (if any) and the new state; ask one final confirmation: **"writing this as canonical. confirm?"**
4. On confirm → write the canonical file(s), then **run the graduate → coverage-reteach → citation-repoint sequence (§4a/4b/4c above) — the `--attended` lock routes through the SAME finalize reconciliation as the autonomous path** (a coverage RC=2/RC=3 here still HALTs the lock; never teardown on a held gate), then `rm -f` the state file, then present a closing message naming the canonical paths and the next step — **PRIMARY: `/orchestrated <epic-slug>`** (the default all-waves-straight epic build — ADR-112 Wave 2), with `/orchestrated <wave-slug>` offered as the **secondary** granular single-wave option.
5. On decline → reverse the lock; drop back into the tuning loop at round N.

## Delta-as-new-wave — re-running /roadmap on an already-built spec (VPH-W1C / ADR-114 D3)

When an operator has a **delta** (new requirements) on a spec that is already roadmapped AND built, there is no
fresh-epic rebuild — the delta graduates as a **NEW `# Wave:` appended to the existing
`docs/step-3-specs/<slug>/` spec** (a new `waves/<wave-slug>/` folder), and `/orchestrated <new-wave-slug>` builds
it against the **prior built tip**:

1. **Plan the delta as a wave.** Run `/roadmap` (Phase E delta pass, or Phase W on the new wave) on the same
   `<slug>`. The delta is authored as one more `# Wave:` and lands in `docs/step-3-specs/<slug>/waves/<new-wave-slug>/`
   — it does **not** spawn a new epic folder.
2. **Graduate through the SAME door.** The delta's residual jam artifacts graduate via VPH-W1B's
   `graduate-jam.py --into-existing` merge mode (§4a) — `--into-existing` is exactly built for the
   already-populated-target case, so an appended wave merges cleanly without re-reshaping the existing waves. The
   coverage-reteach (§4b) + citation-repoint (§4c) reconciliations run as usual.
3. **Build against the prior built tip.** `/orchestrated <new-wave-slug>` reuses the engine's per-wave re-root: the
   orchestrator passes the prior built wave's integrated tip as `baseSha` (the same wave-stepping that re-roots
   wave *i+1* off wave *i*'s `integrated_head` — `core/scripts/workflows/orchestrated.js` STEP 0 / the args-header
   delta note), so the delta wave composes on the BUILT spec, not a stale base. No new engine path — the delta wave
   is just another wave through the unchanged build flow.

**Out of scope (deferred):** TRUE LINE-LEVEL INCREMENTAL REBUILD — re-running only the changed lines/files of an
already-built wave (rather than appending a fresh wave) — is the heavier deferred path and is **explicitly NOT
built here** (ADR-114 §Out of scope). W1C is delta-as-new-wave append only. (Triage stub home if revived:
`docs/step-1-ideas/`.)

## Resume (any session, including fresh)

`/roadmap <slug>` re-enters an in-progress run:
1. Glob the most-recently-modified `docs/step-5-pipeline/*/*-ROADMAP-*${slug}*/` run folder.
2. Read the **highest** `round-N-draft.md` present — resume at round **N+1**. **Never restart at round 0 when drafts exist** (the durable-artifact guarantee; this is the load-bearing resume invariant covered by `core/scripts/test-roadmap-mode.sh`). *(Back-compat, ADR-065 §5: a run authored before script-captured intent may carry a `round-0-intent.md`; the resume glob still finds it for continuity. New runs persist the engine-captured intent as `intent.md` — the resume guard reads whichever is present. The orchestrator persists; it does not re-author the intent doc.)*
3. If `surface-prompt`/`round-N-operator-input.md` indicates a pending operator decision, re-present it; else continue the funnel.
4. The PostToolUse hook re-creates a fresh `${SESSION_ID}-${slug}.json` state file when you re-write `prompt.md` via the Write tool (mirror `/orchestrated`/`pipeline-advance` synthesis); `session-cleanup.sh` clears prior-session state.

## Bypass overlay

If `/bypass` is also active, bypass takes priority for gating — all agents pass. The roadmap run folder, drafts, and `completed_agents[]` accumulation continue. When `/bypass off` runs, the `round-loop` phase-boundary check resumes (advisors pass; implementers block via the `roadmap)` track arm).

## When to use it

1. **New epic kickoff.** You pasted an epic intent and want the ~N-wave roadmap with fat per-wave skeletons, tuned over a few rounds, then locked.
2. **Wave kickoff (cold session).** A wave is on the roadmap but unplanned. `/roadmap wave-N` runs the cto→architect→ui-spec→pm-spec funnel and produces the buildable spec + prompts that `/orchestrated` consumes.
3. **Re-planning a wave.** A wave's spec needs a revision pass with advisor input and operator tuning before re-execution.
4. **A delta on an already-built spec.** New requirements on a roadmapped+built spec → plan the delta as a **new appended wave** (§"Delta-as-new-wave") and build it with `/orchestrated <new-wave-slug>` against the prior built tip. (True line-level incremental rebuild is out of scope — ADR-114 §Out of scope.)

## When NOT to use it

1. **Building a planned epic** → `/orchestrated <epic-slug>` (the default all-waves-straight build — ADR-112 Wave 2); build a single wave granularly with `/orchestrated <wave-slug>`. `/roadmap` plans; `/orchestrated` builds.
2. **Single-feature work** → `/nimble` (or `/orchestrated` for a multi-ticket wave).
3. **One-shot advisor opinion** → `/bypass` + `@<agent>`, or `/planner` for a structured advisory session.
4. **Authoring intent.** Intent is authored by the operator (in claude.ai or wherever) and pasted in. `/roadmap` ingests intent; it does not author it, and it forbids feasibility claims in the paste.

## Intake template (Phase E — paste this shape)

```markdown
# Epic intent
## Product intent          — what we're building and why (the thesis)
## Hard constraints        — non-negotiables (stack, security, tier model, distribution)
## Non-goals / out of scope — what NOT to build now; deferred to a later epic
## Wave hypothesis (optional) — first-pass guess at wave structure; treated as hypothesis, overridable by the research pass
## Forbidden claims        — NO sentences asserting how existing code is structured. If such a claim would help, write "[CC to verify]" and the research pass answers it.
```
