---
name: orchestrated
description: "Start an orchestrated wave run on the v2 Workflow engine (cto → architect-pre → pm-spec → [ui-spec] → [decompose] → explore → one-implementer wave-build → integrate → batch-gate → [architect-final]). Multi-ticket; thin-manifest tickets[] resume."
user_invocable: true
---

## Starting an Orchestrated Wave (v2 — Workflow engine)

Post engine-swap (ADR-039 → ADR-040), the orchestrated track runs as a **native Workflow
script** (`core/scripts/workflows/orchestrated.js`), not the bespoke phase state machine
(`setup → w-setup → t-cto → … → w-finalize`). The whole chain — both architect passes (D4),
multi-ticket decompose, parallel-per-ticket worktree implement, the staleness-guarded
integration merge, and the D5 batch-gate over the integrated diff — lives in one Workflow call
that never enters the orchestrator's per-turn context. That is the token win.

The orchestrator drives a small number of steps. **The persist step (3) is load-bearing and
MUST NOT be skipped** — the Workflow script has no filesystem access and read-only agents
cannot `Write`, so knowledge artifacts (ADR, spec, findings, run-log) are persisted by the
orchestrator from the structured return (FLAG-1).

> **Substrate path resolution (consumer-safe — ADR-031).** The substrate scripts below live at
> `core/scripts/…` when dogfooding inside claude-infra, but at `.claude/scripts/…` in a consumer
> repo (where `core/` is absent — they are symlinked under `.claude/`). A bare `core/…` path does
> NOT resolve in a consumer. Every Bash block that calls one resolves the prefix first
> (`S=.claude/scripts; [ -d "$S" ] || S=core/scripts`, then `$S/…`). For the `Workflow` tool's
> `scriptPath`, pass `.claude/scripts/workflows/orchestrated.js` if that path exists, else
> `core/scripts/workflows/orchestrated.js`.

### 0. Pre-flight — wave branch + base ref

```bash
SLUG="<kebab, <=4 words>"
WAVE_BRANCH="feature/wave-$SLUG"
git checkout -b "$WAVE_BRANCH" 2>/dev/null || git checkout "$WAVE_BRANCH"
WAVE_BASE_REF="$(git rev-parse HEAD)"     # stable diff/merge base for integrate + gate (AC-5)
```

The wave branch is the per-ticket integration destination; **main is never written during the
run.** `WAVE_BASE_REF` is passed to the workflow so the `integrate` step's staleness guard and
the gate's `git diff` use a stable base (not an advancing HEAD).

### 1. Create the run folder + prompt.md — via **Bash**, not the Write tool

```bash
D="docs/step-5-pipeline/$(date +%Y-%m-%d)/$(date +%H%M)-WAVE-$SLUG"
mkdir -p "$D/findings"
cat > "$D/prompt.md" <<'EOF'
# <wave title>
Ticket key: <KEY>
<verbatim wave intent + standing instructions>
EOF
```

Bash heredoc (not the Write tool) so the v1 auto-fire hook (`sync-artifacts-post-agent.sh`,
PostToolUse on Write) does NOT trigger the legacy state machine. The v2 engine owns its lifecycle.

### 1.5. Move the graduated wave spec **or jam** into the run folder — the build's FIRST act (ADR-051 move-on-advance)

Two move-on-advance sources, checked in priority order — **graduated spec first, jam-direct fallback:**

1. **Spec → build (the canonical path).** If a graduated, build-ready wave spec exists for `$SLUG`, **move its
   folder into the run folder `$D`** before launching the engine. The spec walks from `docs/step-3-specs/` into the
   pipeline run — it does not linger in two places. This is move-on-advance at the spec→build boundary
   (ADR-051 §3): the pre-build *knowledge* (the `# Wave:` schema, prompts, findings) co-locates with the run,
   where the engine then writes its *control-flow* state (`run-manifest.json`). The authored `# Wave:` graph
   is ingested into `tickets[]` so the engine **skips `[decompose]`**.

