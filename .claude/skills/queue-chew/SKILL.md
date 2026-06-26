---
name: queue-chew
description: "Drain the autonomous build queue serially — /queue-chew runs a session-loop that picks the earliest dep-ready BUILD-KINDS job from docs/step-4-queue/pending/, launches one top-level Workflow per item on a linear stack, awaits it, and moves it to done/. Build kinds only; never merges to main."
user_invocable: true
---

# /queue-chew — the serial session-loop consumer of the autonomous work queue (ADR-122; ADR-124 entry-as-folder)

`/queue-chew` is the **consumer half** of the autonomous work queue. The producer (`/queue add`, Wave 1)
**move-on-advances** a build-job entry **FOLDER** into `docs/step-4-queue/pending/<entry>/` (the moved source
artifact + `sidecar.json`); this daemon is the only **mover** of entries through the
`pending/ → running/ → {done/ | failed/}` lifecycle (a completed item terminates in **`done/` on success**
or **`failed/` on a non-zero/dirty outcome** — never `done/` for a failure). Together they are a
**files-as-mailbox** producer/consumer: no shared mutable JSON is written by both sides, so there is **no
two-writer race** by construction.

The daemon drains the queue **strictly serial** — exactly one Workflow in flight at a time — onto a
**linear accumulating branch stack** (`main → A → B → C`), and it accepts **BUILD KINDS ONLY**
(`{orchestrated, nimble, chain, loop}`). It is a `/loop`-style **chew session**, NOT a Workflow script.

> **The deterministic mechanics live in a SOURCEABLE LIB (ADR-124, binding).** This SKILL is the
> operator-facing doc; its **deterministic mechanics** (the pick, input validation SA-001/002/003, the
> `pending→running` drain, target resolution, the success/failure outcome branch, the park-vs-halt arbiter)
> are extracted into **`core/scripts/queue-chew-lib.sh`** — a shell lib the session **sources**. The lib is
> what `core/scripts/test-queue-chew-e2e.sh` exercises end-to-end (green = "a chew built a file"). The
> **REAL dispatch is the SESSION's, fired BETWEEN two deterministic lib halves (SHR3-T4)**: `qc_next`
> (before-dispatch: pick / SA-001/002/003 / allowlist / drain / target / readiness — NO dispatch) and
> `qc_settle` (after-dispatch: outcome branch / move / arbiter — takes `launch_rc`+`dirty` as ARGS). This
> session (the LLM) fires the real top-level `/orchestrated|/nimble|…` Workflow and BLOCKS/awaits its
> `<task-notification>` BETWEEN them — the bash lib **no longer pretends to dispatch** (the queue-v1.1
> green-gates-on-a-non-functional-daemon failure class is closed). `launch_workflow` is **demoted out of the
> production lib** — it survives ONLY as the e2e test stub (the test seam). This cleanly separates the
> testable deterministic mechanics (the lib) from the session-level launch/await (here). The lib is **sourced
> by a session WITH FS access** — it is NOT a no-FS Workflow script, so the architecture spine below holds.

> **Why this is a session loop and NOT a Workflow script (binding rationale — read first).**
> A `core/scripts/workflows/*.js` Workflow script **has no FS access** (ADR-039 — a script returns a
> payload and the orchestrator persists it; the script never touches the filesystem). It therefore
> **physically cannot poll** the live `docs/step-4-queue/pending/` folder for cross-session producer appends each
> iteration. A planning session may append a job folder to `pending/` while this chew session is mid-drain;
> only a session **with FS access** can see that newly-dropped entry on its next read. That is the whole
> reason the daemon is a **session loop** (it re-reads the folder from disk each iteration) and not a
> single wrapper Workflow. **no-FS → session-loop** is the architecture spine of this skill. The poll loop
> MUST live in a session with FS access; do not move it into a Workflow script. (The sourceable lib above
> is consistent with this: it is sourced INTO the FS-having session, not run as a Workflow.)

> **Substrate path resolution (consumer-safe — ADR-031).** The shipped scripts this skill reuses
> (`launch-manifest.py`, `orchestrated.js`) live at `core/scripts/…` when dogfooding inside claude-infra,
> but at `.claude/scripts/…` in a consumer repo. Resolve the prefix first:
> `S=.claude/scripts; [ -d "$S" ] || S=core/scripts`, then call `$S/<script>`.

---

## The shared-state floor (binding — ADR-105 / rules-git.md — security-gated)

The daemon runs **unattended**, so it MUST stay behind the shared-state autonomy floor at all times:

- **NEVER merge to main, open a wave→main PR, or push to main.** No daemon path runs `git push origin main`,
  `gh pr create`, `gh pr merge`, or any `--force` / `--force-with-lease`.
- The daemon **stacks branches and queues the merge lever for the operator.** Each drained item lands its
  build on a feature/wave branch in the linear stack; the wave→main merge is an **operator-driven**
  action at the operator's review point (rules-git.md), never the daemon's.
- A wrong autonomous call lands on a stacked feature branch — reviewable and revertible — and **nothing
  reaches a shared system** (remote main / prod) unattended (ADR-105 shared-state floor).

If any step below would cross this floor, the daemon **stops and surfaces** rather than acting.

---

## The iteration loop (AC-008)

`/queue-chew` runs a **session loop**. Each iteration does exactly this, in order:

1. **Re-read `docs/step-4-queue/pending/`** — a **fresh FS read every iteration**. This is the live cross-session
   poll; **never cache the queue in session memory.** A producer that move-on-advanced a job folder since
   the last iteration is seen here, on this read, and nowhere else. (Lib: `qc_pick_entry` iterates
   `pending/*/sidecar.json` — the entry-as-folder shape, ADR-124.)
2. **Pick** the **earliest-`seq`** entry whose `after` deps are **all already in `done/`**. `seq`, `after`,
   and **`target`** are read from the Wave-1 entry sidecar
   (`{label, verb, seq, after?, planned_files?, target, provides?, needs?}`); the daemon **reads** ordering,
   it does not compute it — placement is owned by `queue-order.py` (Wave 1). If no `pending/` entry is
   dep-ready, the daemon idles (or exits if `pending/` is empty — operator choice; see § Termination).
3. **`git mv` the entry FOLDER `pending/<entry>/ → running/<entry>/`** — the **within-queue drain** (see §
   Within-queue drain). The whole entry folder moves (the artifact travels with it). Moving it out of
   `pending/`'s glob range is what gives **glob-never-re-picks** idempotency: a second read of `pending/`
   will not re-pick it. The build target is then `running/<entry>/<sidecar.target>` (default `target = "."`
   = the entry folder; ADR-124 — the **in-queue artifact IS the build input**, NOT a dead `.spec/.target`
   external path).
4. **Launch ONE top-level Workflow** for that item — with its build base ref (`baseSha`) set to the
   **prior completed item's branch tip** (first item roots off `main`; see § Linear stack). This is the
   **launch-and-await** call site (AC-014).
5. **Await** the launched Workflow's `<task-notification>` completion **before doing anything else**
   (serial; AC-009). The blocking await IS the serialization mechanism — a session skill that fires a
   top-level Workflow **blocks** on that call, and that block is the await (the `/loop-task` → ralph
   pattern).
6. **Branch on the build OUTCOME before any move** (CR-001/002). On **SUCCESS** (`launch_rc == 0` AND a
   clean tree) `git mv` the entry `running/ → done/`, set `launch-manifest.py features[].status = done`, and
   **advance the linear-stack base** (`PRIOR_TIP = NEW_TIP`). On **FAILURE** (`launch_rc != 0` OR a dirty
   tree) `git mv` the entry `running/ → failed/` (the NEW terminal failure sink — NOT `done/`), set
   `status = failed`, **do NOT advance the base** (the next item stacks on the last GOOD tip), then run the
   park-vs-halt arbiter (skip the failed item's declared dependents; HALT on a dirty/broken base, PARK on a
   clean isolated failure). See § Runtime status + § The park-vs-halt arbiter.
7. **Pop the next** — back to step 1 (re-read the folder; do not reuse a cached list).

### The launch-and-await call site (AC-014 — WIRE-TO-CONSUMER, grep-visible)

The loop **actually fires** the launch for each dep-ready item and **awaits** its completion before
advancing — it does not merely describe launching. The call site, in the loop body:

```bash
# --- queue-chew iteration: SOURCE the lib → pick → mv to running/ → LAUNCH + AWAIT → mv to {done,failed}/ ---
S=.claude/scripts; [ -d "$S" ] || S=core/scripts

# SOURCE the deterministic mechanics lib (ADR-124). The pick, SA-001/002/003 input validation, the within-
# queue drain, target resolution (TARGET = docs/step-4-queue/running/<entry>/<sidecar.target>), the outcome branch,
# and the park-vs-halt arbiter all live in queue-chew-lib.sh and are unit-tested by test-queue-chew-e2e.sh.
. "$S/queue-chew-lib.sh"

# FLEET_MANIFEST — the launch-manifest.py-managed fleet manifest for THIS queue-chew run. It is the
#   runtime-truth authority (features[].status) the render-trigger writes via `launch-manifest.py set
#   --path "$FLEET_MANIFEST" …` and the BUILD-STATUS regen reads. Resolved ONCE per run, co-located with
#   the run's autonomous-decisions-log.md under the queue-chew run dir — mirroring how /launch resolves
#   $FLEET (docs/step-5-pipeline/<date>/<HHmm>-FLEET-<slug>/fleet.json, launch/SKILL.md L63). It points at
#   the active queue-chew run's fleet manifest; `launch-manifest.py init` creates it on first iteration.
RUN_DIR="docs/step-5-pipeline/$(date +%Y-%m-%d)/$(date +%H%M)-QUEUE-chew"   # this drain run's folder (decision log + manifest live here)
FLEET_MANIFEST="$RUN_DIR/fleet.json"                                        # the launch-manifest.py-managed manifest this daemon reads/writes
mkdir -p "$RUN_DIR" docs/step-4-queue/pending docs/step-4-queue/running docs/step-4-queue/done docs/step-4-queue/failed   # idempotent; mint the lifecycle folders + run dir (docs/ is not distributed to consumers)

# --- launch-manifest.py SEQUENCE (AC-005, F-002 "no runtime API discovery" — encoded LITERALLY) ----------
# The manifest mutation order is FIXED and unambiguous, so the daemon never discovers the API at runtime:
#   1. `init --slug` ONCE per run (first iteration only) — mints $FLEET_MANIFEST with an empty features[].
#   2. per item, `add <label>` BEFORE `set <label> <status>` — `add` registers the feature row; `set`
#      mutates it. `set` is NEVER the first manifest touch for a label: launch-manifest.py cmd_set does
#      `_feat(m,label) or _die("unknown feature label")`, so a `set` on a never-added label HARD-FAILS by
#      design. The add-before-set invariant is what makes that failure structurally impossible (F-002).
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
$S/launch-manifest.py init --slug "queue-chew-$(date +%Y%m%d-%H%M%S)" --path "$FLEET_MANIFEST"   # ONCE per run — mint the manifest (idempotent on re-run via --path; first manifest touch overall)

# --- WORKTREE ISOLATION (SHR3-T3 / ADR-046, binding — security-relevant) -------------------------------
# The chew daemon runs UNATTENDED and AUTONOMOUSLY, so it is an autonomous actor (CLAUDE.md / ADR-046): it
# MUST establish + use a DEDICATED git worktree BEFORE any dispatch and target THAT worktree for all of its
# git operations — NEVER the operator's interactive main repo root. A background build that flips HEAD
# (`git rev-parse HEAD` / a reset / a merge) in the operator's tree would corrupt the operator's live
# session. Isolating the daemon in its own worktree means its HEAD/tree reads (and any launched build's HEAD
# mutation) land on the worktree branch, leaving the operator's interactive HEAD untouched.
#   * `qc_worktree_dir` (queue-chew-lib.sh) is the SEAM: with QC_WORKTREE set, the lib's qc_git reads
#     (`qc_git rev-parse HEAD` / `qc_git status --porcelain`) target the worktree, not the operator's tree.
#   * ADR-062 §3 NON-GOAL: this isolation is for AUTONOMOUS ACTORS ONLY (this chew daemon + a nimble run
#     launched from this background context). The orchestrated IN-PLACE wave-builder is deliberately NOT
#     isolated — do not add a worktree to it (that is by design; cite ADR-062 §3).
QC_WORKTREE="$(git rev-parse --show-toplevel)/.worktrees/queue-chew-$(date +%Y%m%d-%H%M%S)"
git worktree add --detach "$QC_WORKTREE" HEAD     # dedicated worktree off the current tip; daemon git ops target it
export QC_WORKTREE                                # qc_worktree_dir / qc_git in the lib resolve to this path
PRIOR_TIP=$(git -C "$QC_WORKTREE" rev-parse HEAD)  # first item roots off the WORKTREE's tip (not the operator's HEAD); advanced SUCCESS-ONLY
QC_SKIP=""                                      # CR-002 skip-sink (Wave 4): entries REJECTED/REFUSED this run —
                                               # qc_pick_entry excludes them so the daemon advances + reaches
                                               # WRAP instead of re-picking an un-buildable entry forever.

