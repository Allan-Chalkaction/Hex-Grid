---
name: launch
description: "Fire a FLEET of autonomous build jobs (orchestrated · nimble · chain · loop — one per spec) and review them in one deliberate fan-in pass (/launch review). Plan-day → /launch → walk away → /launch review → merge."
user_invocable: true
---

# /launch — overnight / parallel autonomous fleet (T10; multi-track ADR-053)

`/launch` turns N specs into N autonomous **build jobs** — each in its own git worktree/branch — then
reviews them in ONE deliberate fan-in pass. Each job has a **kind** ∈ `orchestrated` | `nimble` | `chain` |
`loop` (default `orchestrated`, back-compatible). It is **thin glue**: the queue + concurrency dial + token
ceiling + fan-in protocol. It does NOT rebuild a dashboard or scheduler — fleet visibility is native **Agent
View**; background/scheduled execution is native **`/bg` / Routines**.

> **Build jobs only (ADR-053).** The queue holds *autonomous build* paths — they share the autonomy
> contract and each produces a mergeable branch. **Planning jobs (`/roadmap`, planner jams) are NOT
> queueable here:** roadmap halts at every round boundary by contract (ADR-030) and produces docs, not a
> branch, so it can't ride the walk-away/fan-in-merge model. See the `multi-track-queue` idea cluster for
> the planning-queue (Option B) and job-graph (Option C) follow-ons.

> **Prerequisite (binding):** single-run trust. Each orchestrated run must be fire-and-forget (the autonomy
> contract + consolidated halts hold — a run surfaces only on the ADR-018 five). Do NOT fleet-parallelize
> until one orchestrated run is trustworthy unattended. A fleet of untrustworthy runs is not trustworthy.

> **Substrate path resolution (ADR-031):** scripts live at `core/scripts/…` in claude-infra, `.claude/scripts/…`
> in a consumer. Resolve first: `S=.claude/scripts; [ -d "$S" ] || S=core/scripts`.

## Usage
- `/launch` (no specs) or `/launch --all` — drain **every** ready wave folder in `docs/step-3-specs/` (glob
  `docs/step-3-specs/*/waves/*/`). The build queue is status-by-location: a wave folder under `docs/step-3-specs/` is
  ready-to-build; once a build begins it MOVES out (ADR-051), so the glob never re-picks an in-flight wave.
- `/launch <wave-slug> <wave-slug> …` — queue the named waves only (resolved by glob, see step 1). A bare
  slug/path with no `kind:` prefix defaults to `kind=orchestrated` (back-compat).
- `/launch <spec-path> …` — explicit spec paths (a wave folder or its `<wave-slug>.md`) also accepted.
- `/launch <kind>:<spec> …` — **mixed-kind queue (ADR-053).** Prefix a spec with its job kind, e.g.
  `/launch nimble:docs/tasks/fix-foo.md orchestrated:docs/step-3-specs/x/waves/w1/ chain:docs/tasks/audit.md`.
  `kind ∈ orchestrated | nimble | chain | loop`. For `chain`, the spec carries the ordered agent list
  (same as `/chain a,b,c`). Bare tokens (no `kind:`) stay orchestrated.
- `/launch … --concurrency K` — K live at once. **K=1 = fully serial** (recommended overnight default,
  gentlest on the 5-hr window + rate limits). K=2–3 daytime. Cap ≤ ~10.
- `/launch … --token-ceiling N` — pause the queue when the batch's cumulative output tokens hit N
  (remaining features stay `queued`, resumable). Calibrate K and N upward from K=1 after observing tolerance.