2. **Jam → build direct (the skip-spec edge — ADR-051 §4 + §3a).** If **no** spec exists but a jam does at
   `docs/step-2-planning/jam-$SLUG/`, **move the jam folder into the run** instead. Going straight to `/orchestrated`
   means the spec work is happening *live* inside the engine (cto→architect→pm-spec→decompose) — there is no
   "ready but not yet building" interval, so there is no reason to stop in `docs/step-3-specs/`. The jam advances
   **directly to pipeline**, skipping the spec stage. The jam's `README.md` (the converged brief) becomes the
   intent **verbatim — no hand-authored brief** (symmetric to `/roadmap`'s jam-first intake, §8); `source/` +
   `findings/` ride along as the engine's deep context. `tickets[]` stays unset → the engine decomposes in
   place (the spec is happening now). After the move the jam is gone from `docs/step-2-planning/` — git is the history.

   > **Curate-once + pass-by-path + bounded-read (ADR-115 D4 / AC-014; ADR-082/083 token discipline) — the
   > orchestrated mirror of `/roadmap` step 1a.** The jam is handed to the funnel **by PATH, not inlined into a
   > dispatch arg string**: the move-on-advance relocates the jam folder INTO the run (`$D`), the converged brief
   > is seeded into `$D/prompt.md` via a Bash redirect, and the engine's downstream advisory/build/gate agents
   > read it **from the run folder** (`runDir` + `specByPath()`) — the orchestrator never round-trips the full
   > brief through its own context as a value. **Bounded-read is capture fidelity, NOT lossy summarization:** the
   > converged jam's **resolved forks must survive** the by-path handoff (a converged jam RESOLVES its forks —
   > `core/skills/sweep/SKILL.md` §"Jam convergence"). The roadmap-side statement of the same principle is in
   > `core/skills/roadmap/SKILL.md` step 1 (`intentSource:"capture"` + `jamSlug`).

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
# Slug safety (SA-002 precedent): kebab-only — no `..`/`/`/empty can escape the planning tree via the glob.
case "$SLUG" in *..*|*/*|"") echo "ERROR: invalid wave slug '$SLUG' (kebab only)" >&2; exit 1;; esac
# The wave folder lives under some epic: docs/step-3-specs/<epic-slug>/waves/$SLUG/
SPEC_DIR=$(ls -d docs/step-3-specs/*/waves/"$SLUG" 2>/dev/null | head -1)
JAM_DIR="docs/step-2-planning/jam-$SLUG"
TICKETS_JSON="null"   # default: no graduated spec → engine decomposes (ad-hoc / jam-direct path)
WAVE_SPECS_JSON="null"  # PEC-T3 plan-detection: on-disk wave-spec markdown[] → engine classifies PLANNED
SPEC_MD_JSON="null"     # PEC-T4: the spec narrative the gates read when the preamble's pm-spec is skipped
HAS_UI="false"        # ADR-104: the wave's UI-surface carry; set from the manifest when a graduated spec
                      # is ingested (else false — the engine's deterministic hasUiSurface floor still fires)