# ===== DAEMON WIDTH/TIME GUARD (ADR-132 D-4 / AC-016) — the overnight-window resource cap. =====
# Build-by-default means an unattended drain builds raw plans unless opted out; the WIDTH/TIME GUARD bounds
# HOW MUCH it builds in one overnight window. This is RESOURCE PROTECTION, NOT a consent question (the
# routing verb at /queue add is the consent; the producer attended-confirm in queue/SKILL.md, D3, is the
# consent point). The guard is a REAL, NAMED, CONSULTED mechanism (security-auditor verifies it gates, not a
# defined-but-unread stub):
#   * WIDTH CAP  — QUEUE_MAX_BUILDS (default 8): the max number of BUILD dispatches this drain performs.
#     Serial daemon ⇒ width = item-count, not literal concurrency; 8 caps the accumulated unreviewed build
#     on the linear stack per window (a defensible "one overnight's worth" — large enough for a real evening
#     queue, small enough that a runaway producer cannot stack 50 raw-plan builds before morning review).
#   * TIME WINDOW — QUEUE_WINDOW_HOURS (default 8): the wall-clock bound on the overnight window; once
#     elapsed, the daemon stops dispatching NEW items and WRAPs (an in-flight build is never interrupted —
#     the bound gates the NEXT pick, never a kill). 8h ≈ a real overnight window.
# On either cap the daemon WRAPs (stacks-and-stops cleanly) — it NEVER merges/pushes (shared-state floor).
QUEUE_MAX_BUILDS="${QUEUE_MAX_BUILDS:-8}"        # WIDTH CAP — max build dispatches per overnight drain
QUEUE_WINDOW_HOURS="${QUEUE_WINDOW_HOURS:-8}"    # TIME WINDOW — overnight wall-clock bound (hours)
QC_BUILDS_DONE=0                                 # running count of BUILD dispatches this drain (consulted by the width guard)
QC_WINDOW_START="$(date +%s)"                    # window origin (consulted by the time guard)
QC_WINDOW_END=$(( QC_WINDOW_START + QUEUE_WINDOW_HOURS * 3600 ))