- `/launch add [<kind>:]<spec>` — append a feature to a **live or completed** fleet, then re-enter the
  existing §2 drain loop (it falls into §2's `next` exactly as a §1-queued feature does). A bare token
  defaults `kind=orchestrated`; a `<kind>:<spec>` token (`kind ∈ orchestrated | nimble | chain | loop`)
  selects the kind — the **same** token grammar as `/launch` (§1), no new flag. Re-adding a label already
  present is **rejected** (the fleet is unchanged), not silently upserted. See "Add to a live/completed
  fleet" below.
- `/launch review [slug]` — the fan-in pass over the fleet's branches.

> **Queued-truth folder (cross-reference, not a new path).** The `ls`-legible queue of build jobs
> waiting for pickup lives at `docs/step-4-queue/` — see `docs/step-4-queue/README.md`. Its entries
> (`docs/step-4-queue/<kind>-<label>.md`, `kind ∈ orchestrated | nimble | chain | loop`) compose with the
> **existing** `add`/drain path above: the same `<kind>:<spec>` token grammar (§1 L35-38, `/launch add`
> §1 L43-48) and the same §2 drain loop. Drain-on-pickup reuses the orchestrated SKILL step 1.5 `git mv`
> primitive — **no new `next`/dispatch backend and no second add/drain loop.**

## 1. Build the fleet manifest (the durable, cross-session index — AC-7)

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
SLUG="<batch label, kebab>"
FLEET="docs/step-5-pipeline/$(date +%Y-%m-%d)/$(date +%H%M)-FLEET-$SLUG/fleet.json"
mkdir -p "$(dirname "$FLEET")"
$S/launch-manifest.py init --path "$FLEET" --slug "$SLUG" --concurrency 1   # --token-ceiling N optional

# Resolve the spec list. Tokens are bare (→ kind=orchestrated, ADR-051 build queue) or `kind:spec` (ADR-053):
#   no args / --all → every ready wave folder (orchestrated);  named slugs/paths → as given;
#   `<kind>:<spec>` → that kind (kind ∈ orchestrated|nimble|chain|loop).
if [ -z "$SPECS" ]; then SPECS=$(ls -d docs/step-3-specs/*/waves/*/ 2>/dev/null); fi
for token in $SPECS; do
  case "$token" in
    orchestrated:*|nimble:*|chain:*|loop:*) KIND="${token%%:*}"; spec="${token#*:}" ;;
    *)                                      KIND="orchestrated"; spec="$token" ;;
  esac
  if [ "$KIND" = "orchestrated" ] && [ -d "$spec" ]; then
    # Orchestrated wave folder: add its # Wave: schema file (skip -prompts.md / .spec.md).
    WAVE_MD=$(ls "$spec"/*.md 2>/dev/null | grep -v -- '-prompts.md\|.spec.md' | head -1)
    spec="${WAVE_MD:-$spec}"
  fi
  $S/launch-manifest.py add --path "$FLEET" --kind "$KIND" --spec "$spec"
done
```

The fleet manifest indexes per-feature `{label, kind, spec, status, branch, run_dir, sha}`. A fresh session
reconstructs full fleet state from this file + the per-feature branches alone — **no shared session
context** (AC-7). This is what makes the fleet resumable across the 5-hr window and across sessions.

### Add to a live/completed fleet (`/launch add`)

A fleet is appendable after it is built — mid-flight (features still `running`) or after `next` has already
returned `COMPLETE`. `/launch add [<kind>:]<spec>` is a **door over the existing `add` backend** (§1 L68); it
authors no new dispatch, merge, or review path. It reuses §1 verbatim:

1. **Resolve the spec token with the §1 grammar — do NOT introduce a second parser.** Apply the same `case`
   split as §1 (L58-69): `orchestrated:*|nimble:*|chain:*|loop:*` → `KIND="${token%%:*}"; spec="${token#*:}"`;
   a bare token → `KIND="orchestrated"; spec="$token"`. Resolve `$S` (L48: `S=.claude/scripts; [ -d "$S" ] ||
   S=core/scripts`) and the orchestrated `# Wave:` schema-file pick (L63-67) exactly as §1 — re-derive nothing.
2. **Append via the existing backend call shape (L68), pointed at the live `$FLEET`** — identical to §1:

   ```bash
   # $S, $KIND, $spec resolved as in §1 (L48, L58-69, L63-67); $FLEET is the already-built fleet manifest.
   $S/launch-manifest.py add --path "$FLEET" --kind "$KIND" --spec "$spec"
   ```

   No edit to `launch-manifest.py`; the verb only reaches the shipped `add`. Label defaults to the spec
   basename (backend `cmd_add`). **Reject-on-duplicate (the backend does NOT upsert):** a second `add` of a
   label already present exits non-zero and leaves the fleet unchanged (backend `_die(... exit 2)`); to add
   anyway, re-label or pick a different spec.
3. **Fall back into §2 (L76-111) — the existing drain loop is the consumer; author no new loop.** After the
   append, re-enter §2 by running `launch-manifest.py next --path "$FLEET"`: the new feature is `queued`, so
   `next` routes it through the standard decision (`RUN:<label>` → §2a dispatch-by-kind when capacity frees;
   `WAIT:<n>` while a slot is busy). Add-to-**live** simply lengthens the queue §2 already drains; add-to-a-
   **`COMPLETE`** fleet re-opens it — `next` now returns `RUN:<label>` (capacity is free), and §2 drains it.
   Do NOT add a `set --status running` / dispatch step here; §2a already owns that.
4. **Fold into the existing §3 fan-in (L113-123) — introduce no new review/merge primitive.** When the
   re-drained fleet reaches `COMPLETE`, the added feature's `done` branch is enumerated by the **same**
   `/launch review` pass (§3) as every other feature — ONE consolidated surface, kind-agnostic. **Zero
   auto-merge:** the add path ends at §3's fan-in and the operator remains the merge authority (§3 +
   "Out of scope"); the verb performs no integration step of its own — landing the branch stays an
   operator-driven §3 action.

## 2. Drain the queue (concurrency-capped)

Loop on the manifest's dispatch decision; never exceed `--concurrency`:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
$S/launch-manifest.py next --path "$FLEET"
#   RUN:<label> → start that feature (step 2a)        WAIT:<n> → a slot is busy; poll when one finishes
#   DRAINING    → none queued, some still running       COMPLETE → fan-in review (step 3)
```

**2a. Start one feature** (`RUN:<label>`):
1. Mark it running: `$S/launch-manifest.py set --path "$FLEET" --label <label> --status running`.
2. **Dispatch by `kind`** (read the feature's `kind` + `branch` from `launch-manifest.py read`) — an
   autonomous run **in isolation** (its own worktree/branch), as a background session (native `/bg`, or a
   **Routine** for laptop-off overnight, or an `Agent`/`Workflow` dispatched with `run_in_background:
   true`). Every kind runs under the autonomy contract — surfaces only on the ADR-018 five (→ Agent View
   "Blocked"), never nags. Use each kind's own SKILL exactly:
   - **orchestrated** (branch `feature/wave-<label>`) — the orchestrated SKILL (single-call `full` for a
     flat wave; the **wave loop** step 2′ for a dependency-deep wave). **Do NOT pre-move the spec** — the
     orchestrated SKILL's step 1.5 moves the wave folder out of `docs/step-3-specs/` into its run folder as the
     build's first act (ADR-051). Launch only points the run at the spec.
   - **nimble** (branch `feature/nimble-<label>`) — the nimble SKILL. **Nuance (ADR-053):** nimble
     integrates *in-place on its working branch*, so set the run's working branch to the feature branch
     (`feature/nimble-<label>`) before it starts — then the staleness-guarded integrate lands there and
     the fan-in step has a branch to merge (not the shared session branch).
   - **chain** (branch `feature/chain-<label>`) — the chain SKILL with the spec's ordered agent list.
   - **loop** (branch `feature/loop-<label>`) — the loop-task SKILL.
3. On completion: `$S/launch-manifest.py set --path "$FLEET" --label <label> --status done|failed|blocked
   --branch <feature-branch> --run-dir <D> --sha <artifacts-sha>` (use the kind's feature branch).

Repeat `next` until `COMPLETE`. Honor the token ceiling: when cumulative output tokens hit `N`, stop
starting new features (leave them `queued`) and surface the pause; the queue resumes later off the manifest.

**Fleet visibility:** native **Agent View** (each feature = one entry — Running/Blocked/Done/Failed). Do
NOT rebuild a dashboard.

## 3. Fan-in review (`/launch review`) — the one disciplined step

Reuse `/merge-orchestrator` + batch-gate — do NOT duplicate them. Enumerate the fleet's `done` branches
(`launch-manifest.py read`), run the gate matrix per branch (`/batch-gate`), and present **ONE consolidated
surface**: per feature → summary, diff, gate verdicts, any deferred findings. Then **merge deliberately, one
at a time** — `/merge-orchestrator` (squash default, post-merge gate). **Nothing auto-merges; the operator
is the merge authority** (AC-2). A `blocked` feature carries its ADR-018 surface for a one-line answer.

This step is **kind-agnostic (ADR-053):** every job kind produces a kind-specific feature branch
(`feature/wave-<label>` for orchestrated; `feature/<kind>-<label>` for nimble/chain/loop), so
enumerate-gate-merge works identically regardless of what built each one.

## 4. The 5-hour window (AC-6) — adopt + PIN a resume wrapper (operator setup)

Native auto-resume across the 5-hr usage window **does not exist** (verified — only `/resume` exists, and
nothing detects a limit-stop and re-fires it). So a long overnight fleet needs an **outer-loop wrapper** that
detects the limit-stop → sleeps to reset → re-fires per parked feature. This wrapper is **third-party and
CLI-fragile** — it is an operator-side adopt-and-**pin** step, not built here:

- Reference wrappers: `karthiknitt/smart_resume`, `terryso/claude-auto-resume`. **Pin a version and
  version-test it** against your CLI (it wraps the CLI's outer loop and can break on CLI changes).
- It re-fires `/resume <feature-slug>` per parked feature off the **fleet manifest** + each wave's own
  thin manifest (T16 wave-loop durability) — completed waves/tickets are not redone. No lost work.
- **Operating practice / safety valve:** size each batch to a single window where you can (the surest fix);
  K=1 overnight; the per-batch token ceiling caps cost.
- **Full procedure (pin + version-test + supply-chain note):** `docs/launch/overnight-resume.md`.

## Out of scope (binding)
- Do NOT build a bespoke fleet dashboard or scheduler — adopt Agent View / Routines.
- Do NOT auto-merge fleet output — fan-in review is mandatory.
- Do NOT parallelize before single-run trust is proven.
- Do NOT queue **planning jobs** (`/roadmap`, planner jams) here (ADR-053). Roadmap halts at every round
  boundary by contract (ADR-030) and produces docs, not a mergeable branch — incompatible with the
  walk-away/fan-in-merge fleet. The planning-queue (Option B) and job-graph (Option C) follow-ons live in
  the `multi-track-queue` idea cluster, gated on routing the roadmap round-funnel through the engine.

## Playbook (plan-day → launch → fan-in → merge)
1. **Mon AM — plan:** `/roadmap` → N locked wave specs (the work that determines overnight success).
2. **Mon midday — launch:** `/launch spec/x spec/y spec/z --concurrency 1` → walk away.
3. **While away:** glance at Agent View; answer a Blocked feature's one-liner from your phone; ignore the rest.
4. **Tue AM — fan-in:** `/launch review` → one consolidated surface → merge each deliberately. Plan the next batch.