if [ -n "$SPEC_DIR" ] && [ -d "$SPEC_DIR" ]; then
  git mv "$SPEC_DIR"/* "$D"/ 2>/dev/null || mv "$SPEC_DIR"/* "$D"/
  rmdir "$SPEC_DIR" 2>/dev/null || true
  # If the parent epic folder is now empty of waves, it has fully graduated; leave it (its roadmap.md may remain).
  echo "moved graduated spec $SPEC_DIR → $D (build's first act)"

  # INGEST the authored # Wave: schema → engine-shaped tickets[] so the engine builds the
  # hand-authored graph (depends_on / planned_files / gates) instead of RE-deriving it via
  # [decompose]. Passing tickets[] in args makes the engine skip the decompose step (ADR-051 §7.2;
  # orchestrated.js arg `tickets?` = "skip decompose if given").
  WAVE_MD="$D/$SLUG.md"
  if [ -f "$WAVE_MD" ]; then
    python3 "$S/wave-manifest.py" write-from-plan "$WAVE_MD" "$D/wave-manifest.json" || true
    if [ -f "$D/wave-manifest.json" ]; then
      TICKETS_JSON=$(python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
out=[{
  "key": t["key"],
  "description": (t.get("title","")+"\n\n"+t.get("description","")).strip(),
  "depends_on": t.get("depends_on",[]),
  "planned_files": t.get("planned_files",[]),
  "acceptance": t.get("acceptance",[]),   # ADR-103 W1: '# Wave:' now renders + wave-manifest.py parses '- acceptance: [...]', so the AC-NNN atom chain rides through here (was always [] before — the defang root)
  "gates": t.get("gate_recommendations",[]),
} for t in m.get("tickets",[])]
print(json.dumps(out))
' "$D/wave-manifest.json")
      # ADR-104: carry the wave-level has_ui from the manifest → the dispatch `hasUi` arg, so the build's
      # ui-spec/ui-review fire without the operator re-deriving it (the planning→build handoff).
      HAS_UI=$(python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1])).get("has_ui") else "false")' "$D/wave-manifest.json")
    fi
    # PEC-T3/T4 plan-detection (wire-to-consumer): pass the on-disk wave-spec markdown so the engine's
    # detectPlanned() classifies this graduated folder as PLANNED → it SKIPS the advisory preamble
    # (cto/architect-pre/pm-spec/[ui-spec]) + decompose and builds only (slice-once — /roadmap already
    # sliced). For an all-waves-straight `/orchestrated <folder>` run, build the array over EVERY wave
    # spec in the folder; the engine's `every()` fail-closes to NOT-PLANNED if any wave is still raw.
    # ADR-115 D1 (the floor): read the wave markdown from disk ONCE, then derive BOTH dispatch args from
    # that single read — was two byte-identical disk reads of the same file (the exact 2× duplicate the
    # dogfood flagged; ADR-082/083 "pass by path not by value"). One python3 -c opens the file once and
    # emits BOTH pre-encoded args as a JSON 2-array [waveSpecs, specMarkdown]; two trivial index extracts
    # (no further disk read) assign the shell vars. The emitted shapes are byte-for-byte UNCHANGED
    # (waveSpecs = [{"slug","markdown"}], specMarkdown = the raw string JSON-encoded, trailing newline
    # preserved — command substitution would have stripped it) — a de-dup of the read, NOT a dispatch-
    # payload contract change. grep -cn 'open(WAVE_MD).read()' returns ≤1 for dispatch-arg construction.
    WAVE_ARGS_JSON=$(python3 -c 'import json,sys; md=open(sys.argv[1]).read(); print(json.dumps([json.dumps([{"slug": sys.argv[2], "markdown": md}]), json.dumps(md)]))' "$WAVE_MD" "$SLUG")
    WAVE_SPECS_JSON=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$WAVE_ARGS_JSON")
    SPEC_MD_JSON=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[1])' "$WAVE_ARGS_JSON")
  fi

  # ADR-FINALIZE on the PLANNED path (VPH-W4A / ADR-116 D1 half-b — the wire-to-consumer atom, AC-026).
  # /roadmap STAGED a Draft ADR at the EPIC ROOT (docs/step-3-specs/<epic>/adr.md), NOT inside waves/<slug>/,
  # so the `git mv "$SPEC_DIR"/* "$D"/` above did NOT move it. Derive the epic root from $SPEC_DIR
  # (docs/step-3-specs/<epic>/waves/<slug> → strip /waves/<slug>) and, if a Draft adr.md exists there,
  # FINALIZE it: claim the number ATOMICALLY (claim-id.py adr — ADR-072; NEVER scan-for-max — that is the
  # ADR-061 collision), write the finalized content INTO the canonical docs/decisions/ADR-NNN-<epic>.md
  # the allocator just created (claim-id writes a Proposed STUB — we overwrite it with the real Draft body,
  # Status: Draft → Accepted + the claimed number in the title), and keep a copy at the run folder $D/adr.md
  # for the implementer's reference. The CANONICAL record is docs/decisions/ADR-NNN-<epic>.md — that is what
  # every other ADR uses and what adr-index.py scans; a Proposed stub left behind would index as an empty ADR.
  # The engine is FS-less and only SIGNALS via payload.adrFinalize — orchestrated.js; ADR-039 contract 2.
  # Stage-only (git mv / git add — never commit). Absent/non-Draft adr.md → no-op (a draftless or already-
  # finalized build authors the ADR inline via architect-pre as today — the fail-open direction).
  #
  # CR-001: capture claim-id stdout ONCE, then PARSE both the number and the canonical path out of the
  #   `CLAIM-ADR: number=NNN path=...` line — do NOT use the raw stdout as the number.
  # CR-003: write the finalized body INTO $ADR_PATH (the canonical file), not only the run-folder copy.
  # CR-004: claim + title with the EPIC slug (the staged ADR is epic-scoped), derived from EPIC_ROOT.
  #   Idempotency: the finalize fires ONCE per epic build — the first wave finds the Draft and promotes it;
  #   subsequent waves find no Draft adr.md at the epic root (it was git mv'd away) and no-op. The
  #   `grep -q Draft` guard makes that explicit (an already-Accepted or absent draft never re-finalizes).
  EPIC_ROOT="${SPEC_DIR%/waves/*}"            # docs/step-3-specs/<epic>/waves/<slug> → docs/step-3-specs/<epic>
  EPIC_SLUG=$(basename "$EPIC_ROOT")          # CR-004: epic slug (NOT the wave slug $SLUG) — the ADR is epic-scoped
  ADR_DRAFT="$EPIC_ROOT/adr.md"
  if [ -f "$ADR_DRAFT" ] && grep -qE '^\*\*Status:\*\*[[:space:]]*Draft' "$ADR_DRAFT"; then
    # CR-001: claim ONCE, parse number + canonical path from the single `CLAIM-ADR: number=NNN path=...` line.
    CLAIM_OUT=$(python3 "$S/claim-id.py" adr "$EPIC_SLUG")   # atomic O_EXCL allocation (ADR-072) → e.g. ADR-117
    ADR_NUM=$(printf '%s' "$CLAIM_OUT" | sed -n 's/^CLAIM-ADR: number=\([0-9]\{3,4\}\).*/\1/p')
    ADR_PATH=$(printf '%s' "$CLAIM_OUT" | sed -n 's/^CLAIM-ADR: .*path=\(.*\)$/\1/p')
    if [ -z "$ADR_NUM" ] || [ -z "$ADR_PATH" ]; then
      echo "ERROR: could not parse claim-id output: '$CLAIM_OUT'" >&2; exit 1
    fi
    # CR-003: write the finalized Draft body INTO the canonical claim-id file ($ADR_PATH — currently a
    # Proposed stub) AND keep a run-folder copy at $D/adr.md for the implementer. The canonical file is the
    # one adr-index.py scans, so it MUST carry the real Accepted content, not the stub.
    cp "$ADR_DRAFT" "$D/adr.md"
    git mv "$ADR_DRAFT" "$ADR_PATH" 2>/dev/null || mv -f "$ADR_DRAFT" "$ADR_PATH"
    python3 - "$ADR_PATH" "ADR-$ADR_NUM" "$EPIC_SLUG" <<'PY'