while : ; do
  # ----- WIDTH/TIME GUARD CONSULTATION (ADR-132 D-4) — checked BEFORE picking the next item, so an in-flight
  #       build is never interrupted; the bound gates the NEXT pick. Either cap → WRAP (stack-and-stop). -----
  if [ "$QC_BUILDS_DONE" -ge "$QUEUE_MAX_BUILDS" ]; then
    echo "queue-chew: WIDTH-GUARD WRAP — reached QUEUE_MAX_BUILDS=$QUEUE_MAX_BUILDS build dispatches this overnight window; stacking-and-stopping (resource cap, NOT a merge). Remaining items stay queued for the next drain." >&2
    break
  fi
  if [ "$(date +%s)" -ge "$QC_WINDOW_END" ]; then
    echo "queue-chew: TIME-GUARD WRAP — overnight window (QUEUE_WINDOW_HOURS=$QUEUE_WINDOW_HOURS) elapsed; stopping NEW dispatches (any in-flight build already completed). Remaining items stay queued for the next drain." >&2
    break
  fi

  # ===== STAGE-KIND PRE-ROUTE (ADR-132 D-2, AC-014 routing / AC-015 wire-to-consumer) — the settle/route
  #       branch for a SECOND, DISJOINT lifecycle. A STAGE-kind (STAGE_KINDS = {"roadmap"} from
  #       launch-manifest.py, D1) is NOT a build — its output is a SPEC, not a merged branch — so it MUST
  #       diverge from the build path BEFORE qc_next's BUILD-KINDS allowlist (qc_validate_kind) would reject
  #       it. This is a SESSION-level route (the lib stays build-only — mirror, don't reuse — exactly like the
  #       gate-presence settle check A2, which also lives here in the session, not the lib). The membership is
  #       CONSUMED BY ROUTING here, visible at the settle/route branch: a STAGE entry skips qc_archive_settled,
  #       is NOT moved to done/ as a terminal, and does NOT auto-chain plan->build.
  #
  #   PEEK the next dep-ready pending entry's verb (the sidecar `verb` field — a session-readable file) WITHOUT
  #   draining it through the build path. STAGE_KINDS is the source of truth (D1); the session reads it from
  #   launch-manifest.py so producer and daemon agree on the taxonomy.
  STAGE_KINDS="$(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("lm","'"$S"'/launch-manifest.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(" ".join(sorted(m.STAGE_KINDS)))')"
  QC_PEEK_ENTRY="$(qc_pick_entry)"                 # the next dep-ready entry the build loop WOULD pick (fresh FS read)
  if [ -n "$QC_PEEK_ENTRY" ]; then
    QC_PEEK_KIND="$(qc_sidecar_field "$QC_PEEK_ENTRY" verb)"
    # MEMBERSHIP CHECK — is the next entry a STAGE-kind? (sweep is NOT in STAGE_KINDS, so it falls through to
    # the build path below where qc_validate_kind still REJECTS it — Phase-1 boundary preserved.)
    case " $STAGE_KINDS " in
      *" $QC_PEEK_KIND "*)
        # ===== STAGE ROUTE — produce a SPEC, do NOT build, do NOT archive, do NOT auto-chain. =====
        # (i) OUTPUT IS A SPEC, already persisted to step-3-specs/ by roadmap.js. The daemon ENFORCES the
        #     routing rule (no new persist machinery): it dispatches the STAGE recipe (`/roadmap` for a
        #     `roadmap` entry — core/skills/roadmap/SKILL.md, Phase E/W), whose terminal is the canonical
        #     roadmap.md / wave spec under docs/step-3-specs/<epic>/. The session AWAITS its completion.
        # (ii) NO TERMINAL done/-MOVE + SKIPS qc_archive_settled. A STAGE entry's terminal is NOT a merged
        #     build, so it is NOT moved to done/ (the build terminal) and is NEVER fed to qc_archive_settled
        #     (which is build-archival → step-6-done/queue/). The STAGE entry drains pending/ → a STAGE
        #     terminal (staged/<entry>/) that the archival sweep never reads — it stays OUT of the
        #     done/→step-6-done/queue/ map entirely. The base (PRIOR_TIP) is NOT advanced (no build commit).
        # (iii) NO AUTO-CHAIN plan->build. THE SINGLE MOST IMPORTANT BEHAVIORAL CONTRACT OF THE STAGE-KIND:
        #     the daemon produces the spec and STOPS. It does NOT queue a build of the spec it just produced
        #     ("while we're here, build it" is exactly the failure this wave prevents) — THE MORNING HUMAN-
        #     REVIEW GATE IS THE VALUE. The two-pass flow is: overnight pass-1 produces builds + specs; the
        #     human reviews between passes; the human queues the reviewed specs as builds (ADR-132 D-2).
        echo "queue-chew: STAGE-ROUTE '$QC_PEEK_ENTRY' (kind=$QC_PEEK_KIND) — producing a SPEC to step-3-specs/ (no build, no archive, no auto-chain). The morning review gate IS the value." >&2
        #   --- dispatch the STAGE recipe (LLM-driven, blocks on the <task-notification>); DELEGATE to the
        #       named recipe (core/skills/roadmap/SKILL.md), never inline its arg construction (AC-001) ---
        #   /roadmap --target "$QC_PEEK_ENTRY"   # produces docs/step-3-specs/<epic>/ — the spec IS the output
        qc_drain_to pending staged "$QC_PEEK_ENTRY"   # within-queue STAGE terminal — NOT done/, NEVER archived
        QC_STAGED_LABELS="$QC_STAGED_LABELS $QC_PEEK_ENTRY"   # track STAGE-routed labels THIS drain (CR-001 WRAP surface): a
                                                             # build queued `after` one of these strands in pending/ (the STAGE
                                                             # label never enters qc_completed_labels()) — surfaced at end-of-drain.
        # F-001 (epic examiner, ADR-131-adjacent): this `set` is the FIRST manifest touch for a STAGE label —
        # there is intentionally NO `add` before it (the build path's add-before-set invariant, ADR-129/AC-005,
        # does NOT apply: a STAGE label is a spec job, not a build feature, and cmd_add rejects non-KINDS so
        # `roadmap` could never be add'ed anyway). It is non-stranding because Wave B's cmd_set UPSERT (ADR-130 D-4,
        # plain/ungated by design) creates the row. DO NOT re-gate that upsert (e.g. a `--create` flag) without
        # giving the STAGE route its own row-create path — re-gating would silently strand STAGE manifest rows here.
        $S/launch-manifest.py set --path "$FLEET_MANIFEST" --label "$QC_PEEK_ENTRY" --status done 2>/dev/null || true  # manifest label-keyed; status records the stage completed (the spec is reviewable)
        python3 "$S/docs-index.py" >/dev/null 2>&1 || true
        continue   # pop the next — the STAGE entry produced a spec and STOPPED (no build, no base-advance)
        ;;
    esac
  fi

  # ===== qc_next — the DETERMINISTIC BEFORE-DISPATCH half (SHR3-T4). NO dispatch happens in the lib. =====
  #   1. PICK earliest-seq dep-ready pending/<entry>/ (sidecar.after all in done/) — fresh FS read, NEVER cached.
  #   2. SA-001 entry folder-basename path-traversal guard + SA-003 label/kind shape-check (BEFORE any git mv).
  #   3. AC-010 BUILD-KINDS allowlist (fail-closed; a planning verb is REJECTED + LEFT in pending/).
  #   4. within-queue drain pending/<entry>/ → running/<entry>/ (glob-never-re-picks).
  #   5. SA-002 target resolution + guard: TARGET = running/<entry>/<sidecar.target>, validated UNDER docs/step-4-queue/
  #      (ADR-124 flipped the root from docs/step-3-specs/ to docs/step-4-queue/); a miss un-drains running→pending.
  #   5b. BUILD-READINESS ROUTING (ADR-132 D-3, posture FLIPPED): an `orchestrated` RAW PLAN BUILDS BY DEFAULT
  #       (choosing the verb at /queue add IS the consent); QUEUE_REFUSE_RAW_PLAN=1 is the opt-OUT to refuse.
  # On rc 0 (ready-to-dispatch) qc_next has set QC_LAST_ENTRY/QC_LAST_LABEL/QC_LAST_TARGET/QC_LAST_KIND — the
  # session reads them to drive the REAL dispatch. (qc_run_one is RETIRED — SHR3-T4 split it across the dispatch.)
  #
  # BUILD-BY-DEFAULT posture (ADR-132 D-3): translate the opt-OUT into the classifier's existing knob BEFORE
  # qc_next runs. Build a raw plan unless the operator opted OUT (QUEUE_REFUSE_RAW_PLAN=1 retires the old
  # opt-IN QUEUE_ALLOW_RAW_PLAN). The width/time guard (§ Daemon width/time guard) caps HOW MUCH builds —
  # resource protection, NOT a second consent question.
  if [ "${QUEUE_REFUSE_RAW_PLAN:-0}" = "1" ]; then
    unset QUEUE_ALLOW_RAW_PLAN        # opt-OUT → the readiness classifier REFUSES a raw plan (un-drains it, leaves it queued)
  else
    export QUEUE_ALLOW_RAW_PLAN=1     # DEFAULT → the readiness classifier PROCEEDS to build a raw plan unattended (consent = the routing verb)
  fi
  qc_next
  rc=$?
  case "$rc" in
    2) break ;;                                # nothing dep-ready → WRAP / idle / exit (see § Termination)
    3) QC_SKIP="$QC_SKIP $QC_LAST_ENTRY"; continue ;;   # REJECTED (validation/allowlist/SA-002) → skip-sink, pop next
    4) QC_SKIP="$QC_SKIP $QC_LAST_ENTRY"; REFUSED_RAW=$((${REFUSED_RAW:-0}+1)); continue ;;  # raw plan REFUSED (Fork B) → skip-sink + WRAP count
  esac
  # rc == 0 — READY-TO-DISPATCH. The entry is in running/, its target is resolved + validated.

  # --- ADD-BEFORE-SET (AC-005, F-002): register this item's manifest row BEFORE any `set` on it. The
  #     per-item `add` is the FIRST manifest touch for $QC_LAST_LABEL — `set` (at qc_settle's render-trigger,
  #     :212) comes only AFTER. add-before-set, never set-first (cmd_set hard-fails on a never-added label).
  $S/launch-manifest.py add --path "$FLEET_MANIFEST" --label "$QC_LAST_LABEL" --kind "$QC_LAST_KIND" --spec "$QC_LAST_TARGET" 2>/dev/null \
    || true   # idempotent: a duplicate-label add (resumed run) is a no-op; the row already exists for the later `set`

  # ===== THE REAL DISPATCH — session-level, BETWEEN qc_next and qc_settle (SHR3-T4, the realified seam). =====
  # The SESSION fires ONE top-level Workflow (/orchestrated|/nimble|/chain|/loop-task) for the resolved
  # in-queue $QC_LAST_TARGET with baseSha=$PRIOR_TIP (re-root via waveStep0), and BLOCKS until the Workflow
  # emits its completion <task-notification>. THAT BLOCK IS THE AWAIT — a session-level mechanic the lib does
  # NOT own (the bash lib no longer pretends to dispatch — the queue-v1.1 green-gates-on-a-non-functional-
  # daemon failure class is closed here). $QC_LAST_TARGET is passed as a DISTINCT argv element
  # (--target "$QC_LAST_TARGET"), never composed into a shell string, so a malicious target cannot break out
  # into shell-command position (SA-002). Serial: exactly ONE Workflow in flight; a pending/ append landing
  # mid-build is picked up next iteration (files-as-mailbox).
  #
  # The launch is fired by the LLM (this session) as a top-level /<kind> Workflow call — NOT a bash function.
  # The four kinds map: orchestrated→/orchestrated, nimble→/nimble (passing workTree="$QC_WORKTREE" so the
  # launched nimble's integrate is ISOLATED to the daemon's worktree — SHR3-T3/AC-008, no launching-HEAD flip),
  # chain→/chain, loop→/loop-task. The session AWAITS the <task-notification>, then OBSERVES the outcome in
  # the daemon's WORKTREE (SHR3-T3): launch_rc, the worktree's new tip, and its dirty state.
  #
  # DELEGATE, NEVER RE-DERIVE (AC-001). The session does NOT hand-construct the engine arg object here — it
  # DELEGATES to the canonical recipe for $QC_LAST_KIND, which is the SINGLE SOURCE OF TRUTH for how engine
  # args are built (ADR-039/040/062/063 — re-deriving them here would drift against the recipes):
  #   * orchestrated → `core/skills/orchestrated/SKILL.md` §0-2 (Pre-flight base ref → run-folder + prompt.md →
  #                     Launch the Workflow engine). The recipe creates $D/prompt.md and builds the {runDir,
  #                     repoRoot, task, waveBaseRef, baseSha, tickets, …} arg object; the daemon supplies the
  #                     in-queue target as the wave spec and $PRIOR_TIP as baseSha — it does NOT re-author the
  #                     arg object's shape.
  #   * nimble       → `core/skills/nimble/SKILL.md` (run-folder + prompt.md → explore → implement (worktree)
  #                     → integrate). Pass workTree="$QC_WORKTREE" so the launched nimble's integrate is
  #                     isolated to the daemon's worktree.
  #   * chain        → `core/skills/chain/SKILL.md`;  loop → `core/skills/loop-task/SKILL.md`.
  # The daemon routes (kind, $QC_LAST_TARGET, $PRIOR_TIP) THROUGH the named recipe's run-folder + prompt.md +
  # arg-object inputs — it names the recipe it delegates to and never inlines arg construction.
  #
  #   --- launch (LLM-driven, blocks on the <task-notification>) — DELEGATES to the named recipe above ---
  #   # orchestrated: follow core/skills/orchestrated/SKILL.md §0-2 with the in-queue spec=$QC_LAST_TARGET, baseSha=$PRIOR_TIP, workTree=$QC_WORKTREE
  #   # nimble:       follow core/skills/nimble/SKILL.md       with target=$QC_LAST_TARGET, baseSha=$PRIOR_TIP, workTree=$QC_WORKTREE
  #   /<kind> --target "$QC_LAST_TARGET" --base-sha "$PRIOR_TIP" --work-tree "$QC_WORKTREE"
  #   launch_rc=<the awaited Workflow's exit status>
  #
  # PERSIST (ADR-039 contract 2). The launched recipe's FINAL step persists its returned payload to the run
  # folder via `$S/persist-run-artifacts.py --run-dir "$D" --slug "$SLUG" …` (orchestrated/SKILL.md §3,
  # nimble/SKILL.md). The daemon DELEGATES that persist to the recipe — it does NOT re-author the persist call.
  #
  # CAPTURE the run folder into the daemon loop's OWN scope (CR-001): the delegated recipe persisted its
  # payload to a run folder (the recipe's internal $D), but $D is recipe-internal and is NOT a live variable
  # back here in the daemon loop. The SESSION reads the persisted run-folder path from the dispatch return and
  # binds it to QC_RUN_DIR HERE — that daemon-scoped var (NOT a recipe-internal $D) is what the gate-presence
  # settle check (A2, below) reads findings/ from. Fail-safe: if the session could not capture it, QC_RUN_DIR
  # is empty → the settle check refuses `done` (never settles green on an unverifiable run).
  QC_RUN_DIR="<the run folder the delegated recipe persisted — read from the dispatch return>"
  QC_BUILDS_DONE=$((QC_BUILDS_DONE + 1))     # WIDTH GUARD (ADR-132 D-4): count this BUILD dispatch — the loop-top
                                             # width-guard consults QC_BUILDS_DONE ≥ QUEUE_MAX_BUILDS to WRAP.
  QC_NEW_TIP="$(git -C "$QC_WORKTREE" rev-parse HEAD 2>/dev/null || echo '')"   # observed in the WORKTREE (SHR3-T3)
  DIRTY="$(qc_worktree_dirty)"               # clean tree = the success precondition. Routes through the lib's
                                             # qc_worktree_dirty seam so the done-vs-failed read carries the
                                             # load-bearing transient-path exclude `-- . ':(exclude).claude/'`
                                             # (AC-008 / ADR-130 D-3): a clean build whose worktree carries
                                             # `.claude/` pollution settles done/, not failed/. qc_worktree_dir
                                             # resolves $QC_WORKTREE (lib :90) so this reads the same worktree.

  # ===== qc_settle — the DETERMINISTIC AFTER-DISPATCH half (SHR3-T4). Takes launch_rc + DIRTY as ARGS. =====
  # BRANCH ON OUTCOME (CR-001/002): success (launch_rc 0 + clean tree) → running/→done/ + QC_LAST_OUTCOME=done;
  # failure → running/→failed/ + park-vs-halt arbiter. The session hands qc_settle the EXACT entry/label
  # qc_next picked (deterministic reconciliation — never an `ls -dt` mtime guess, CR-002).
  qc_settle "$QC_LAST_ENTRY" "$QC_LAST_LABEL" "$launch_rc" "$DIRTY"
  rc=$?

  case "$rc" in
    1) break ;;                                # arbiter HALT (condition b: dirty/broken base) → stop the stack
    0)
      # qc_settle drained the entry (success → done/ + QC_LAST_OUTCOME=done, or parked failure → failed/ +
      # QC_LAST_OUTCOME=failed). Render + reconcile runtime status here (SESSION-level — not the lib's job).
      # Use the EXACT entry qc_next/qc_settle just handled (QC_LAST_ENTRY/QC_LAST_LABEL) — deterministic, not
      # an `ls -dt` mtime inference that could mis-pick under clock skew or a concurrent touch (CR-002).
      ENTRY="$QC_LAST_ENTRY"
      LABEL="$QC_LAST_LABEL"

      # --- GATE-PRESENCE ASSERTION at settle (AC-003 — the load-bearing structural backstop against
      #     green-on-gateless). A settled `done` entry whose DISPATCHED RUN folder has NO non-empty batch-gate
      #     findings file is SURFACED and NOT settled green. qc_settle branches on launch_rc + DIRTY only and
      #     NEVER inspects gate findings — so without this check a hand-driven gate-less build (the round-4
      #     dogfood failure) would settle `done` with nothing to stop it. The concrete signal is the
      #     `rules-artifact-sync.md` run-folder layout: a NON-EMPTY findings/code-reviewer*.md ∥
      #     findings/spec-conformance*.md UNDER THE DISPATCHED RUN's folder ($QC_RUN_DIR), NOT under
      #     docs/step-4-queue/running/<entry>/ (the queue entry folder). $QC_RUN_DIR is the run folder the
      #     delegated recipe persisted via persist-run-artifacts.py (A1); resolve it from the dispatch return
      #     (the recipe's $D). "Non-empty" matters — a zero-byte findings file is NOT gate evidence.
      #     Absent → surface the entry + REFUSE the `done` settle (do not record `done`; do not advance
      #     PRIOR_TIP). Refuse-don't-crash: a PER-ENTRY surface, NOT a hard stack halt (ADR-105 park-vs-halt).
      if [ "$QC_LAST_OUTCOME" = "done" ]; then
        # $QC_RUN_DIR was captured at the dispatch site above, in the daemon loop's OWN scope (CR-001) — the
        # recipe-internal $D is NOT live here. Read the daemon-scoped var directly; empty → fail-safe REFUSE.
        QC_RUN_DIR="${QC_RUN_DIR:-}"
        QC_GATE_FINDINGS=""
        if [ -n "$QC_RUN_DIR" ] && [ -d "$QC_RUN_DIR/findings" ]; then
          # a NON-EMPTY (`-s`) batch-gate findings file is the gate-presence signal (code-reviewer ∥ spec-conformance)
          QC_GATE_FINDINGS="$(find "$QC_RUN_DIR/findings" -maxdepth 1 -type f \( -name 'code-reviewer*.md' -o -name 'spec-conformance*.md' \) -size +0c 2>/dev/null | head -1)"
        fi
        if [ -z "$QC_GATE_FINDINGS" ]; then
          # GATE-PRESENCE FAILED — no non-empty batch-gate findings file on the dispatched run folder.
          # SURFACE the entry and REFUSE the `done` settle: do NOT record `done`, do NOT advance the base.
          echo "queue-chew: GATE-PRESENCE REFUSE '$LABEL' — settled done but its dispatched run folder ($QC_RUN_DIR) has NO non-empty batch-gate findings file (findings/code-reviewer*.md or findings/spec-conformance*.md). The engine's batch-gate did not run (or produced no findings) — refusing to settle green on a gate-less build (AC-003, ADR-129 D-2). Per-entry surface, NOT a stack halt (ADR-105). The entry stays surfaced; base NOT advanced." >&2
          QC_SKIP="$QC_SKIP $QC_LAST_ENTRY"   # exclude from re-pick; the daemon advances + WRAPs rather than re-picking
          $S/launch-manifest.py set --path "$FLEET_MANIFEST" --label "$LABEL" --status blocked 2>/dev/null || true   # surface as blocked, NOT done
          python3 "$S/docs-index.py" >/dev/null 2>&1 || true   # regen BUILD-STATUS to reflect the refusal (never hand-edit)
          continue   # refuse-don't-crash: pop the next item; PRIOR_TIP deliberately NOT advanced for this entry
        fi
      fi

      ITEM_BRANCH=$(git -C "$QC_WORKTREE" rev-parse --abbrev-ref HEAD)   # the stacked branch this item built on (in the daemon's WORKTREE — SHR3-T3 — never the operator's tree)
      # --- AC-021 RENDER-TRIGGER (wire-to-consumer): on the running/ → {done,failed}/ state change the daemon
      #     UPDATES launch-manifest features[] (status + BRANCH + sha) THEN REGENERATES docs/BUILD-STATUS.md by
      #     re-running docs-index.py. It NEVER hand-edits the rendered file (F-002 / ADR-109 W3). ---
      $S/launch-manifest.py set --path "$FLEET_MANIFEST" --label "$LABEL" --status "$QC_LAST_OUTCOME" --branch "$ITEM_BRANCH" --sha "$QC_NEW_TIP"
      python3 "$S/docs-index.py"               # ← REGENERATE BUILD-STATUS (built-but-unmerged stack) — never an in-place edit
      if [ "$QC_LAST_OUTCOME" = "done" ]; then
        PRIOR_TIP="$QC_NEW_TIP"                # advance the linear stack base — SUCCESS-ONLY (the lib never advanced it)
      fi
      # NOTE on failure: PRIOR_TIP is deliberately NOT advanced — never stack the next item on a failed tip.
      # The lib already moved a failed item to failed/ (NOT done/) and ran the park-vs-halt arbiter.
      continue ;;                              # pop the next — back to the fresh pending/ read (NEVER cached)
  esac
done

# ===== END-OF-DRAIN ARCHIVAL (ADR-128 D-1) — done/ → step-6-done/queue/, post-settlement. =====
# The loop has exited (rc 2: no dep-ready BUILD-KIND remains — the queue drained). NOW release every SETTLED
# done/ entry to the canonical archive so done/ stays near-empty in steady state. qc_archive_settled is
# deterministic + idempotent (the F9 settled predicate: a done/ entry archives iff NO live pending after:
# names it) and uses a bare MAIN-tree git mv (mirroring qc_drain_to — the queue folders live in the main
# tree, NOT through qc_git; isolation is satisfied by not touching the build worktree, so an archival move
# can never flip the operator's HEAD). It writes NO manifest update
# (status stays `done`; the manifest is label-keyed) so it adds NO crash-consistency window (ADR-123 D-3 #2).
# A late `pending after:<archived>` still resolves because qc_pick_entry reads the qc_completed_labels()
# union (done/ ∪ step-6-done/queue/), not bare done/ (ADR-128 D-3). failed/ is NEVER archived (D-5).
ARCHIVED_N="$(qc_archive_settled)"   # prints the count; per-entry "ARCHIVED <label>" lines go to stderr (the review surface)
[ "${ARCHIVED_N:-0}" -gt 0 ] && python3 "$S/docs-index.py" >/dev/null 2>&1   # regen BUILD-STATUS if anything moved (never hand-edit)

# ===== STAGE-BLOCKED-BUILD SURFACE (CR-001 — the silent-strand close). =====
# A build queued `after <roadmap-label>` in the SAME drain that STAGE-routed that label will NEVER resolve:
# the STAGE label drained to staged/ (a non-done/ terminal) and is intentionally NOT in qc_completed_labels()
# (done/ ∪ step-6-done/queue/, NEVER staged/) — that IS the no-auto-chain / morning-review gate. Without a
# surface the build strands in pending/ forever and NOTHING tells the operator (green-on-a-non-functional-path).
# This converts that silent strand into an EXPECTED, informational NOTE — NOT a failure (the two-pass flow is
# intended). It changes NO routing: it only READS pending/ and reports. Shell-portable (bash AND zsh — sourced
# into the operator's zsh): `while IFS= read` + `case` membership, NEVER a bare `for x in $(...)`.
QC_STAGED_LABELS="${QC_STAGED_LABELS:-}"
if [ -n "${QC_STAGED_LABELS// /}" ]; then            # only when ≥1 label was STAGE-routed THIS drain
  QC_STRANDED=""; QC_STRANDED_N=0
  QC_PENDING_DIR="$(qc_queue_dir)/pending"
  if [ -d "$QC_PENDING_DIR" ]; then
    # Enumerate pending entries portably (NUL-delimited find | while read — no bare word-split-on-$()).
    while IFS= read -r -d '' QC_PD; do
      QC_PENT="$(basename "$QC_PD")"
      [ "$QC_PENT" = ".gitkeep" ] && continue
      # Read this entry's `after` dep(s) — scalar OR list — one label per line (untrusted sidecar; tolerant).
      while IFS= read -r QC_DEP; do
        [ -z "$QC_DEP" ] && continue
        case " $QC_STAGED_LABELS " in
          *" $QC_DEP "*)                              # this pending build depends on a label STAGE-routed this drain
            case " $QC_STRANDED " in
              *" $QC_PENT "*) : ;;                    # already recorded (a build may name >1 STAGE dep)
              *) QC_STRANDED="$QC_STRANDED $QC_PENT"; QC_STRANDED_N=$((QC_STRANDED_N + 1)) ;;
            esac ;;
        esac
      done <<EOF