import sys, re
path, num, slug = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f: t = f.read()
# CR-002: drop the dead `\b` — `# ADR (Draft) — slug` → `# ADR-NNN — slug`. After ')' comes a space (both
# non-word) so `\b` asserted no boundary and never matched. The title half-a writes is `# ADR (Draft) — <slug>`.
t = re.sub(r'^# ADR \(Draft\)(.*)$', f'# {num} — {slug}', t, count=1, flags=re.M)
t = re.sub(r'^\*\*Status:\*\*[ \t]*Draft.*$', f'**Status:** Accepted ({num}, finalized at /orchestrated build-start — ADR-116 D1 half-b)', t, count=1, flags=re.M)
with open(path, "w", encoding="utf-8") as f: f.write(t)
print(f"finalized staged ADR → {num} (Draft → Accepted) at {path}")
PY
    git add "$ADR_PATH" "$D/adr.md"
    echo "ADR-finalize: claimed ADR-$ADR_NUM, wrote canonical $ADR_PATH (Accepted, was Draft) — PLANNED build (ADR-116 D1 half-b)"
  fi
elif [ -d "$JAM_DIR" ]; then
  # JAM → BUILD DIRECT (ADR-051 §4 skip-spec edge + §3a move-on-advance). No graduated spec; the jam
  # IS the intent. Move the whole jam folder into the run (README.md = converged brief; source/ +
  # findings/ ride along as deep context), then seed prompt.md/task from the README — NO hand-authored
  # brief. TICKETS_JSON stays null → the engine's cto→architect→pm-spec→decompose chain does the spec
  # work live (the spec is happening now; that's why it skips docs/step-3-specs/ and lands in pipeline directly).
  git mv "$JAM_DIR"/* "$D"/ 2>/dev/null || mv "$JAM_DIR"/* "$D"/
  rmdir "$JAM_DIR" 2>/dev/null || true
  echo "moved jam $JAM_DIR → $D (jam→build direct; engine decomposes in place)"
  # Converged brief = README.md (fallback index.md); seed it verbatim as the intent — no paste, no
  # feasibility guard (the jam already grounded it; symmetric to /roadmap §8). Bash redirect (not the
  # Write tool) keeps the v1 PostToolUse auto-fire hook quiet, same as step 1's heredoc.
  JAM_BRIEF="$D/README.md"; [ -f "$JAM_BRIEF" ] || JAM_BRIEF="$D/index.md"
  if [ -f "$JAM_BRIEF" ]; then
    { echo "# $SLUG"; echo "Ticket key: <KEY>"; echo; cat "$JAM_BRIEF"; } > "$D/prompt.md"
    echo "seeded prompt.md from jam brief $JAM_BRIEF (no hand-authored brief)"
  fi
fi
```

- **When a graduated spec was moved in,** pass `$TICKETS_JSON` as the Workflow `args.tickets` (step 2). The
  engine then builds the **authored** ticket graph and **skips `[decompose]`** — the locked
  `depends_on` / `planned_files` / `gate_recommendations` are honored, not re-derived. Seed `prompt.md`
  (step 1) from `$D/$SLUG.md` + `$D/$SLUG-prompts.md` rather than ad-hoc intent.
  *(ADR-103 W1: the `# Wave:` schema now **renders** the `AC-NNN` acceptance atoms (`roadmap.js` `renderWaveSchema`)
  and `wave-manifest.py` parses them, so `acceptance` carries the real atom set through here — re-arming AC-COVERAGE
  on the graduated-spec path. Legacy plans without the field default to `[]`, which the engine still tolerates. pm-spec still runs in the chain.)*
- **Jam, no graduated spec?** (`/orchestrated <slug>` where `docs/step-2-planning/jam-<slug>/` exists but no
  `docs/step-3-specs/` entry) → the **jam-direct skip edge** fires: the jam folder moves into `$D`, `prompt.md`/`task`
  are seeded from the jam `README.md` verbatim (no brief to write), and `TICKETS_JSON` stays `null` so the
  engine decomposes live. This is the "I don't want to prepare a brief — the jam has the context" path: the
  jam advances jam→pipeline directly, skipping `docs/step-3-specs/` (the spec work happens *inside* the engine).
- **Neither?** (truly ad-hoc — no spec, no jam) → `TICKETS_JSON` stays `null`; nothing moves; the engine
  decomposes from the intent you authored in step 1. All three (spec move, jam move, ingest) are conditional.
- **Per-wave granularity.** Only `$SLUG`'s own `waves/<slug>/` folder moves; sibling un-built waves under the
  same epic stay in `docs/step-3-specs/<epic-slug>/` until their own builds begin.

### 2. Launch the Workflow engine

Invoke the `Workflow` tool with the resolved orchestrated-script `scriptPath` (per the path-resolution
note above: `.claude/scripts/workflows/orchestrated.js` in a consumer, else
`core/scripts/workflows/orchestrated.js`) and `args`:

```json
{
  "runDir": "$D",
  "repoRoot": "<abs repo root>",
  "task": "<the wave intent + acceptance criteria>",
  "waveBaseRef": "$WAVE_BASE_REF",
  "baseSha": "$WAVE_BASE_REF",
  "decompose": true,
  "hasUi": $HAS_UI,
  "contextual": null,
  "concurrency": 3,
  "tickets": "$TICKETS_JSON",
  "waveSpecs": $WAVE_SPECS_JSON,
  "specMarkdown": $SPEC_MD_JSON
}
```
*(PEC-T3/T4: `waveSpecs` (raw JSON, not a quoted string) carries the on-disk wave-spec markdown the engine's
`detectPlanned()` parses; with the ingested `tickets[]` present it classifies the folder **PLANNED** and
SKIPS the advisory preamble + decompose — slicing happened once at `/roadmap`. `specMarkdown` is the spec
narrative the gates read when pm-spec is skipped. Both default `null` on the ad-hoc / jam-direct path
(NOT-PLANNED → the full preamble runs, exactly as before — the fail-closed direction.)*
*(ADR-104: `hasUi` is the wave's UI-surface carry — `$HAS_UI` from the ingested manifest's `has_ui` (else
`false`). The engine's `wantUi` resolves to `_a.ui === true || _a.hasUi === true || hasUiSurface(_a.tickets)`,
so even a `false`/absent carry still fires ui-spec + ui-review when the wave's `planned_files` are a UI
surface. Pass `"ui": true` ONLY as a manual operator override to force the visual path on.)*
*(`tickets` = `$TICKETS_JSON` from step 1.5: the parsed authored graph when a graduated spec was moved in,
else `null`. When non-null the engine skips `[decompose]` and builds the authored tickets — `decompose`'s
value is then moot.)*

- `concurrency` (ADR-045) caps how many ticket implementers run at once: `1` = sequential (watchable /
  overnight throttle), `K` = cap at K, `null`/`"parallel"` = unbounded (engine still ~16). **Default `3`.**
  This caps *width* (defect B — scale/watchability); a wave > ~12 tickets logs a soft "epic-shaped → roadmap →
  waves (T10)" note.
- **Single-call `full` (this step) vs. the dependency-wave loop (step 2′):** the single `full` call above
  implements ALL tickets off one wave base — correct for a **flat / dependency-shallow** wave (no `depends_on`
  edges, or edges only between tickets safe to build in parallel). For a wave with **dependency DEPTH** (a
  ticket uses a symbol another ticket creates), use the **wave loop (step 2′)** so each dependency level is
  integrated before the next level's implementers spawn off it (T16/ADR-045 — fixes "dependent built blind").
- `decompose: true` (default) → `spec-decomposer` emits `tickets[]`. Pass an explicit `tickets`
  array to skip decomposition — this is the **graduated-spec path** (step 1.5 ingests the locked `# Wave:`
  schema into `$TICKETS_JSON`), and also the operator-supplied-plan path. `decompose: false` → single ticket
  = whole task.
- `ui: true` → run `ui-spec` after pm-spec.
- `contextual` (string | array) → extra gate reviewers by file type (D5). **security-auditor is
  auto-added** by the script on any auth/secret/migration surface (ADR-018 crit-3) — you do not
  need to request it.
- `baseSha` → the wave-branch tip SHA captured at invocation (`$WAVE_BASE_REF` is exactly
  `git rev-parse HEAD` on the wave branch from step 0, so pass it for both). The engine embeds it as
  an **unconditional STEP 0** in the wave-build brief (`git fetch . && git reset --hard <baseSha>`
  before any work) so the single in-place wave-builder starts from the dispatch-time wave-branch tip
  rather than stale session-start state (ADR-085 D2). Absent → the brief falls back to the protocol
  base-check guard language; the engine has no git/FS access, so the SHA must arrive in `args`
  (ADR-039 contract 2).

The chain runs autonomously and returns a structured payload (`cto`, `archPre` (with the ADR),
`spec`, `tickets`, `implementResults`, `integrate`, `review`, `conformance`, `contextualReviews`,
`archFinal`, `allFindings`, `criterionFindings`, `surfaceRequired`). The `integrate` step has
already merged each ticket's commit into the wave branch (staleness-guarded).

### 2′. Dependency-wave loop (multi-level waves — T16 / ADR-045)

Use this **instead of** the single `full` call (step 2) when the wave has dependency DEPTH. The engine
exposes three phase modes (`mode: 'plan' | 'wave' | 'finalize'`); the orchestrator drives **N sequential
`Workflow` calls** in its turn, persisting the manifest between calls so a mid-loop death is resumable.
This is necessary because native worktree isolation roots every worktree at a **session-stable base per
Workflow call** — so re-rooting wave *i+1* off wave *i*'s integrated result requires a **separate** call
with an advanced `waveBaseRef`. (Engine-side modes are behaviorally tested in
`test-orchestrated-behavioral.mjs`; the re-root itself is confirmed by a live multi-level run.)

**a. Plan call** — `Workflow` with `args { …, mode: "plan" }`. Returns
`{ tickets, waveLevels, specMarkdown, adrMarkdown, exploreMap, gateReviewers }`. Persist the plan:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
# tickets[] -> manifest (the durable resume substrate); also persist spec/adr artifacts now
$S/run-manifest.py set-tickets "$D/manifest.json" --tickets-file /tmp/plan-tickets.json
```

`waveLevels` is `[[keys@L0],[keys@L1],…]` — strictly-ordered dependency levels.

**b. Per wave level `i` (0…N-1)** — `Workflow` with
`args { …, mode: "wave", tickets: <the ticket OBJECTS whose key ∈ waveLevels[i]>, specMarkdown, exploreMap,
waveBaseRef: <CUR_BASE>, gateBaseRef: "$WAVE_BASE_REF", concurrency }` where:
- `CUR_BASE` = `"$WAVE_BASE_REF"` for level 0, else the **prior** wave call's returned `integrated_head`
  (this is the re-root — level `i+1`'s worktrees branch off level `i`'s integrated result, fixing AC-4).
- On return `{ implementResults, integrate, integrated_head }`, **persist each ticket** before the next call
  (AC-5 durability): `for each r in implementResults: $S/run-manifest.py set-ticket "$D/manifest.json" "$r.ticket_key" complete --sha "$r.sha"`.
- A wave that returns `surfaceRequired` / a short-circuit (refused/blocked/stale) → **halt + surface**; the
  manifest already records completed tickets, so `/resume <slug>` continues from the first non-complete level.
- Carry `integrated_head` forward as the next level's `CUR_BASE`.

**c. Finalize call** — once ALL levels are integrated, `Workflow` with
`args { …, mode: "finalize", tickets: <ALL tickets>, specMarkdown, adrMarkdown, gateBaseRef: "$WAVE_BASE_REF",
gateReviewers }`. Runs the batch-gate + AC coverage check + architect-final **once** over the full
integrated wave (`gateBaseRef..HEAD`). Its return feeds steps 3–5 exactly like the `full` return.

> The gate diff base is the **stable** `gateBaseRef` (the original wave base), while each wave's staleness
> guard uses the **advancing** per-level base (AC-6 — the two bases are split so cross-wave merges aren't
> false-refused).

### 3. Persist artifacts (FLAG-1 — **mandatory, never skip**)

Write the workflow return to a temp file, then:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
$S/persist-run-artifacts.py --run-dir "$D" --slug "$SLUG" \
  --task "<short wave label>" --return-file /tmp/orchestrated-return.json
```

This materializes `cto-evaluation.md`, **`adr.md`** (the pre-pass ADR), `spec.md`,
`ui-spec-addendum.md` (if UI), `findings/*` (explore, per-ticket implementer reports, integrate,
gate agents, architect-final), `run-log.md`, and the **thin manifest** `manifest.json` with a
populated `tickets[]`. Inspect the printed `run_status`.

### 3.5. Ledger the examiner fold-in dispatch(es) — **mandatory if `examinerDispatches[]` is non-empty** (ADR-088 D4)

The engine runs an **examiner fold-in pass** before the wave-build (PEC-T14 / ADR-112 Wave 5): ONE examiner
(Fable seat) reviews the build-bound spec, and its findings are folded into the spec by a `pm-spec` re-dispatch.
It is **fold-in only — no halt, no new halt class** (a severe `RETHINK` verdict rides the existing findings /
decision-log surface, folded best-effort). The pass is **skipped on a PLANNED folder** (it was authored by
`/roadmap`, whose funnel-tail already examined the spec — no double-examine).

Because the engine has **no filesystem** (ADR-039 contract 2) it cannot write the Fable ledger. For **each**
entry in the return's `examinerDispatches[]`, the orchestrator appends **one** `_fable-spend.jsonl` line
post-run — the binding ADR-088 D4 duty ("if you dispatch an examiner outside `/examine`, you append the ledger
line yourself at the dispatch site"). REUSE the `/examine` O_APPEND snippet VERBATIM (`core/skills/examine/SKILL.md`
§d) — do not re-author the JSON. Read `in_tokens`/`out_tokens`/`cache_*` from the examiner's agent journal (the
`measure-run.sh --per-agent` source — the ledger's second reconcilable source); `TARGET` = the entry's `target`,
`VERDICT` = its `verdict`:

```bash
TS="$(date -u +%FT%TZ)"
OVER=false; if [ "$IN_TOKENS" -gt 90000 ] || [ "$OUT_TOKENS" -gt 4000 ]; then OVER=true; fi
jq -nc --arg ts "$TS" --arg target "$TARGET" --arg session "$SESSION" --arg verdict "$VERDICT" \
  --argjson in_tokens "$IN_TOKENS" --argjson out_tokens "$OUT_TOKENS" \
  --argjson cache_create "$CACHE_CREATE" --argjson cache_read "$CACHE_READ" --argjson over "$OVER" \
  '{ts:$ts,agent:"examiner",target:$target,in_tokens:$in_tokens,out_tokens:$out_tokens,cache_create:$cache_create,cache_read:$cache_read,session:$session,verdict:$verdict,over_envelope:$over}' \
  >> docs/step-3-specs/_fable-spend.jsonl
```

> **Sibling arm (AC-034 — now BUILT, post-Wave-5).** The `/sweep` convergence pass runs its OWN examiner
> fold-in (thesis + cluster/move correctness, auto on each convergence, fold-in only) — see
> `core/skills/sweep/SKILL.md` § "Jam convergence" step 4b. `/sweep` ledgers it itself (orchestrator-direct).
> The three engine examine passes (roadmap funnel-tail, orchestrated pre-build, `/sweep` convergence) are the
> full set.

### 4. Consolidated surface (only if `surfaceRequired`)

- `surfaceRequired: false` → auto-dispose: all findings are `criterion_match: none`. Proceed to commit.
- `surfaceRequired: true` → surface **once**, batched: print the `criterionFindings` list with the
  recommended disposition per item, and **halt** (manifest is `surfaced`; the offending phase/ticket
  is `blocked`). Resume later via `/resume <slug>`. Do NOT loop per-finding (ADR-036). The five
  ADR-018 criteria are the only halt reasons. A short-circuit (`stoppedAt: cto|architect-pre|
  implement|integrate`) is a material halt — present the verdict + options (e.g. CTO SIMPLIFY/DEFER/
  NO-GO; arch-pre REQUEST_CHANGES; a refused/blocked ticket; a stale-base integration refusal).

### 5. Wave-level commit + bookkeeping

The deliverable code is already on the wave branch (per-ticket commits merged by `integrate`).
The orchestrator commits the **orchestration artifacts** and records SHAs:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
git add "$D"                                   # run folder: prompt/adr/spec/findings/run-log/manifest
git commit -m "chore(wave-$SLUG): orchestration artifacts"
$S/run-manifest.py set-sha "$D/manifest.json" "$(git rev-parse HEAD)"
```

For a polished wave message, `@smart-commit` MAY be invoked (orchestrator-side). Pushing the wave
branch as backup is permitted (`git push origin "$WAVE_BRANCH"`). **The wave→main PR/merge is
operator-driven — never opened or merged automatically** (authorization boundary).

### 6. Auto-closeout — the build-done seam auto-advances (VPH-W1A / ADR-114 D1)

Once the wave reaches `done` (artifacts committed above), wire the **single-hop** close-out so the
finished run no longer sits in `step-5-pipeline/` — location-is-status (ADR-087) made automatic for the
build-done seam. The mover already exists and is invoked by `/resume` + `/merge-orchestrator §5e`; here it
is wired into the orchestrated completion path:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
python3 "$S/closeout-run.py" "$D"   # single-hop: step-5-pipeline/<date>/<name> → step-6-done/<date>/<same-name>
```

- **Never pass `--skip-scope-check` and never `--force-partial`.** The ADR-103 OUT-bookend scope gate must
  run intact: a run with an unaccounted decided atom (`tickets[].status != complete`) refluxes into
  `docs/step-1-ideas/from-<run-slug>/` and **HELDs the move** (close-out exits 3, run stays visibly in
  `step-5-pipeline/`). The HOLD is the safety property — let the exit-3 signal propagate (the operator
  triages the refluxed atoms); never auto-bypass it.
- **Single-hop, not two-hop.** The target is `step-6-done/<date>/<same-name>/` — there is no
  `built-pending-merge/` stage (ADR-114 ejected that unverified two-hop framing; `closeout-run.py` is a
  single-hop mover).
- **Stage-only (ADR-105).** The close-out STAGES the move (`git mv`); **the operator commits it.** The
  wired path never commits/pushes/`reset --hard`, and the **wave→main merge stays operator-only** — the
  move landing in `step-6-done/` is staged, reviewable, and revertible before anything reaches main.
- Idempotency is handled by the mover (an already-moved folder under `step-6-done/` is a no-op).

After the move, regenerate the dashboard (`python3 "$S/docs-index.py"`).

## Phase sequence

`cto → architect-pre (writes ADR) → pm-spec → [examine fold-in (NOT-PLANNED only)] → [ui-spec] →
[decompose] → explore → ∥implement-per-ticket (worktree) → integrate (staleness-guarded) →
batch-gate (code-reviewer ∥ spec-conformance [∥ contextual]) → architect-final (integration)`

The **[examine fold-in]** step (PEC-T14 / ADR-112 Wave 5) runs ONE examiner over the build-bound spec before
the build and folds its findings in (fold-in only, no halt — AC-033); it is **skipped on a PLANNED folder**
(roadmap's funnel-tail already examined it). Each dispatch is ledgered post-run (step 3.5).

**Both architect passes (D4):** the pre-pass authors the ADR + validates the approach is sound
*before* implementation; the final pass validates the *integrated* wave composes correctly — it is
the v2 net for the parallel-implement seam (the cross-ticket integration risk that
one-implementer-per-wave structurally prevented in v1, ADR-028).

## Default-straight: `/orchestrated <folder>` builds ALL waves, front-loaded (PEC-T4 / ADR-112)

`/orchestrated <folder>` builds **every wave in the folder straight (front-loaded)** by default — one build
pass over the planned waves, no per-wave re-planning. This is the autonomous-to-completion default
(ADR-105/029/054): detection → build → gate within the run, with the **only** operator gate being the
shared-state lever (wave→main merge / push). There is **no manual checkpoint between plan and build**.

**Plan-detection makes the plan-work run at most once.** When the folder is already planned (every wave spec
parses to `## Tickets` / `### <KEY>:` blocks and the ingested `tickets[]` is passed), the engine SKIPS the
advisory preamble (cto / architect-pre / pm-spec / [ui-spec]) **and** decompose — slicing lives once in
`spec-decomposer` via `/roadmap`; the builder just consumes `tickets[]`. A raw cluster (no `## Tickets`) runs
the preamble; an ambiguous/partial folder fails **closed** to NOT-PLANNED (runs the preamble) — building
unplanned is the dangerous direction.

**Interleave is opt-in, not a per-wave flag.** Re-planning each wave against the *built* reality of prior
waves is the `/orchestrate-epic` door (it sets `crossWavePrior`), chosen for a whole epic when the operator
indicates it — NOT a per-wave selector. There is deliberately **no per-wave build-mode selector tag**: the
choice is made once at the whole-epic level (`/orchestrated` front-loads all waves; `/orchestrate-epic`
re-plans per wave), which keeps the engine simple and the plan-detection signal deterministic.

## When to use orchestrated vs nimble

Nimble = one well-understood feature/fix one implementer completes end-to-end. Orchestrated = a
multi-ticket wave needing CTO + ADR + decomposition + parallel implement + integration review. If a
nimble `implementer` REFUSES for scope, escalate here.

## Resume

A wave interrupted at a surface (or across sessions) resumes via `/resume <slug>` — it reads the
thin manifest's `tickets[]` and continues from the first non-complete, dependency-ready ticket.

**Wave-loop resume (step 2′):** because each wave level persists its tickets' `complete` status + SHAs to
the manifest *before* the next call, `/resume` re-enters the loop at the **first dependency level with a
non-complete ticket** — completed levels are NOT re-implemented or re-integrated. Resume recomputes
`waveLevels` from `tickets[]`, finds the lowest level containing an incomplete ticket, sets `CUR_BASE` to
that level's base (the prior completed level's integrated HEAD, recoverable from the wave branch / the last
completed ticket's commit), and continues `wave` calls from there → `finalize`. A single-call `full` run has
nothing to resume mid-flight (it re-runs); the wave loop is what makes cross-window durability real (AC-5).