$(python3 - "$QC_PD/sidecar.json" <<'PYEOF'
import json, sys
try:
    side = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
after = side.get("after")
if after is None:
    after = []
elif isinstance(after, str):
    after = [after]
for dep in after:
    if isinstance(dep, str):
        print(dep)
PYEOF
)
EOF
    done < <(find "$QC_PENDING_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
  if [ "$QC_STRANDED_N" -gt 0 ]; then
    echo "queue-chew: NOTE — ${QC_STRANDED_N} build(s) are queued 'after' a STAGE spec produced THIS drain (${QC_STAGED_LABELS# }); by design they do NOT auto-build (the morning review gate). They remain in pending/ — queue/confirm them after reviewing the spec. This is expected, not an error:${QC_STRANDED}" >&2
  fi
fi
```

The grep-visible tokens the gate looks for are all present above: `launch`, `workflow`, `await`,
`task.?notification`, `serial`, `one ... flight`, `files-as-mailbox`, `single-locus`. The deterministic
mechanics (`qc_next` before the dispatch + `qc_settle` after it — the SHR3-T4 split of the retired
`qc_run_one`, the SA-001/002/003 guards, the within-queue drain, the outcome branch, the arbiter) are
sourced from `core/scripts/queue-chew-lib.sh` (ADR-124) and proven by `core/scripts/test-queue-chew-e2e.sh`
(green = a chew built a file end-to-end via the real `qc_next` → dispatch → `qc_settle` round-trip). The
**REAL dispatch is the SESSION's, fired BETWEEN `qc_next` and `qc_settle`** — the bash lib no longer
pretends to dispatch (SHR3-T4); `launch_workflow` survives only as the e2e test stub.

> **`launch_workflow` is DEMOTED test-only — NEVER called from any production drain path (AC-004, binding).**
> The lib already demotes it (`queue-chew-lib.sh:463-465`): there is **no** `launch_workflow` invocation in
> `qc_next`, `qc_settle`, `qc_pick_entry`, `qc_drain_to`, the arbiter, or any other production drain function
> — its **only surviving call site is the e2e test stub** in `core/scripts/test-queue-chew-e2e.sh`. The
> production prose above therefore carries **no executable `launch_workflow` call**: the real fire is the
> SESSION's top-level `/<kind>` Workflow delegation (the named recipe), never a lib inline dispatch
> (re-introducing one reopens the AC-010 autonomy boundary — ADR-129 D-3). The e2e test asserts this
> (`git grep -n 'launch_workflow' core/scripts/queue-chew-lib.sh core/skills/queue-chew/SKILL.md` shows no
> production drain function invokes it — A3).

## Done-archival — `done/` → `step-6-done/queue/`, post-settlement (ADR-128)

Completed queue entries do not rest in `docs/step-4-queue/done/` forever — that was the "parallel `done`
silos" residual ADR-127 D-2 deferred. **`done/` is now TRANSIENT**: once an entry is *settled* (no live
`pending/*/sidecar.json` still names it in `after:`), it is physically archived to the canonical
`docs/step-6-done/queue/` sub-namespace (sibling of `handoffs/`/`sessions/` — queue archives never conflate
with run folders). This is ADR-127 D-2's promised one-way map `done/<entry>` → `step-6-done/queue/<entry>`,
taken **only post-settlement** so the four ADR-123 D-3 invariants hold (lifecycle unchanged; single `git mv`,
no new crash window; base-advance untouched; `done/`-only — `failed/` stays queue-local, D-5).

**Two deterministic triggers (both call `qc_archive_settled` from `queue-chew-lib.sh`):**

1. **Opportunistic — end-of-drain.** The chew loop calls `qc_archive_settled` when the queue drains (no
   dep-ready BUILD-KIND remains — § the end-of-drain block above), so `done/` stays near-empty in steady state.
2. **On-demand — a standalone `queue-archive` maintenance sweep.** An operator (or a cron/`--watch` adjunct)
   can release settled entries without a full chew. It sources the lib + runs the SAME function — including a
   **one-time migration** of any already-accumulated settled `done/` entries (idempotent; `.gitkeep` ignored):

```bash
# Standalone done-archival sweep (no dispatch — pure folder release). Idempotent + safe to re-run.
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
. "$S/queue-chew-lib.sh"                  # sources qc_archive_settled + qc_completed_labels (the chokepoint)
# Settled-set preview (zero-LLM, deterministic): what WOULD archive, and why.
python3 "$S/queue-archive.py" settled --queue-dir docs/step-4-queue
# Release every settled done/ entry → step-6-done/queue/ (single git mv each; NO git rm; NO manifest write).
# This same call performs the ONE-TIME MIGRATION of pre-existing settled done/ entries on first run (the
# settled predicate doesn't care whether an entry was just-built or accumulated — folder-as-truth).
ARCHIVED_N="$(qc_archive_settled)"        # per-entry "ARCHIVED <label>" lines on stderr; count on stdout
[ "${ARCHIVED_N:-0}" -gt 0 ] && python3 "$S/docs-index.py"   # regen BUILD-STATUS only if something moved
echo "queue-archive: ${ARCHIVED_N:-0} settled entr(y/ies) released to docs/step-6-done/queue/."
```

`qc_archive_settled` runs a **bare main-tree `git mv`** (mirroring `qc_drain_to` — the queue lifecycle
folders live in the operator's main tree, **not** through `qc_git`/the build worktree; an archival pass can
never flip the operator's HEAD because it never touches the build worktree) and writes **no manifest update**
(status stays `done`, the manifest is label-keyed). A crash mid-archival leaves a half-moved set the next
idempotent pass completes. Proven by `core/scripts/test-queue-archive.sh`.

---

## The park-vs-halt arbiter (AC-015 — ADR-105 extended to the queue)

The **arbiter** is the daemon's failure-policy decision layer. The caller **branches on the build OUTCOME
BEFORE any move** (CR-001/002): a SUCCESS (`launch_rc == 0` AND clean tree) goes straight to `done/` +
`status=done` + base-advance and never reaches the arbiter; a FAILURE (`launch_rc != 0` OR dirty tree) is
moved to `failed/` + `status=failed` with the base **not** advanced, and **only then** is the arbiter
invoked to decide park-vs-halt-vs-skip-dependent. The governing principle is **ADR-105** extended to the
queue: just as the engine's default is "auto-dispose + log + continue, halt only on an execution-class
block," the daemon's default is **park-and-continue**, and it **halts only on a dirty/broken base**.

**Park-and-continue is the DEFAULT.** An item that fails where **no downstream entry declares a dependency
on it AND the shared base is left clean** is **parked**: the daemon logs the failure to the run's decision
log (`autonomous-decisions-log.md` — `{what failed, why-best-known, parked, remediate-if-wrong}`) and
**continues to the next independent item**. An isolated failure is NOT a session halt — it is a parked
disposition, exactly as ADR-105's judgment-class default auto-disposes rather than stopping. This is the
common case; write the policy so park reads as the default and halt as the exception.

**Halt is CONDITIONAL — it fires ONLY under condition (a) OR condition (b), the two and only halt triggers:**

- **(a) A downstream entry declares the dependency on the failed/dirty item.** When the failed item has
  **declared dependents** (read via the dependency-edge helper below), those dependents **cannot stack on a
  base that never got this item's commits**, so the daemon **skips its declared dependents** (marks them
  `blocked`, leaves them in `pending/`, does NOT stack them on the broken/missing base). **Independent items
  still continue** — only the declared dependents are skipped. This is a `skip-dependent` disposition, not a
  full session stop: the daemon skips the affected sub-graph and drains the rest.
- **(b) The shared base is left dirty/broken** (the post-item base-integrity check below trips). The next
  item would stack on a broken base, so the daemon **halts the stack** — this is the queue's
  execution-class block (the one hard stop), the queue analogue of ADR-105's "halt only on an
  execution-class block."

**Decision-log, not session-halt, for a park** — a park is one decision-log line + continue; only condition
(b) (and, for its declared sub-graph, condition (a)) escalates. The arbiter never crosses the shared-state
floor: a parked or skipped item leaves its (partial) build on a stacked feature branch, reviewable and
revertible — nothing reaches main (§ The shared-state floor).

```bash
# arbiter_decide LABEL LAUNCH_RC DIRTY  → exit 0 = park-and-continue (drain the rest); exit 1 = halt the stack.
#   CALLED ONLY ON FAILURE (the caller's SUCCESS branch never reaches here). The failed item has ALREADY
#   been moved to failed/ and recorded status=failed, and PRIOR_TIP was NOT advanced. The arbiter's job is
#   the remaining failure policy: skip the failed item's DECLARED dependents (condition a), then split on
#   base integrity — HALT on a dirty/broken base (condition b), PARK on a clean isolated failure (default).
#   Frames PARK as the default; HALT only under condition (b) dirty/broken base.
arbiter_decide() {
  local label="$1" launch_rc="$2" dirty="$3"
  S=.claude/scripts; [ -d "$S" ] || S=core/scripts

  # AC-016 POST-ITEM BASE-INTEGRITY CHECK — already computed by the caller and passed in as $dirty (the
  # `git status --porcelain` result; empty = clean tree). "Broken base" = a DIRTY/non-empty working tree.
  # NOTE the semantics split (CR-001): a non-zero build outcome with a CLEAN tree is an ISOLATED, PARKABLE
  # failure (skip its declared dependents, continue) — NOT a whole-queue base break. Only a DIRTY/broken
  # tree is the base-break that halts the stack. (Mirror, don't reuse, the implementer-protocol base check.)

  # condition (a) ALWAYS: skip the failed item's DECLARED dependents (both edge kinds — after X + derived
  # planned_files overlap) so they do not stack on the absent/failed base. Independent items still continue.
  local deps; deps=$($S/queue-order.py dependents --pending docs/step-4-queue/pending --label "$label")
  local all_deps; all_deps=$(printf '%s' "$deps" | python3 -c "import json,sys;print(' '.join(json.load(sys.stdin)['all_deps']))")
  local d
  for d in $all_deps; do
    # SA-003 (defense-in-depth) — each dependent label $d read from `queue-order.py dependents` is shape-checked
    #   BEFORE it reaches `--label "$d"`, mirroring the primary $LABEL guard. It is already quoted (no shell
    #   injection), so this is hardening, not a vuln fix: a malformed dependent label is skipped + logged rather
    #   than passed to launch-manifest.py. Same label shape as SA-003 (^[a-z0-9][a-z0-9-]*$).
    if ! printf '%s' "$d" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
      echo "queue-chew: SKIPPED malformed dependent label '$d' of '$label' — failed ^[a-z0-9][a-z0-9-]*\$ shape check (defense-in-depth SA-003)." >&2
      continue
    fi
    # condition (a): skip-dependent — a declared/derived dependent cannot stack on the broken/missing base.
    echo "queue-chew: SKIP-DEPENDENT '$d' — its predecessor '$label' failed (ADR-105 condition a, arbiter)." >&2
    $S/launch-manifest.py set --path "$FLEET_MANIFEST" --label "$d" --status blocked 2>/dev/null || true
  done

  if [ -n "$dirty" ]; then
    # condition (b): the shared base is left DIRTY/BROKEN → HALT the whole queue (execution-class block).
    #   A corrupt working tree cannot be safely stacked on; stop rather than stack-on-broken-base.
    echo "queue-chew: HALT — base-integrity check tripped after '$label' (broken base, dirty tree). Stopping the stack rather than stack-on-broken-base (ADR-105 condition b)." >&2
    return 1
  fi

  if [ -n "$all_deps" ]; then
    # ISOLATED non-zero failure, base CLEAN, but it HAS declared dependents (condition a) → those are
    # skipped above; the daemon continues draining the INDEPENDENT remainder (not a full halt).
    echo "queue-chew: '$label' failed (clean tree); declared dependents skipped, independent items continue (ADR-105 condition a, arbiter)." >&2
    return 0
  fi

  # PARK-AND-CONTINUE (the DEFAULT): isolated non-zero failure, base CLEAN, NO declared dependents → log +
  # continue. The failed item already sits in failed/ (the ls-legible terminal failure state); it never
  # advanced the linear-stack base.
  echo "queue-chew: PARK '$label' — failed (clean tree) but no downstream declares a dep; logging to autonomous-decisions-log.md and continuing to the next independent item (ADR-105 default — park-and-continue, arbiter)." >&2
  return 0
}
```

The AC-015 tokens are all present above: `park-and-continue` / `park`, `halt`, `skip-dependent`, `ADR-105`,
`arbiter`, with the two dispositions kept distinct — condition (a) declared-dependent **skip** (the failed
sub-graph is skipped, the rest drains) and condition (b) dirty/broken base **halt** (the one whole-queue
stop). Only condition (b) halts the stack; condition (a) is a skip, not a halt.

## Post-item base-integrity check (AC-016)

The **post-item base-integrity check** is the queue's stack-protection invariant: **after each item
completes, before the next item stacks on it**, the daemon checks the shared working tree. There are
**TWO distinct conditions, and they dispose differently** — keep them explicit, with park as the default:

- **(b) A DIRTY/BROKEN tree = base broken = HALT.** A non-empty `git status --porcelain` (a `dirty` tree)
  means the working tree is corrupt and **cannot be safely stacked on**. This is the queue's
  **execution-class block** — the one hard stop. The arbiter **halts** the whole queue (condition b) rather
  than stack the next item on a **broken base**. There is **no silent stack-on-broken-base**.
- **(a) A non-zero build outcome with a CLEAN tree = an ISOLATED, PARKABLE failure — NOT a whole-queue
  base-break.** A `LAUNCH_RC != 0` whose tree is **clean** did not corrupt the shared base; it is an
  isolated item failure. The daemon **skips the failed item's declared dependents** (condition a — they
  cannot stack on the absent base) and then **`park-and-continue`s** to the next INDEPENDENT item. It does
  **NOT** halt the queue — an isolated non-zero outcome on a clean tree is the common, parkable case, not a
  base break.

**`park-and-continue` is the default; `halt` is the dirty/broken-base exception (condition b).** Either way
the failed item has already been moved to `failed/` (NOT `done/`) and the linear-stack base was **not**
advanced past it — a failed item never becomes the next item's base.

## Dependency-edge reading — both edge kinds (AC-017)

The arbiter must decide **halt-vs-skip-vs-park** by reading **dependency edges**, and there are **two edge
sources it MUST consume — both, not just `after X`**:

- The explicit **`after X` sidecar field** (the declared edge, Wave-1 producer).
- The **derived `planned_files`-overlap edges** (AC-004, `queue-order.py`): two entries whose `planned_files`
  overlap are **structurally dependent even when neither declared `after`**. Reading only `after X` would let
  a structurally-dependent-but-undeclared item stack on a broken base — the exact gap this wave closes.

The arbiter reads **both** by **calling the `queue-order.py dependents` helper** (it does **not** recompute
edges — it reuses the orderer's `_load_tape` + overlap logic):

```bash
# Read LABEL's dependents from BOTH edge kinds (declared `after X` + derived planned_files-overlap).
$S/queue-order.py dependents --pending docs/step-4-queue/pending --label "$LABEL"
# → {"label":LABEL, "after_deps":[...], "overlap_deps":[...], "all_deps":[...]}   (all_deps = the skip-set)
```

`all_deps` is the union the arbiter skips under condition (a). **The skip-dependents behavior is unit-tested**
in `core/scripts/test-queue-order.sh` (the AC-017 cases: a failed item's declared `after X` dependent is in
the skip-set while an independent item is not; a `planned_files`-overlap dependent is surfaced too) — that
test is the wire-to-consumer assertion evidence that the arbiter's skip logic is exercised, not just defined.

---

## Input validation — the sidecar is UNTRUSTED (binding — security gate SA-001/002/003)

The daemon runs **unattended**, so every untrusted sidecar field that flows into a filesystem sink (a
`git mv` path, the launch target, an operator-facing log line) **MUST be validated reject-and-skip
BEFORE the sink** — mirroring the existing `baseSha` SHA-guard precedent (`waveStep0`,
`/^[0-9a-f]{7,40}$/i`) the skill already cites. These are **BINDING** contracts, not advisory notes:

> **Portability — `_canon`, NOT the GNU-only realpath flag (ADR-124, binding).** Every containment check
> below uses the lib's `_canon` (`python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))'`) —
> `os.path.realpath` canonicalizes a **missing** path cross-platform (BSD macOS + GNU linux). The GNU-only
> realpath missing-path flag is **banned** from the queue surface — a `git grep` for it returns nothing in
> any queue file; `queue-chew-lib.sh` defines `_canon` and uses it at all four former canonicalization sites.

- **SA-001 — `$ENTRY` is a single in-folder DIRECTORY basename (path-traversal).** The daemon **MUST
  validate `$ENTRY` is a single in-folder directory basename before any `git mv`** (entry-as-folder, ADR-124).
  "Single in-folder directory basename" means it matches `^[a-z0-9][a-z0-9-]*$` (no `/`, no `..`, no leading
  `-` — and **no `.md`/`.json` suffix**, because the entry is now a **folder**, not a file) **AND** `_canon`
  of the source stays under `docs/step-4-queue/pending/`. A crafted/buggy entry name containing `../` would
  otherwise steer the `git mv` target outside `docs/step-4-queue/`; on a validation miss the daemon logs and
  **skips** (reject-and-skip, `continue`) — it does **not** move the entry. (Lib: `qc_validate_entry`.)
- **SA-002 — `$TARGET` resolves under `docs/step-4-queue/` (the allowlisted root — FLIPPED by ADR-124).** Before
  launch the daemon **MUST validate** (via `_canon`) that `$TARGET` resolves **UNDER** `docs/step-4-queue/` — the
  allowlisted root is **flipped from `docs/step-3-specs/` to `docs/step-4-queue/`** because the in-queue artifact
  IS the build input (ADR-124). `TARGET = docs/step-4-queue/running/<entry>/<sidecar.target>`; on a containment
  miss the daemon **reject-and-skips AND un-drains** the entry `running/ → pending/` (nothing was built). An
  unattended daemon must never be steered to build an arbitrary / attacker-chosen path outside `docs/step-4-queue/`.
  The launch verb **MUST pass `$TARGET` as a distinct argv element** (`--target "$TARGET"`) — **never
  composed into a shell string** — so a malicious target cannot break out into shell-command position.
  (Lib: `qc_resolve_target`.)
- **SA-003 — sidecar string fields are shape-checked before they reach logs (log-injection).** The
  sidecar string fields (`label`, `kind`) are **untrusted** and **MUST be shape-checked**
  (`^[a-z0-9-]+$`) before being `echo`ed into operator-facing logs — the unattended run's only review
  surface. The BUILD-KINDS allowlist gate (AC-010) remains **fail-closed** (a `kind` outside the
  allowlist is rejected); the SA-003 shape check is an additional pre-log guard that **preserves**, not
  weakens, that fail-closed allowlist. (Lib: `qc_validate_label_kind`.)

---

## SERIAL — exactly one Workflow in flight (AC-009)

The daemon is **strictly serial**: it launches one Workflow, **awaits it fully**, and **only then**
re-reads the folder and picks the next item. Parallelism stays **`/launch`'s** job — `/queue-chew` does
**not** borrow `/launch`'s fan-out; it is the single-locus serial drainer.

- **One in flight.** At any moment there is at most one launched Workflow. The await (the blocking
  top-level launch call) is what enforces this — there is no second dispatch until the first returns.
- **files-as-mailbox / single-locus.** A new producer append landing in `pending/` mid-drain is an
  **async file drop** that does **NOT** interrupt the in-flight item. The daemon sees it on the **next**
  iteration's fresh read and picks it up then. Because the daemon is the **single locus** that moves
  entries, no second writer ever races it.

The "launch one → await it fully → *then* re-read the folder" ordering is non-negotiable. Do not start a
second build before the first's `<task-notification>` lands.

---

## BUILD KINDS + the STAGE-kind (AC-010 build allowlist + AC-014/015 STAGE route)

The daemon recognizes **two DISJOINT verb taxonomies** (ADR-132 D-1; `launch-manifest.py` L30/L37):

- **BUILD-KINDS** (`KINDS = {orchestrated, nimble, chain, loop}`) — terminal is a **merged build** on the
  linear stack, archived to `step-6-done/queue/`. Drained by `qc_next`/`qc_settle` (the build path).
- **STAGE-KINDS** (`STAGE_KINDS = {roadmap}`) — terminal is a **SPEC routed to `step-3-specs/`**, never a
  merged build, never archived. Routed by the **STAGE pre-route** at the top of the loop body (§ the
  daemon loop above): the entry is recognized BEFORE the build-kinds allowlist, dispatched to its STAGE
  recipe (`/roadmap`), drained to the `staged/` STAGE terminal (NOT `done/`), and **`qc_archive_settled`
  is skipped** for it. It does **NOT auto-chain plan→build** — the daemon produces the spec and STOPS (the
  morning human-review gate IS the value, ADR-132 D-2).

**`sweep` is the ONE still-rejected planning verb (Phase-1 boundary).** `sweep` is in **neither** set, so
it falls through to `qc_next`'s `qc_validate_kind` allowlist and is **REJECTED at drain time** — its
convergence has an interactive door and needs an unattended-convergence mode that does not exist yet
(deferred, not lost):

> `queue-chew: REJECTED '<label>' (kind=sweep) — planning verb is deferred to the planning-queue
> follow-on; the daemon does NOT drain it.`

The rejected `sweep` entry is **left in `pending/`** (not this daemon's to move) and the daemon skips to
the next dep-ready item. (`roadmap` is **no longer rejected** here — it is the routed STAGE-kind above.)

---

## Build-readiness routing — BUILD-BY-DEFAULT, opt OUT to refuse (ADR-132 D-3 — posture FLIPPED from ADR-124)

Once the whole artifact moves INTO the queue (move-on-advance), the in-queue artifact IS the build input —
so the daemon can classify its **build-readiness** before launching. Only an **`orchestrated`** build carries
the distinction (nimble/chain/loop have no decompose stage and always proceed):

- **PLANNED spec** (the in-queue artifact has a `## Tickets` heading + ≥1 `### KEY:` ticket block — a
  roadmapped, sliced wave spec) → **proceed**: a straight `/orchestrated` build. The engine's own
  `detectPlanned()` then skips its preamble (slice-once — `/roadmap` already sliced it).
- **Raw PLAN** (a shaped thesis / un-decomposed intent with no ticket graph) → **BUILDS BY DEFAULT**
  (ADR-132 D-3, operator-blessed). **Choosing the routing verb at `/queue add` IS the consent** (ADR-105
  default-autonomy is the spine — autonomy is the engine-path default). A raw plan runs the full
  `cto → architect → pm-spec → decompose` funnel unattended and lands its build on a stacked branch.
  **Opt-OUT:** `QUEUE_REFUSE_RAW_PLAN=1` is the **escape hatch to REFUSE** — set it and a raw plan is
  un-drained (left queued for the operator to `/roadmap` first) instead of built. A queue exists to do
  unattended work; an implied-consent gate that refuses the queued verb defeats it (ADR-132 D-3).

**`QUEUE_ALLOW_RAW_PLAN=1` is RETIRED** (the opt-IN-to-build knob is gone; build is now the default). The
session translates the new opt-OUT posture into the classifier at the top of the build path — it exports
the lib's existing knob as `QUEUE_ALLOW_RAW_PLAN=1` by default, and only withholds it when the operator
set `QUEUE_REFUSE_RAW_PLAN=1`:

```bash
# Build-by-default posture (ADR-132 D-3): build a raw plan UNLESS the operator opted OUT with QUEUE_REFUSE_RAW_PLAN=1.
if [ "${QUEUE_REFUSE_RAW_PLAN:-0}" = "1" ]; then
  unset QUEUE_ALLOW_RAW_PLAN          # opt-OUT honored → the readiness classifier REFUSES a raw plan (un-drains it)
else
  export QUEUE_ALLOW_RAW_PLAN=1       # DEFAULT → the readiness classifier PROCEEDS to build a raw plan unattended
fi
```

The classifier is `core/scripts/queue-detect-readiness.py`, which **mirrors** `orchestrated.js`'s
`parsesToTickets()`/`detectPlanned()` — ONE detector shape, so the queue's pre-launch gate and the engine
agree on what "planned" means. Under the opt-OUT (`QUEUE_REFUSE_RAW_PLAN=1`) it is **fail-closed**: a
NOT_PLANNED / unreadable verdict refuses, so opting out never silently decompose-lives an unreviewed plan.
The per-item refusal (opt-OUT only) is logged (`queue-chew: REFUSED '<label>' — orchestrated target is a
RAW PLAN …`) and counted into the WRAP (`REFUSED_RAW`).

> **Operator decision (blessed).** Build-by-default is the operator's blessed posture (ADR-132 D-3): the
> queue's headline overnight job is planning + building unattended, so the routing verb at `/queue add` is
> the consent (the producer-side **attended confirm** in `queue/SKILL.md`, D3, is the consent point). It
> lands on a branch either way (ADR-105 shared-state floor — nothing merges unattended); the
> `QUEUE_REFUSE_RAW_PLAN=1` opt-OUT is there for an operator who wants the old refuse-by-default behavior.

---

## Daemon width/time guard — overnight-window resource cap (ADR-132 D-4 / AC-016)

Build-by-default is made safe by **two** mechanisms (ADR-132 D-4): the **producer-side attended confirm**
(`queue/SKILL.md`, D3 — consent at queue-time) and the **daemon-side width/time guard** (here — resource
protection at drain-time). The guard caps **how much** the unattended drain builds in one overnight
window; it is **NOT a consent question** (the routing verb is the consent), it is a **real, named,
consulted** resource cap. It is wired into the daemon loop (§ the daemon loop, loop top) — defined,
consulted on every iteration, and enforced (it WRAPs the drain), not a defined-but-unread stub:

- **Width cap — `QUEUE_MAX_BUILDS` (default 8).** The maximum number of BUILD dispatches per overnight
  drain. The loop increments `QC_BUILDS_DONE` after each build dispatch and the loop-top guard WRAPs once
  `QC_BUILDS_DONE ≥ QUEUE_MAX_BUILDS`. The daemon is serial (one Workflow in flight), so "width" = the
  item-count cap on accumulated **unreviewed** build on the linear stack per window. **8** is a defensible
  "one overnight's worth": large enough for a real evening queue, small enough that a runaway/buggy
  producer cannot stack dozens of raw-plan builds before the morning review gate.
- **Time window — `QUEUE_WINDOW_HOURS` (default 8).** The wall-clock bound on the overnight window. The
  loop captures `QC_WINDOW_START` at drain start and the loop-top guard WRAPs once the window elapses. The
  bound gates the **next pick** — an in-flight build is **never interrupted** (no kill), it just stops
  dispatching new items. **8h** ≈ a real overnight window.

On either cap the daemon **WRAPs** — it stacks-and-stops cleanly, leaving the remaining items queued for
the next drain. It **NEVER merges or pushes** to main on a cap (the shared-state floor, § below, is
untouched — the guard bounds build volume, not the merge lever). Both thresholds are operator-tunable via
the env-vars; the defaults are the implementer call surfaced for the operator (ADR-132 D-4 — AC-016
contracts the mechanism, the numbers are tunable).

---

## Linear stack — reuse `waveStep0`, do NOT re-implement re-root (AC-011)

Each item launches with its build base ref set to the **prior completed item's branch tip** (`baseSha`):

- The **first** item roots off `main`.
- Thereafter the stack accumulates linearly: `main → A → B → C`. Item B's `baseSha` is A's completed tip;
  item C's is B's.

The re-root itself is **already shipped** as **`waveStep0`** in `core/scripts/workflows/orchestrated.js`
(**L1124-1133**) — `git fetch . && git reset --hard ${baseSha}`, SHA-guarded by `/^[0-9a-f]{7,40}$/i`.
(L69-84 is only the JSDoc param reference, not the executable — cite `waveStep0` at L1124-1133.)

The daemon's **only** job here is to **compute and pass the prior tip as `baseSha`** to the launched
Workflow. It **MUST NOT re-implement re-root logic** — the shipped `waveStep0` performs the reset when the
launched build starts. No `git reset --hard` lives in this skill's own loop body for the purpose of
re-rooting; that belongs to `waveStep0`.

---

## Within-queue drain — `git mv` + glob-never-re-picks, entry-as-folder (AC-012; ADR-124 EXTENDS ADR-123 D-3)

The lifecycle is **within-queue**: `pending/<entry>/ → running/<entry>/ → {done/<entry>/ | failed/<entry>/}`
(a completed item terminates in `done/` on success or `failed/` on a non-zero/dirty outcome), with the
**whole entry folder** (artifact + sidecar) staying **inside `docs/step-4-queue/`** the entire time. This is **NOT**
the shipped move-OUT-to-run-folder drain.

> **ADR-124 EXTENDS ADR-123 D-3 — the within-queue-drain invariant is PRESERVED.** ADR-124 adds the producer
> **move-IN** (the source artifact → `pending/<entry>/`) and makes the **in-queue artifact the build input**.
> That move-IN is **upstream of the drain**; the within-queue drain poll
> (`pending → running → {done|failed}` staying INSIDE `docs/step-4-queue/`) is **unchanged** — entries **never move
> OUT** of `docs/step-4-queue/` during the drain. The build READS the in-queue artifact at
> `running/<entry>/<sidecar.target>`; nothing leaves the queue at pickup. This preserves the ADR-123 D-3
> within-queue-drain invariant that the cross-session poll depends on.

> **Load-bearing divergence (F-003).** The legacy `docs/step-4-queue/README.md` drain-on-pickup and the
> `orchestrated` SKILL step 1.5 (`git mv "$SPEC_DIR"/* "$D"/`) move a queue entry **OUT** of `docs/step-4-queue/`
> into the build's run folder — the entry **leaves** the queue at pickup. The daemon does **NOT** ship that
> move-out (and ADR-124 reinforces this: the in-queue artifact IS the build input, so there is no reason to
> move it out). A move-out would **empty the queue at pickup** and break the live cross-session poll (the
> daemon's poll depends on the entry staying inside `docs/step-4-queue/` so lifecycle state — `running/` vs `done/`
> — is visible to other sessions). What the daemon reuses is the **`git mv` verb** and the
> **glob-never-re-picks property**, scoped to `pending/`.

- **glob-never-re-picks idempotency.** Moving an entry folder out of `pending/`'s glob range means a second
  read of `pending/*/sidecar.json` matches nothing for that entry — the daemon never re-picks an in-flight
  or completed item. This is the same glob-never-re-picks property `/launch --all` relies on (ADR-064
  §Consequences re-pick catch), **inherited**, not a new mechanism.
- **NO new drain executable.** The drain is the existing `git mv` primitive applied to the subfolder
  transitions, wrapped in the sourceable lib's `qc_drain_to` (ADR-124) — **not** a standalone move/drain
  script. The lib is sourced into the FS-having session; it is not a no-FS Workflow script.

---

## Runtime status — reconcile via `launch-manifest.py set`

On completion the daemon updates the in-flight item's **runtime status** in the fleet manifest
(`launch-manifest.py features[].status` — the runtime-truth authority, README R1) via the shipped
`set` verb:

```bash
$S/launch-manifest.py set --path "$FLEET_MANIFEST" --label "$LABEL" --status done --branch "$ITEM_BRANCH" --sha "$NEW_TIP"
```

The `--branch` field carries the item's stacked branch into `features[]` so the regenerated
`docs/BUILD-STATUS.md` built-but-unmerged section shows the linear stack (§ Anti-limbo visibility). After
this `set`, the daemon runs `python3 core/scripts/docs-index.py` to REGENERATE BUILD-STATUS (never an
in-place edit — F-002 / ADR-109 W3). `--status` is one of `{queued, running, done, blocked, failed}` (`launch-manifest.py STATUSES`). The
daemon writes `running` when it begins a build, then on completion writes `done` **iff** the build
succeeded (`launch_rc == 0` AND clean tree → entry moves to `done/`) or `failed` on a non-zero/dirty
outcome (→ entry moves to `failed/`); a skipped declared dependent is written `blocked` (it stays in
`pending/`). The status and the terminal folder agree: `done`↔`done/`, `failed`↔`failed/`. The **folder
location** (`pending/ | running/ | done/ | failed/`) and `launch-manifest.py features[].status`
are **disjoint authorities** — the folder is the queued/lifecycle truth, the manifest is the in-flight
runtime truth of the single active item (the full split is recorded in `docs/step-4-queue/README.md` §
"Source-of-truth split" and the reconciliation ADR — AWQ-T5). The daemon is the **sole writer of both**,
so there is no two-writer race; on a crash mid-transition, reconciliation **re-derives from the folder**
(see the reconciliation ADR's crash-consistency ordering).

---

## Anti-limbo visibility — the built-but-unmerged queue stack is NEVER invisible (AC-018 / AC-021)

Built-but-unmerged **queue** work must never sit invisible — that invisible-limbo failure was the real
lesson this epic closes. Each queued build's per-item **branch + merge state** surfaces in the EXISTING
`docs/BUILD-STATUS.md` **"Built-but-unmerged"** section (its L5 stack), reusing the **existing render**
(`core/scripts/docs-index.py::render_build_status` / `collect_build_status`) — this is **NOT a new
dashboard** and **NOT a parallel renderer**. The daemon's per-item drains feed the same
`launch-manifest.py features[]` the dashboard already reads; the linear **stack** (`main → A → B → C`)
then shows up as the built-but-unmerged roster automatically.

**The render path is feed-then-regenerate — never an in-place edit (F-002 / ADR-109 W3, binding):**

1. On each item state change (after `running/ → done/` or `running/ → failed/`) the daemon calls
   `launch-manifest.py set --label <item> --status <done|failed> --branch <item-branch> --sha <tip>` to
   update `features[]` (status + branch + sha).
2. The daemon then runs `python3 core/scripts/docs-index.py` to **REGENERATE** `docs/BUILD-STATUS.md`.
   `docs-index.py` rewrites BOTH `docs/INDEX.md` AND the date-stamped `docs/BUILD-STATUS.md` from
   `features[]` + live git branch state — that two-file regenerated output is **expected** and is the
   committed artifact.

`docs/BUILD-STATUS.md` is **GENERATED, never authored** (its own header; ADR-109 W3): the daemon MUST
NOT open it and write into it. The only legitimate visibility path is `launch-manifest.py set` →
`docs-index.py`. The render call site lives at the item-state-change point in the loop body above
(grep-visible `BUILD-STATUS` / `render` / `update` — the `docs-index.py` regen invoked each iteration,
not merely defined). The built-but-unmerged **queue stack** is thus surfaced by the existing pattern; the
`queue` / `stack` / `built-but-unmerged` tokens are present in both this skill and the regenerated
`docs/BUILD-STATUS.md` section header.

## End-of-queue WRAP — surface readiness, queue the merge lever for the operator (AC-019)

When the daemon's fresh read of `docs/step-4-queue/pending/` finds **no dep-ready BUILD-KIND remaining** (the
queue has drained — every buildable item is in `done/` or `failed/`), it emits the **end-of-queue WRAP**.
The WRAP is the operator's "eyes at the end" review surface — informational + a **queued lever**, not a
halt that needs a response:

```text
queue-chew WRAP — queue drained.
  N items built on `<tip>`, linear stack (main → A → B → … → <tip>), ready to FF-merge.
  M STAGE specs produced to docs/step-3-specs/ — review them, then queue their builds (no auto-chain; the morning review gate IS the value).
  NOTE — K build(s) are queued 'after' a STAGE spec produced THIS drain (<labels>); by design they do NOT auto-build (the morning review gate). They remain in pending/ — queue/confirm them after reviewing the spec. This is expected, not an error.
  REFUSED_RAW raw-plan item(s) left queued — these built BY DEFAULT unless QUEUE_REFUSE_RAW_PLAN=1 was set (opt-OUT to refuse).
  Decision logs: docs/step-5-pipeline/<date>/<run>/autonomous-decisions-log.md (per-item park/skip records).
  The merge-to-main lever is QUEUED FOR THE OPERATOR — the daemon STACKS branches but NEVER merges to main.
  Run the FF-merge yourself after review:  git checkout main && git merge --ff-only <tip>
```

*(The STAGE-spec line is emitted when ≥1 `roadmap` STAGE entry produced a spec — the morning-review surface
for the two-pass flow. The **NOTE line** is the CR-001 silent-strand close: it is emitted only when ≥1
pending build declares `after <label>` for a label STAGE-routed THIS drain — that build will never resolve
this drain (the STAGE label never enters `qc_completed_labels()` — done/ ∪ step-6-done/queue/, never
staged/), so the daemon surfaces it as an EXPECTED informational NOTE rather than letting it strand
silently; it is never a failure. The `REFUSED_RAW` line is emitted only when `QUEUE_REFUSE_RAW_PLAN=1` was set AND ≥1
raw plan was refused by the readiness gate (§ Build-readiness routing) — under the default build-by-default
posture raw plans build, so this line is normally empty.)*

The daemon **STACKS** branches but **NEVER merges to main** (ADR-105 shared-state floor / rules-git.md):

- It surfaces "**N** items built on `<tip>`, linear stack, **ready to FF-merge** — decision logs here."
- The **merge-to-main lever is QUEUED for the operator**, **never auto-merged**. A wrong autonomous
  placement lands on a reviewable, revertible stacked branch — **nothing reaches a shared system**
  (remote / main / prod) unattended. No daemon path runs the FF-merge; the operator does, after review.
- The WRAP is plain text (§ Operator-legibility) — no halt, no color-only signal.

The WRAP grep tokens are present: `WRAP` / `FF-merge` / `ready to` / `shared-state` / `never merges to
main`. The WRAP **does not** cross the shared-state floor — it queues the lever and ends the drain.

## ADR-093 overnight resume — CONSUME the folder-state contract, build NOTHING for survival (AC-020)

Overnight survival **REUSES ADR-093** (`docs/decisions/ADR-093-overnight-resume.md`) — the adopt-and-pin
resume wrapper. The daemon **builds NOTHING new for survival**: it adds no checkpoint, journal, or
in-memory state. An ADR-093-restarted daemon needs **NO in-memory state** because **state IS location**
(location-is-status, ADR-087):

- On restart the daemon **re-reads `docs/step-4-queue/`** (the same fresh-FS-read the iteration loop already
  does), sees which entries are in `done/` / `failed/` vs `pending/` / `running/`, and **resumes from the
  next dep-ready `pending/` item** — the next earliest-`seq` entry whose `after` deps are all in `done/`.
- **No double-builds:** a `done/` entry is out of `pending/`'s glob range, so the **glob-never-re-picks**
  property (Wave-2 AC-013) guarantees it is **never re-selected** — the restart cannot rebuild completed
  work. Mop-up is **idempotent** (re-deriving from the folder yields the same pick); transitions are
  **atomic** via the `git mv` (move-file / location-is-status). A `running/`-stranded entry is a crashed
  mid-flight build (re-launch or surface — SA-004 in § Termination), **never** treated as `done`.
- This is pure **re-read-on-resume** — the same discipline ADR-093 documents for the fleet manifests.
  The wave authors **no survival mechanism**; it wires (documents) the folder-state contract and proves
  it with an assertion.

**Executable resume assertion (AC-020 — NOT a prose-only claim).** `core/scripts/test-queue-chew.sh` is
a real shell harness (mirroring `test-launch-manifest.sh` / `test-queue-order.sh` structure) that sets up
a temp `pending/`+`done/` folder state and asserts a simulated mid-drain restart **resumes from the next
pending item without rebuilding a `done/` item**: it asserts the documented earliest-`seq`-dep-ready
selection picks the next `pending/` item, that a `done/` item is **never** re-selected
(glob-never-re-picks / no double-build), that a dep-gated item waits for its `after` dep to reach
`done/`, that selection is **idempotent**, and that a fully drained queue yields no pick (the WRAP point).
Run it: `bash core/scripts/test-queue-chew.sh` → `queue-chew resume: 6 passed, 0 failed`.

## Worked example — one BUILD-KINDS item through pick → launch → await → done (AC-014)

Tracing a real `orchestrated`-kind item end-to-end (a BUILD-KINDS tape, doubling as the AC-022
build-kinds-subset evidence — an `orchestrated` item drained by the daemon):

1. **Poll.** Iteration reads `docs/step-4-queue/pending/` fresh. It finds one entry **FOLDER**,
   `orchestrated-add-user-profiles/`, holding the moved source artifact + `sidecar.json`
   `{label:"orchestrated-add-user-profiles", verb:"orchestrated", seq:10, after:[], target:"."}` (ADR-124:
   `target:"."` = the entry folder is the build input — the in-queue artifact, NOT an external
   `docs/step-3-specs/` path). Its `after` is empty → it is dep-ready.
2. **Allowlist.** `verb=orchestrated` ∈ `{orchestrated,nimble,chain,loop}` → accepted (a `roadmap` entry
   would instead take the STAGE pre-route — produce a spec, no build; a `sweep` entry would be REJECTED).
3. **Drain to running/.** `git mv docs/step-4-queue/pending/orchestrated-add-user-profiles
   docs/step-4-queue/running/orchestrated-add-user-profiles` (the whole folder; the artifact travels with it). A
   second poll of `pending/` now never re-picks it.
4. **Launch + await.** It is the first item → base is `main`; `PRIOR_TIP` = current `main` tip. The build
   target is `docs/step-4-queue/running/orchestrated-add-user-profiles/` (= `running/<entry>/<sidecar.target>`,
   `target:"."`, validated UNDER `docs/step-4-queue/` by SA-002). The daemon fires ONE top-level `/orchestrated`
   Workflow pointed at that in-queue target with `baseSha=$PRIOR_TIP`. The launched build's `waveStep0`
   (orchestrated.js L1124-1133) resets onto `baseSha`. The daemon **BLOCKS** on this call — that block is
   the await; no second item is picked up while it runs. A producer move-on-advancing `nimble-fix-typo/` to
   `pending/` during this build does NOT interrupt it (files-as-mailbox).
5. **Completion.** The Workflow emits its `<task-notification>`; the daemon unblocks. `NEW_TIP =
   git rev-parse HEAD` is the wave branch tip — call it `A`.
6. **Drain to done/ + reconcile.** `git mv docs/step-4-queue/running/orchestrated-add-user-profiles
   docs/step-4-queue/done/…` (the whole folder, artifact included); then `launch-manifest.py set
   --label orchestrated-add-user-profiles --status done --sha A`. The wave→main merge is **NOT** done here —
   it is queued for the operator (shared-state floor).
7. **Pop the next.** `PRIOR_TIP = A`; loop back to a fresh `pending/` read. The next item (e.g.
   `nimble-fix-typo`) launches with `baseSha=A` → the stack becomes `main → A → B`.

---

## Worked example — a real BUILD-KINDS tape through pick → stack → done → WRAP (AC-022)

This trace runs a **real BUILD-KINDS tape** end-to-end — `orchestrated A after-nothing → orchestrated B
after A` — through **pick → stack → done → WRAP**, the cross-cutting integration evidence that the daemon
chews the build-kinds subset of the canonical worked example.

**The canonical worked-example tape** (epic intent §"Worked example", `docs/step-3-specs/autonomous-work-queue/README.md`
L12-16) mixes build verbs with **planning verbs**. Post-ADR-132, `roadmap` is a **routed STAGE-kind** (it
produces a spec, no auto-chain); only `sweep` stays **deferred** (it has no headless-convergence mode yet):

The tape is **two passes** — and the build of a STAGE spec is queued in the SECOND pass, AFTER the human
reviews the spec the first pass produced. An `after <roadmap-label>` build is NOT queued in the same
evening's tape: by the no-auto-chain contract a `roadmap` STAGE label never lands in the completion set
(`qc_completed_labels()` unions `done/ ∪ step-6-done/queue/`, NOT `staged/`), so a build queued `after` it
**this drain** would strand in `pending/` forever — the morning-review gate IS the value.

```text
# === PASS 1 (this evening) — drain builds + produce specs; the daemon STOPS at drain-end ===
/queue add sweep                                              # deferred (planning verb; sweep ∉ STAGE_KINDS — daemon REJECTS at drain)
/queue add roadmap dogfood-fixes        after orchestrated    # STAGE-kind — produces a spec to step-3-specs/ (no build, no archive, NO auto-chain)
/queue add roadmap autonomous-work-queue after orchestrated   # STAGE-kind — produces a spec; the morning review gate IS the value
#   (NO `orchestrated … after roadmap` line in PASS 1 — a build queued `after` a STAGE label this drain
#    would never resolve: the STAGE label drains to staged/, which is NOT in qc_completed_labels().)

# === PASS 2 (next morning, AFTER the operator reviews the specs PASS 1 produced) ===
/queue add orchestrated dogfood-fixes                         # BUILD KIND — queued AFTER reviewing the dogfood-fixes STAGE spec
/queue add orchestrated autonomous-work-queue                 # BUILD KIND — queued AFTER reviewing the autonomous-work-queue STAGE spec
```

The `roadmap` lines are **routed STAGE-kinds** (§ BUILD KINDS + the STAGE-kind): the daemon produces
the spec to `docs/step-3-specs/`, drains the entry to `staged/` (NOT `done/`), **skips archival**, and does
**NOT auto-chain** the dependent `orchestrated` build — the human reviews the spec between passes, then
queues its build in PASS 2. The `sweep` line stays **deferred**: `sweep ∉ STAGE_KINDS` (and ∉ `KINDS`), so
it falls through to `qc_validate_kind` and is **REJECTED at drain** and left in `pending/` (it needs an
unattended-convergence mode that does not exist yet). The trace below demonstrates the **build-kinds**
chewing; the `roadmap` STAGE route is traced/asserted separately (§ STAGE-kind + `test-queue-chew-e2e.sh`).

**The build-kinds trace — `orchestrated A → orchestrated B after A` → WRAP:**

1. **Pick A.** Fresh read of `pending/` finds entry folder `orchestrated-A/` (`sidecar.json`
   `{verb:orchestrated, seq:100, after:[], target:"."}`) dep-ready (no deps). `verb=orchestrated` ∈ the
   allowlist → accepted.
2. **Stack A on main.** First item → `PRIOR_TIP = main` tip. `git mv pending/orchestrated-A
   running/orchestrated-A` (the whole folder); launch `/orchestrated` for A's in-queue target
   (`running/orchestrated-A/`) with `baseSha=main`; **await** its `<task-notification>`.
3. **A done.** `LAUNCH_RC == 0` + clean tree → `git mv running/orchestrated-A done/orchestrated-A`;
   `launch-manifest.py set --label orchestrated-A --status done --branch feature/wave-A --sha A_TIP`;
   **regenerate BUILD-STATUS** (`docs-index.py`) → A appears in the built-but-unmerged stack.
   `PRIOR_TIP = A_TIP`.
4. **Pick B.** Fresh read of `pending/` finds entry folder `orchestrated-B/` (`sidecar.json`
   `{verb:orchestrated, seq:200, after:["orchestrated-A"], target:"."}`). Its `after` dep `orchestrated-A`
   is now in `done/` → **dep-ready**.
5. **Stack B on A's fresh tip (linear stack).** `git mv pending/orchestrated-B running/orchestrated-B`;
   launch `/orchestrated` for B's in-queue target with `baseSha=A_TIP` → B re-roots onto A (`waveStep0`),
   so the stack is `main → A → B`. Await completion.
6. **B done.** `git mv running/orchestrated-B done/orchestrated-B`; `launch-manifest.py set
   --label orchestrated-B --status done --branch feature/wave-B --sha B_TIP`; regenerate BUILD-STATUS → both
   A and B show in the built-but-unmerged linear stack. `PRIOR_TIP = B_TIP`.
7. **WRAP.** Next fresh read of `pending/` finds no dep-ready BUILD-KIND (a `roadmap` line would have taken
   the STAGE route → `staged/` already; a deferred `sweep` line stays in `pending/`, rejected-not-drainable)
   → the daemon emits the **end-of-queue WRAP**:
   "**2** items built on `B_TIP`, linear stack (`main → A → B`), **ready to FF-merge** — decision logs
   here." The merge-to-main lever is **QUEUED for the operator**; the daemon never merges to main.

The trace ends in the **same WRAP** authored above (§ End-of-queue WRAP) — it references that WRAP, it does
not redefine it.

## Security / autonomy floor — cross-cutting close-out (AC-023, binding — security-gated)

The full shared-state autonomy floor is stated above (§ The shared-state floor); this close-out makes the
floor's grep-tokens explicit and binds the no-forbidden-invocation standard the floor prose is evidence
*for*. The daemon runs **unattended**, so **nothing reaches a shared system (remote / main / prod)
unattended** (ADR-105 shared-state floor, `rules-git.md`):

- The daemon **MAY** stack branches and **MAY** push a **wave branch** as backup
  (`git push origin feature/wave-<slug>`, no force) — that lands on a reviewable, revertible branch.
- The daemon **MUST NOT** **merge to main**, open the wave→main PR, or **force-push**. There is **no
  `git push origin main`, no `gh pr merge`, no `--force` / `--force-with-lease` (no force-push)** in any
  daemon code path. All of these are **operator-driven** — the merge-to-main lever is queued (§ WRAP),
  never the daemon's to pull.
- A wrong autonomous placement lands on a **reviewable branch, never on main** — the autonomy guardrail.

Floor grep-tokens, all present: `never merges to main` / `operator-driven` / `shared-state` /
`force-push` / `merge-to-main`. The substantive standard: **audit the daemon's actual git commands — no
forbidden invocation exists in any path** (the WRAP's only main-touching line is an OPERATOR instruction
to run `git merge --ff-only` after review, never a daemon action).

## Operator-legibility — every queue state is `ls`-legible, output is plain-text (AC-024)

This epic is `has_ui: false`; the only "accessibility" surface is the **legibility of the daemon's text
outputs**. Two binding properties:

1. **`ls`-legible state (location-is-status).** Every queue state is answerable by `ls` with no manifest
   parse: `ls docs/step-4-queue/pending/ docs/step-4-queue/running/ docs/step-4-queue/done/ docs/step-4-queue/failed/` answers "what is
   queued / running / done / failed?" directly — a job's **location IS its lifecycle status**
   (location-is-status, ADR-087; the Wave-1 subfolders, AC-002). The operator reads **folders, not JSON**.
   `failed/` is the `ls`-legible terminal failure state. This is the `ls`-legible / location-is-status
   contract — read the folder, not the manifest.

   **"What is done?" reads the UNION after archival (ADR-128 D-3 / examiner F-001 — the legibility close).**
   Post-settlement archival (§ End-of-drain archival) empties `done/` into the canonical
   `docs/step-6-done/queue/`, so the complete "what successfully completed?" answer is the **union**
   `done/ ∪ step-6-done/queue/`. The sanctioned legibility read is the **`qc_completed_labels()` chokepoint**
   (the SAME single completion read the dependency gate uses) — `ls docs/step-4-queue/done/` shows only the
   *transient, not-yet-archived* tail, while `ls docs/step-6-done/queue/` shows the *archived* completions;
   reading BOTH (or calling `qc_completed_labels`) answers "what is done?" completely. **Never glob bare
   `done/` to answer "is X done?"** — an archived entry would be silently missed (the no-bare-glob discipline,
   ADR-128 D-3; AC-9/AC-11). `step-6-done/queue/` is itself `ls`-legible (location-is-status holds across the
   archival hop — an archived entry's folder IS its "completed-and-archived" status).
2. **Plain-text, screen-reader-friendly output.** The WRAP (§ End-of-queue WRAP) and the regenerated
   `docs/BUILD-STATUS.md` built-but-unmerged section are **plain text** with **no color-only signal** — no
   information is conveyed solely by ANSI color, so a screen reader or a no-color terminal loses nothing.
   Status is carried by **words and folder location** (`done` / `failed` / the `done/` vs `failed/`
   folder), never by color alone.

Legibility grep-tokens, all present here and in `docs/step-4-queue/README.md`: `ls-legible` /
`location-is-status` / `plain-text`.

---

## Termination

The daemon exits when `pending/` holds no dep-ready BUILD-KINDS entry — either it is empty, every remaining
entry is blocked on an unsatisfied `after` dep, every remaining entry is a rejected planning verb, **or every
remaining entry is in the in-session skip-sink** (REJECTED/REFUSED this run — `QC_SKIP`, CR-002). The exit on
an empty dep-ready set is deliberate: a Claude session must not busy-wait (it burns context/tokens). Because
all lifecycle state is **on disk** in `docs/step-4-queue/{pending,running,done,failed}/` and the fleet manifest, a
re-invoked `/queue-chew` resumes by **re-deriving from the folder** — there is no in-memory state to lose
(matching ADR-093 overnight-resume's re-derive-on-resume discipline). The `QC_SKIP` skip-sink is **in-session
only** — a fresh run re-evaluates a previously skipped entry (e.g. after the operator `/roadmap`s a refused
raw plan).

### Walk-away `--watch` — event-driven re-launch, NOT an LLM busy-wait (Wave 4 — ADR-124)

Exit-on-empty is correct for a **finite tape** (drain a known batch, stop), but it does not deliver the
epic's **"feed work over time and walk away"** north star: a producer append landing *after* a drain strands
in `pending/` until someone re-invokes the chew. **`core/scripts/queue-watch.sh`** closes that gap as a
**thin shell watcher** (the architectural catch: a Claude session can't cheaply busy-wait, so the EXPENSIVE
LLM chew stays event-driven, not poll-driven). The watcher waits cheaply (`inotifywait` if present, else a
bounded `sleep`) and launches a **fresh one-shot `/queue-chew`** only when `pending/` gains a dep-ready entry:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
"$S/queue-watch.sh" --max-idle 1800 --interval 10       # walk away; re-launches a chew on each new entry
```

- **Bounded (anti-limbo):** exits after `--max-idle` seconds idle, or `--max-runs` launches; a heartbeat is
  logged each idle tick so a forgotten watch is visible.
- **No new survival state (ADR-093 reconciliation):** each launched chew re-derives lifecycle from the folder;
  the watcher only decides *when* to launch. ADR-093 handles restart across the usage window; the watcher
  handles drained-then-new-work — different problems, composable.
- **Shared-state floor intact:** the watcher only launches chews (which STACK branches); it never merges or
  pushes. Finite-tape mode = run `/queue-chew` directly (no watcher); continuous mode = `queue-watch.sh`.

**Resume — a `running/`-stranded entry is a crashed in-flight build, NEVER `done` (binding — SA-004).**
On resume, an entry found in `running/` means a build **crashed mid-flight**: the daemon **re-derives the
base from the last `done/` tip** and either **re-launches** the stranded item or **surfaces it to the
operator** — it **NEVER** treats a `running/` entry as `done`. This is consistent with the ADR-123
crash-consistency ordering the skill already references (folder `git mv` first, manifest `set` second;
re-derive from the **folder** on resume): because the folder `git mv` to `done/` happens **before** the
manifest `set`, an entry still in `running/` provably did not complete its drain, so resume must treat it
as in-flight (re-launch or surface), never as completed.

## References

- `docs/decisions/ADR-122-autonomous-work-queue.md` — the epic decision.
- `docs/decisions/ADR-124-queue-v1-1-move-on-advance.md` — entry-as-folder / move-on-advance / sourceable
  lib (this wave's design source of truth).
- `docs/decisions/ADR-123-autonomous-work-queue.md` — the within-queue-drain invariant (D-3) ADR-124 EXTENDS + PRESERVES.
- `docs/step-4-queue/README.md` — the queue contract + § "Source-of-truth split" (folder=lifecycle / manifest=runtime).
- `core/skills/queue/SKILL.md` — `/queue add`, the producer move-on-advance door (Wave 1).
- `core/scripts/queue-chew-lib.sh` — the SOURCEABLE deterministic mechanics, split across the dispatch
  (SHR3-T4): `qc_next` (before-dispatch: pick / SA-001/002/003 / drain / target resolution / readiness) +
  `qc_settle` (after-dispatch: outcome branch / arbiter / reconcile) this SKILL sources (ADR-124). The REAL
  dispatch+await is the SESSION's, fired BETWEEN the two halves; `launch_workflow` is demoted to the e2e test
  stub only (no production call site).
- `core/scripts/test-queue-chew-e2e.sh` — the executable e2e proof (green = a chew built a file end-to-end).
- `core/scripts/queue-order.py` — the deterministic orderer that computes `seq` (Wave 1; reads the entry-as-
  folder `pending/*/sidecar.json` shape); its `dependents` subcommand (AWQ-T6) surfaces an item's dependents
  from both edge kinds for the arbiter (AC-017).
- `core/scripts/workflows/orchestrated.js` — `waveStep0` (L1124-1133), the re-root the daemon reuses (does NOT re-implement).
- `core/scripts/launch-manifest.py` — `KINDS` (L30), `STATUSES`, the `set` verb for runtime status.
- `core/skills/loop-task/SKILL.md` — the `/loop`-style session-loop-with-durable-on-disk-state pattern this skill mirrors.
- `docs/decisions/ADR-039-engine-on-workflow-and-thin-manifest.md` — the no-FS Workflow contract (why this is a session loop).
- `docs/decisions/ADR-105-default-autonomous-disposition.md` — the shared-state floor the daemon stays behind.
