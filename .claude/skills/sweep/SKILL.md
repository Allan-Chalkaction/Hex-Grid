---
name: sweep
description: On-demand triage of the ideas inbox + the two shelves + the chore lane (docs/step-1-ideas/ + docs/step-1-ideas/backlog/ + docs/step-1-ideas/parked/ + docs/step-1-ideas/chores/) AND the in-skill jam-convergence door. Renders ONE table (item, age, stage memory, gist, recommended verdict); operator answers inline; the skill performs file moves, promotes needs-shaping captures to ready-to-build, and converges jam clusters in-skill (cluster + compose + thesis + examiner fold-in + vitality line). Triggers - "/sweep", "triage the inbox", "sweep deferrals", "converge the jam", "what's in the inbox".
user_invocable: true
---

# /sweep — triage the ideas inbox + the two shelves + the jam convergence door

`/sweep` is the operator-facing triage door **and the in-skill jam-convergence door** (ADR-087 D2.5;
ADR-112 Wave 3). **On-demand only — no nagging.**
It walks `docs/step-1-ideas/` + `docs/step-1-ideas/backlog/` + `docs/step-1-ideas/parked/` + `docs/step-1-ideas/chores/` (ADR-089 D4; ADR-090), renders ONE table,
takes the operator's inline verdicts, performs file moves, and **converges clusters IN-SKILL** — it
clusters, composes, prunes a fork-resolving thesis, writes the machine-readable vitality line, and performs
targeted moves itself, rather than handing off to a separate `/idea-jam`/`/bulk-jam` door.

> **Two altitudes, one door.** `/sweep` is (1) the **triage router** over the whole inbox + shelves + chore
> lane (verdict assignment + file moves) AND (2) the **in-skill convergence door** that reconverges a jam
> cluster (cluster → compose → thesis → examine → vitality). The triage walk still covers everything; the new
> **convergence** behavior defaults its scope to `docs/step-1-ideas/ready-to-build/` (§ Jam convergence below).
> `/sweep` is no longer router-only — it owns the in-skill convergence the retired `/idea-jam`/`/bulk-jam`
> doors used to (ADR-112 Wave 3, PEC-T8/T9). It keeps the on-demand-only / no-nagging discipline and the
> move-only-staging discipline (no `git push`, no commit) unchanged.

**Pre-migration tolerant:** if `docs/step-1-ideas/` is absent, fall back to `docs/deferrals/OPEN-*`.
If `docs/step-1-ideas/backlog/` or `docs/step-1-ideas/parked/` is absent, that shelf's section is empty.

## The engine: `/sweep` on the Workflow engine — `sweep.js` (SHR3-T7, ADR-039)

`/sweep`'s deterministic mechanics live on the **Workflow engine** as
`core/scripts/workflows/sweep.js` (the `nimble.js`/`orchestrated.js` mold, visible in `/workflows`). **This
SKILL is the door over `sweep.js`** — the script owns the deterministic floor; the skill renders the table,
takes the operator's verdicts, and executes the move/commit intents the engine returns.

**Three-step flow, exactly ONE LLM seam (F9 floor/ceiling split — ADR-126):**

1. **cluster — DETERMINISTIC, zero LLM.** The coarse cluster floor is `sweep-cluster.py cluster`'s
   `decision` (the Wave C F9 script). The engine carries that floor; it does NOT re-derive the partition by
   judgment. No `agent(` in this step.
2. **converge — the SOLE LLM seam.** One agent converges each cluster into a single fork-resolving thesis —
   the irreducible ceiling (ADR-126 D-3). This is the ONLY `agent(`/LLM call in `sweep.js`.
3. **vitality + moves — DETERMINISTIC, zero LLM.** The vitality line + every move/commit **intent** are
   computed by pure functions over structured inputs. No `agent(` in this step.

**Contract-2 boundary (the trap — ADR-039).** Workflow scripts have **NO FS/git access**, so `sweep.js`
**cannot itself run `git mv` / `git add` / `git commit`.** It expresses every move and the self-commit as a
**returned intent** (`payload.moveIntents[]`, `payload.commitIntent`) the **orchestrator (or a deterministic
helper invoked OUTSIDE the Workflow sandbox) executes**. The engine decides *what* moves; the orchestrator
performs the `git` op. Be crisp about which side of the boundary each `git` operation lives on.

**Location-is-status DROP (AC-020).** A dropped item is a `git mv` into the visible
`docs/step-1-ideas/dropped/` folder — it is **moved, never deleted**. An **open decision PROMOTES rather
than drops**. The drop path uses `git mv` exclusively (no delete op).

**Scoped self-commit (AC-021 — the security boundary).** `sweep.js`'s `commitIntent` is **local-only**,
stages **ONLY the explicit paths the moves touched** (an enumerated `addPaths` list the orchestrator runs as
`git add <paths…>` — **never `-A`** of unrelated working-tree state), produces a **local commit**, and issues
**NO remote push / no main write.** This is the boundary security-auditor scrutinizes.

**Non-capture-doc routing (AC-022).** A **deterministic router** (`routeNonCapture()`, no LLM) moves
non-capture docs (findings, READMEs) **OUT of the ideas inbox** to their correct home, decided purely by file
class/location — so findings/READMEs no longer pollute `docs/step-1-ideas/`.

**Seat Q3 disposition (AC-023).** Wave D builds **only** the deterministic taxonomy pieces
(DROP-to-`dropped/`, non-capture routing). The **broader shelf/bucket unification** (parked vs
`step-1-ideas/parked` vs backlog; `step-6-done` content silos) is **OUT-of-scope** for this wave — it is a
recorded disposition, not an omission (wave findings).

## On invocation

### 1. Walk + render ONE table

Collect from the inbox (`docs/step-1-ideas/`, fallback `docs/deferrals/`), the backlog shelf
(`docs/step-1-ideas/backlog/`), the parked shelf (`docs/step-1-ideas/parked/`), and the chore lane (`docs/step-1-ideas/chores/`, absent-tolerant —
ADR-090; walking it gives queue-depth visibility and catches mis-filed items: a chore that turns out to
need a design choice gets bounced via any non-chore verdict, e.g. `keep`-to-inbox or `ingest-to-jam`).
For each item compute:

- **item** — filename.
- **age** — days since git-added (fallback mtime). `git log --diff-filter=A --format=%at -1 -- <f>`.
- **stage memory** — the prefix: `DEFER-` (a deferral, carries a source-run pointer) / `FOLLOWUP-`
  (a delta stub against a locked spec) / a shelf `<stage-prefix>-` (where it came from) / plain
  (a proactive idea).
- **gist** — first markdown heading or first non-blank line.
- **recommended verdict** — your best read (see the verdict set).

Render exactly one table, oldest first:

```
| Item | Age | Stage memory | Gist | Recommended |
|------|----:|--------------|------|-------------|
```

### 2. The verdict set (operator answers inline)

Verdicts: **promote / shape / backlog / park / chore / drop / keep / ingest-to-jam / delta-pool-for-spec / new-cluster**
(ADR-089 D4; `chore` added by ADR-090; `shape` added by ADR-112 Wave 3).

| Verdict | What the skill does |
|---|---|
| **promote** | `git mv` the item into `docs/step-2-planning/` (clustering) or `docs/step-3-specs/` (a roadmap/wave) per the operator's target. |
| **shape** | promote a `docs/step-1-ideas/needs-shaping/` capture to `docs/step-1-ideas/ready-to-build/` — `git mv` into `ready-to-build/` once the item carries enough substance to be built against (the G3 thinness gate is the promotion gate: a one-line stub stays in `needs-shaping/`). This is the **shaping step** (ADR-112 Wave 3, AC-020) that keeps captures from stalling at `needs-shaping/` — it is coupled to the convergence-scope narrowing (§ Jam convergence): a capture must reach `ready-to-build/` before the default-scoped convergence sees it. |
| **chore** | `git mv` into `docs/step-1-ideas/chores/` — the no-planning lane for execution-ripe small items (ADR-090). Qualifier: **no-decision work only** — needs a design choice → not a chore (inbox/jam instead). Executed later in batch via the operator's "run the chores" (sequential solo/nimble units, batch-isolation discipline, one gate pass at the end; done items → `docs/step-6-done/chores/<date>/`). |
| **backlog** | `git mv` into `docs/step-1-ideas/backlog/<stage-prefix>-<file>` — the "we're doing this, just not now" shelf (operator-authorized by the inline answer; ADR-089 D2). |
| **park** | `git mv` into `docs/step-1-ideas/parked/<stage-prefix>-<file>` — the "shelved, maybe never" shelf (operator-authorized by the inline answer; parked is operator-only). |
| **drop** | **location-is-status DROP (ADR-087, AC-020):** `git mv` the item into a **visible `docs/step-1-ideas/dropped/` folder** — it is moved, NEVER deleted. The `dropped/` folder is the visible status marker; git history is still the archive. An **open decision PROMOTES, it does NOT drop** (`git mv` into `needs-shaping/`) — a live decision is never silently erased. (This is the `sweep.js` engine's `drop`/`promote` move intent; the engine returns it, the skill/orchestrator executes the `git mv`. The drop path uses `git mv` exclusively — no delete op.) |
| **keep** | leave in place — still inbox. |
| **ingest-to-jam** | maps to a converging jam in step-2 → `git mv` into `docs/step-2-planning/jam-<cluster>/`; **`/sweep` reconverges the jam IN-SKILL** (cluster → compose → thesis → examine → vitality line — § Jam convergence below; no external door). |
| **delta-pool-for-spec** | maps to a LOCKED spec in step-3 → `git mv` into `docs/step-3-specs/<slug>/deltas/` AND auto-mint/update `docs/step-1-ideas/FOLLOWUP-<spec-slug>.md` (delta count + one-line gist). The follow-up is now an inbox item — structurally unforgettable. |
| **new-cluster** | a fresh grouping → **`/sweep` opens the jam workspace and converges it IN-SKILL** (§ Jam convergence below); `git mv` the member ideas into `docs/step-2-planning/jam-<cluster>/` as they're claimed. **Emit at COARSE grain (~4–6 broad buckets) — see § Coarse planner grain below.** |

A delta that **CONTRADICTS** an unbuilt spec is NOT auto-pooled — surface it: proceed-and-follow-up
vs. an operator-only pull-back (`git mv` the spec back to step-2). The operator decides (ADR-087 D6).

**Every proposed verdict passes the § 2d W11 quality gates before § 3 acts on it** — G1
(never re-fork a live jam), G2 (a drop must not lose a unique captured idea), G3 (don't graduate a thin
stub), G4 (consolidate related items). A gate may **block or modify** a verdict (e.g. a `new-cluster` whose
topic already has a live jam is rewritten to `ingest-to-jam`); § 2c then sizes any surviving `new-cluster`
buckets. Validity (gates) and grain (§ 2c) are orthogonal — neither overrides the other.

### 2b. Shelf-aware reconciliation — the no-go dampener (ADR-089 D3)

**The shelf/jam match + the inbox-dedup check are DETERMINISTIC floor scripts (F9, ADR-126), not LLM
inference.** Two F9 decision scripts back this section — the skill **acts on their verdict as the floor**, it
does NOT re-derive the match by judgment alongside them (the F9 wire-to-consumer contract, ADR-126 D-2):

- **`core/scripts/shelf-match.py`** — does an inbox item structurally reconcile with an existing shelf item
  (route-to-pool, § 2b) or a live jam (route-to-jam, Gate G1)? Reads the LIVE shelves + jams
  (folder-as-truth); prints `{decision: route-to-pool|route-to-jam|abstain, reason, confidence, target,
  shelf}` with **zero LLM in its body**. A `route-to-*` (exit 3) IS the dampener firing; an `abstain` hands
  the shelf verdict to the operator/LLM (no-guess, ADR-126 D-3).
- **`core/scripts/idea-dedup.py`** — is an incoming idea a duplicate of an existing inbox item? Reads the
  LIVE inbox; prints `{decision: duplicate|unique|abstain, reason, confidence}` with **zero LLM in its
  body**. `abstain` is the no-guess band — the LLM ceiling (G2/G4) takes those.

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
# shelf/jam reconciliation floor — the skill ACTS ON .decision (route-to-pool|route-to-jam|abstain):
python3 "$S/shelf-match.py" match --item "<file>" \
  --backlog docs/step-1-ideas/backlog --parked docs/step-1-ideas/parked --jams docs/step-2-planning
# inbox-dedup floor — the skill ACTS ON .decision (duplicate|unique|abstain):
python3 "$S/idea-dedup.py" check --inbox docs/step-1-ideas --slug "<file>" --exclude "<file>"
```

When `shelf-match.py` returns `route-to-pool` (its `decision`), the skill performs the pool route below
**because the script said so** — it does not independently re-judge the match. An `abstain` means the floor
found no deterministic match and the operator's inline verdict decides. When `idea-dedup.py` returns
`duplicate`, the item is a confirmed dupe (route per G2/G4); an `abstain` defers to the LLM ceiling.

**BEFORE recommending `new-cluster` for any inbox idea, check it against the two shelves** (this is
`shelf-match.py`'s `route-to-pool` verdict). Match each
inbox item against `docs/step-1-ideas/backlog/` and `docs/step-1-ideas/parked/` items on topic/slug/content (the same fuzzy
matching the jams use). On a match, the item does NOT get a new cluster — it routes TO the shelf item as
an **accumulating pool**:

- Slugify `<topic>` to `[a-z0-9-]` (the /idea slugification; single path segment under `docs/<shelf>/` only),
  then append one bullet to `docs/<shelf>/<topic>-pool.md` (create it beside the shelf item if absent):
  `- <YYYY-MM-DD>: <one-line gist>  (from <source-filename>)`.
- Then **`git rm` the original inbox idea file** (the pool now carries it — the append-to-pool then
  `git rm` the source mechanism is the same one `/sweep`'s in-skill convergence uses for jam moves).
- Render the routing as its own table line riding the standard one-go-per-line confirmation:
  `N ideas → parked: <topic> (no new cluster)` or `N ideas → backlog: <topic> (no new cluster)`.

When the operator unshelves the item, the `<topic>-pool.md` travels with it (move-back includes the pool).

### 2c. Coarse planner grain for new-cluster verdicts (W9 — ADR-110)

**The coarse clustering floor is the DETERMINISTIC `sweep-cluster.py cluster` script (F9, ADR-126).** The
skill **acts on the script's `decision` (the coarse token-similarity groups) as the floor** for which inbox
items look like distinct clusters — it does NOT re-derive the coarse partition by LLM inference:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
# coarse clustering floor — the skill ACTS ON .decision (the >=2-member groups; singletons abstained):
python3 "$S/sweep-cluster.py" cluster --inbox docs/step-1-ideas
```

The script's `decision` is the coarse grouping the skill acts on; per the no-guess contract (ADR-126 D-3)
the script **abstains on fine member/boundary lines** — singletons and borderline edges stay their own group,
and the **fine partition is drawn later in the in-skill convergence pass by the LLM** (§ Jam convergence,
step 1), exactly as the boundary text below mandates. Floor (coarse, script) vs ceiling (fine, LLM) is the
F9 split.

**`new-cluster` verdicts emit at a COARSE grain — roughly 4–6 broad buckets.** At the **router altitude**
`/sweep` proposes broad topical groupings; it does NOT draw fine member/boundary lines ("cluster A contains
exactly items 1,4,7, excludes item 9 because…") at triage time — **that fine member/boundary convergence is
the in-skill convergence pass's job** (§ Jam convergence below), made with the jam's convergence machinery
once the cluster is opened.

Drawing fine boundaries at router time *leaks* un-litigated forks into the build (the jam-convergence
contract: an unresolved fork is an unfinished jam, not a build-time decision). So the triage altitude stays
coarse: "these ~5 broad areas look like distinct clusters," never the per-member partition — the per-member
partition is drawn inside the convergence pass. The ~4–6 band is a coarse-grain heuristic on the
leakage-vs-overhead tradeoff (ADR-110), independent of any single sweep's item count — NOT a tuned magic
number.

This rule co-exists with the § W11 quality gates below without contradiction: the gates check verdict
*validity* (don't re-fork a live jam, don't lose dropped ideas, don't graduate thin stubs, consolidate
related items); this rule sets verdict *grain*. A gate may block/modify a `new-cluster` verdict; the
grain rule sizes the buckets it emits.

### 2d. W11 quality gates — verdict-validity checks (run BEFORE the moves)

Four named gates run over the proposed verdict set **before § 3 performs any move**. They check verdict
**validity** (is this verdict coherent / safe?) and may **block or modify** a verdict — they are reached on
the real `/sweep` run path, not standalone prose.

**The structural gates (G1 jam-refork, G3 thinness) have a DETERMINISTIC floor: `sweep-cluster.py gate`
(F9, ADR-126).** The skill **acts on the script's `decision` as the floor** for those two — it does NOT
re-derive the gate verdict by LLM judgment alongside the script:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
# per proposed verdict, the W11 structural-gate floor — the skill ACTS ON .decision (OK|MODIFIED|BLOCKED|abstain):
python3 "$S/sweep-cluster.py" gate --verdict "<verdict>" --item "<file>" --jams docs/step-2-planning
```

`sweep-cluster.py gate` deterministically fires **G1** (a `new-cluster` whose topic matches a live jam →
`MODIFIED` to `ingest-to-jam`, exit 3) and **G3** (a graduating verdict on a structurally-thin stub →
`BLOCKED` to `keep`, exit 3) from folder-as-truth + content presence. It returns **`abstain` for G2
(drop-preservation) and G4 (consolidate-related)** — those are content-NUANCE judgments the LLM ceiling
owns (no-guess, ADR-126 D-3). So the skill takes the script's `MODIFIED`/`BLOCKED`/`OK` as the floor for
G1/G3 and applies its own LLM judgment ONLY on the abstained G2/G4 cases — the F9 floor+ceiling split. They are **orthogonal to § 2c**: § 2c sizes the buckets a
`new-cluster` verdict emits (grain); these gates decide whether a verdict is *valid* at all. Both survive in
the final file without contradiction (the § 2c L92-95 boundary text reserves exactly this slot). Gate
outcomes use **plain-text labels** — `BLOCKED`, `MODIFIED`, `OK` — no color-only or symbol-only signaling.
The gates introduce **no new write primitive**: they operate within § 3's existing `git mv` / `git rm` move
mechanics (no `git push`, no inbox-mutation, no commit) — a gate either lets a move proceed, rewrites it to a
different verdict, or holds it.

- **Gate G1 — cluster-routing-recognizes-existing-jam (never re-fork a live jam).** Before emitting any
  `new-cluster` fork-verdict, check the proposed cluster topic against **live jams** at
  `docs/step-2-planning/jam-*/` (fuzzy topic/slug match — the same matching § 2b uses against the shelves).
  On a match, the verdict is **MODIFIED**: it does NOT fork a new cluster — it routes the items to the
  existing jam as an `ingest-to-jam` verdict (`git mv` into `docs/step-2-planning/jam-<cluster>/`, then
  `/sweep` reconverges the jam in-skill — § Jam convergence). A `new-cluster` verdict whose topic already
  has a live jam is `BLOCKED` from forking. This is the validity sibling of § 2b's shelf reconciliation —
  § 2b dampens against the two shelves, G1 dampens against live jams.
  - **G1's job is exactly this — jam-refork dampening, nothing wider (ADR-117 D5).** G1 does NOT gate
    deferral shelving. A **phase-2-deferred** item shelves *because it is deferred* — a later-phase scope
    call — **not** because G1 fired. Never cite G1 as the reason a phase-2-deferred item was shelved; G1
    only rewrites a `new-cluster` whose topic already has a live jam. (A phase-2-deferred item linked to a
    jam has a durable home — see the *later-phase scope of jam X* lane in § Jam convergence.)
- **Gate G2 — drop-preservation (a drop must not lose captured ideas).** Before a `drop` verdict's
  location-is-status move, confirm the item's substance is preserved where it belongs: a drop is valid only
  when the idea is genuinely a duplicate/superseded (its content already lives in a pool, a jam, a spec, or
  another inbox item) OR is genuinely empty. If a `drop` would strand a unique captured idea with nowhere
  else holding it, the gate is **BLOCKED** → the verdict is **MODIFIED** to `keep` (or
  `ingest-to-jam`/`backlog`/`park`) so the capture is not lost. Even a passing `drop` does NOT delete the
  file: it `git mv`s it into the visible `dropped/` folder (location-is-status — AC-020), so a unique idea is
  never silently erased out of the conveyor. Only `drop`s that pass G2 reach § 3's `git mv`-to-`dropped/`.
- **Gate G3 — thinness-gate (don't graduate thin stubs).** Before a `promote` / `delta-pool-for-spec` /
  `ingest-to-jam` verdict graduates an item out of the inbox toward planning/spec, confirm it carries
  enough substance to be graduated — a stub that is only a one-line title with no value/notes/body is a
  **thin stub** and is **BLOCKED** from graduation. The verdict is **MODIFIED** to `keep` (stay in the
  inbox to be shaped) until it has real content. Thinness is judged on content presence (the `/idea` README
  fields filled, a real body) — not on length pedantry.
- **Gate G4 — consolidate-related-items.** Before finalizing the verdict set, detect inbox items that are
  near-duplicates / strongly related (fuzzy topic/slug/content match across the rendered table). Rather than
  scattering related work across separate `new-cluster`/`promote` verdicts, the gate **MODIFIES** them to a
  single consolidated route — fold the related items into one target (one pool via the § 2b append-then-`git
  rm` mechanism, or one `ingest-to-jam` into the same jam, or one `new-cluster` bucket). This keeps triage
  coherent and feeds § 2c's coarse-grain bucketing rather than fighting it.

**Gate ordering + co-existence.** Run G1→G4 over the proposed verdicts, then § 2c sizes any surviving
`new-cluster` buckets at coarse grain. A verdict that a gate `BLOCKED`/`MODIFIED` carries its new disposition
into § 3; § 2c never re-litigates a gate decision and a gate never draws fine cluster boundaries (that stays
§ 2c / the § Jam convergence pass). Surface a parseable summary line:
`GATES: G1 jam-refork <n>, G2 drop-preservation <n>, G3 thin-stub <n>, G4 consolidate <n> — verdicts modified/blocked before moves`.

### 3. Perform the moves

**Run the § 2d W11 gates first** (G1–G4 over the proposed verdict set), carrying each gate's
`BLOCKED`/`MODIFIED` disposition into the moves below. Then perform the moves — a **`drop` is a `git mv`
into the visible `docs/step-1-ideas/dropped/` folder** (location-is-status, AC-020 — never a delete), an
**open decision is a `git mv`-promote** (never a drop), a **non-capture doc routes OUT of the inbox** via the
deterministic router (AC-022), and the § 2b pool-dedup route is unchanged. These are exactly the
`sweep.js` engine's returned move intents. Never edit unrelated content, and introduce no new write primitive
beyond these existing move mechanics. Stage the moves; do NOT commit yet (or use the engine's scoped,
local-only, explicit-paths self-commit — AC-021 — never `-A`, never a remote push).

### 4. Sweep CHAINS — render the execution queue (one operator go per line)

Any verdict implying CONTENT work ends the run with an execution queue. Convergence work
(`ingest-to-jam`/`new-cluster`) runs **in-skill** via § Jam convergence — NOT a hand-off to a retired
`/idea-jam`/`/bulk-jam` door. Render exactly like:

> J3 took 23 ideas → reconverge IN-SKILL: jam-flow-telemetry (go?) · 4 new clusters → converge IN-SKILL (go?) ·
> 3 ideas → parked: electron-app (no new cluster) (go?) ·
> 2 captures → shaped: ready-to-build (go?) ·
> FOLLOWUP-flow-telemetry ripe → plan via `/roadmap` (go?)

One operator go per line. For an `ingest-to-jam`/`new-cluster` line, the go runs `/sweep`'s **own** § Jam
convergence pass (cluster → compose → thesis → examine → vitality) on that jam — `/sweep` no longer reimplements or
routes to a separate convergence door. A `/roadmap` line still routes to `/roadmap` (planning is a separate
door). cluster → converge → merge-to-plan is one continuous flow inside `/sweep` up to the `/roadmap` handoff.

## Jam convergence — the in-skill convergence door (ADR-112 Wave 3; re-homed from rules-advisory-modes.md)

This is the contract `/sweep` absorbed from the retired `/idea-jam`/`/bulk-jam`/`/planner jam` doors (PEC-T8/T9).
It is reached by the **live verdict flow**: an `ingest-to-jam` or `new-cluster` verdict (§ 2 / § 4) runs THIS
pass on the affected jam — there is no external door to hand off to.

**Default convergence scope: `docs/step-1-ideas/ready-to-build/`.** Convergence operates over captures that
have reached `ready-to-build/` (promoted there by the `shape` verdict). This is **distinct from the triage
walk** (§ 1), which still covers the *whole* inbox + both shelves + the chore lane — do NOT narrow the walk.
Only the convergence behavior defaults its scope to `ready-to-build/`; an explicit operator scope overrides it.
The default is the floor, **not a mandate** — the operator MAY point convergence at a wider scope, but
convergence MUST NOT *silently collapse the shape hop* by reaching into `needs-shaping/` items unprompted.

#### Readiness check — recommend-and-override (ADR-117 D1)

Before the in-skill pass runs, apply a **lightweight readiness check** over the items the convergence scope
would pull in. When that scope would include items still in `docs/step-1-ideas/needs-shaping/` — **or** items
that lack a Shaped section (judge shaped-ness on *content presence*, mirroring the G3 thinness heuristic at
§ 2d, NOT length pedantry) — surface a plain-text **recommendation with an explicit override**:

> these look unshaped — recommend running them through shaping first (`/shape <folder>`). Override to converge
> them as-is? (y/N)

- This is **recommend-and-override, not a gate.** The operator can always proceed anyway — overriding
  preserves the L19/default behavior (convergence runs on the requested scope). The check only prevents the
  *silent* collapse; it never blocks.
- The `/shape <folder>` pointer is a **one-line reference to the `/shape` door** (the attended shaping
  interview, `core/skills/shape/SKILL.md`) — a documented cross-wave reference STRING only. `/sweep`
  implements **NO** shaping interview loop (no seed → summary → question → riff → fold logic lands here —
  that is `/shape`'s job). `/sweep` only recommends the door and lets the operator override.
- **Readiness check ≠ G3.** G3 (§ 2d) is a verdict-validity gate over the triage table (blocks graduating
  thin stubs out of the inbox). This readiness check is a *convergence-scope* recommendation about
  shaped-ness — orthogonal; it reuses the shaped-ness heuristic but does not fold into G3.

### The convergence contract (binding — re-homed from rules-advisory-modes.md "Jam convergence contract")

A jam **converges by pruning into a single thesis doc that RESOLVES its forks** — every tree-vs-graph-class
decision the cluster carried is decided once, upstream, and written down. The thesis is the durable artifact;
the build inherits it and MUST NOT re-litigate a fork the jam already resolved. **An unresolved fork is an
unfinished jam, not a build-time decision.** Every ingest/reconvergence pass MUST update the jam README's
machine-readable plan-vitality line (below) that `docs-index.py` renders (ADR-089 D5).

### The in-skill pass (cluster → compose → thesis → examine → vitality → targeted move)

For the jam at `docs/step-2-planning/jam-<cluster>/` (open it if `new-cluster`; reopen + read the whole
workspace if `ingest-to-jam`):

1. **Cluster (fine member/boundary).** Draw the per-member partition the coarse router altitude (§ 2c)
   deliberately did not — which `ready-to-build/` items belong to this jam, made with the jam's convergence
   machinery, not at triage time.
2. **Compose (ground from the repo).** For each member, ground its claims by reading the repo — turn
   "I think X works like Y" into "verified in `path:line`", or flag `[verify]`. Grounding from memory is
   worse than no grounding (the documented feasibility-error source, ADR-030 intake discipline).
3. **Targeted move.** `git mv docs/step-1-ideas/ready-to-build/<slug>.md docs/step-2-planning/jam-<cluster>/source/<slug>.md`
   — the `git mv` preserves history; `source/` is created **lazily on first write** (do NOT pre-`mkdir`
   `source/`/`findings/`). NEVER a plain `cp` (that duplicates and leaves the inbox copy — the
   inbox-shrinkage signal IS the move). **Never fork `jam-<cluster>-2`** — upsert the one folder forever.
   - **Post-move inbox-shrink assertion (ADR-117 D2 — binding).** The shrinkage signal is a *check*, not just
     prose: after the `git mv`, ASSERT the inbox actually shrank — the source path no longer exists AND the
     `ready-to-build/` file count dropped by the number moved. Stage-only (no commit/push):
     ```bash
     # before the moves: COUNT_BEFORE=$(find docs/step-1-ideas/ready-to-build -maxdepth 1 -name '*.md' | wc -l)
     # for each moved <slug>:
     test ! -e "docs/step-1-ideas/ready-to-build/<slug>.md" || { echo "ABORT: source still present — move did not take" >&2; exit 1; }
     # after the moves:
     COUNT_AFTER=$(find docs/step-1-ideas/ready-to-build -maxdepth 1 -name '*.md' | wc -l)
     [ "$COUNT_AFTER" -lt "$COUNT_BEFORE" ] || { echo "ABORT: inbox did not shrink — no move signal" >&2; exit 1; }
     ```
     A move that leaves the inbox the same size did NOT happen (a `cp` slipped in, or the path was wrong) —
     halt rather than reconverge against a phantom move.
4. **Thesis.** Write/update the jam `README.md` (fallback `index.md`): the converged gist, how each member
   fits, and the forks RESOLVED (not just listed). A reconvergence pass prunes dead branches and folds good
   threads together in place.
4b. **Examine fold-in (ADR-112 Wave 5 follow-on — the third leg of the engine examine passes).** On **every**
   convergence pass, dispatch **ONE** examiner (the Fable seat — reuse the ADR-088/095/099 dispatch + ledger
   rules, do NOT re-author) over BOTH (a) the converged **thesis** (is it sound? does it actually RESOLVE its
   forks, or just list them?) AND (b) the **cluster/move correctness** (did the right `ready-to-build/` items
   land in this jam? are the member/boundary lines right? anything mis-clustered or orphaned?). The brief
   assembles the thesis + the list of `source/*` members moved this pass + the resolved/open forks; read
   budget ~15 tool calls.
   - **FOLD-IN ONLY — no halt, no new verdict class (matches the W5 engine contract).** Fold the examiner's
     `FOLD-IN-REQUIRED` findings back into the thesis (step 4) before computing the vitality line; a severe
     `RETHINK` verdict is **recorded** (a `## Examiner` note in the thesis + surfaced in the sweep run summary)
     and folded best-effort — it never blocks the sweep. `/sweep`'s move-only-staging discipline is unchanged.
   - **Finding placement — folds into the jam, NEVER the flat inbox root (ADR-117 D3 — binding).** Every
     examiner finding folds into **the jam it evaluated** — the jam-local `docs/step-2-planning/jam-<cluster>/findings/`
     (created lazily on first write) or a `## Deferred` / `## Examiner` note in that jam's thesis. An examiner
     finding MUST NOT be written to the flat `docs/step-1-ideas/` root (nor any inbox bucket) — that would
     violate the ADR-111 bucket taxonomy (the inbox is for *captures*, not jam-evaluation findings). This
     constrains only the finding *placement*; the ledger snippet below is reused VERBATIM and is not re-authored.
   - **LEDGER (ADR-088 D4 — binding).** `/sweep` runs orchestrator-direct (not a no-FS engine), so it appends
     the ledger line **itself** at the dispatch site: read `in_tokens`/`out_tokens`/`cache_*` from the examiner
     dispatch's usage block and O_APPEND ONE line to `docs/step-3-specs/_fable-spend.jsonl` using the
     `/examine` snippet **VERBATIM** (`core/skills/examine/SKILL.md` §d — do NOT re-author the JSON; `TARGET` =
     `jam-<cluster>`, `VERDICT` = the examiner verdict). One line per convergence pass; `over_envelope` per the
     2× rule. (No new halt class anywhere — fold-in is the whole contract.)
5. **Vitality line (ADR-089 D5).** Insert (if absent, at the top after the title) or increment in place the
   single machine-readable header line, in the EXACT format `docs-index.py` renders:

   ```
   <!-- vitality: absorbed=N passes=N last=YYYY-MM-DD pending=N -->
   ```

   - `absorbed` = ideas pulled into the jam to date (**+= the count folded in this pass**).
   - `passes` = reconvergence pass count (**+= 1** this pass).
   - `last` = today — `date +%F` via Bash, **never hardcode**.
   - `pending` = ideas tagged this jam's slug but not yet absorbed (forks/members still open).

   An absent line renders "—" on the dashboard (tolerant).

### The "later-phase scope of jam X" lane (ADR-117 D5 — durable phase-2 home)

A **phase-2-deferred item linked to a jam** needs a durable resting place that does NOT depend on someone
manually cross-linking it in the thesis during a coincident reconverge (fragile — the link is lost if no
reconverge happens to run). Give it a first-class lane:

- When an item is deferred to a *later phase* of an in-flight jam (e.g. "this belongs to jam-X but is phase-2
  scope, not now"), record it as a **`## Later-phase scope` entry in jam X's thesis** (`README.md`, fallback
  `index.md`) — one bullet: `- <YYYY-MM-DD>: <gist>  (phase-2 scope of jam-<X>; from <source-filename>)`.
- This entry is durable on its own: it lives in the jam workspace regardless of whether a reconvergence pass
  runs, and `pending` in the vitality line counts it (a tagged-but-not-yet-absorbed member). When jam X's
  later phase opens, the lane entry is the ready-made member list — no thesis archaeology required.
- This is **additive** — the existing `ingest-to-jam` path (§ 2 verdict / the in-skill pass) is UNCHANGED.
  The lane is a new durable home for deferred-linked-to-jam items, not a change to how active ingest works.
- Stage-only: recording the lane entry is a thesis Edit/Write (the existing convergence write primitive) —
  no new move primitive, no commit, no push.

### Load-bearing invariants (do NOT violate)

- **The `jam-` prefix is load-bearing** (~260 refs / 40 files: `docs-index.py`, `roadmap.js` `jamPath`,
  `roadmap-source-coverage.py` the ADR-103 IN-bookend, `closeout-jam.py`, `graduate-jam.py`, the test suite).
  Every workspace `/sweep` creates MUST be `docs/step-2-planning/jam-<slug>/` — a prefix-LESS cluster
  (`docs/step-2-planning/<slug>/`) silently passes the ADR-103 IN gate (a correctness hole). Never introduce
  a prefix-less cluster path.
- **jamSlug kebab-validation.** Slugify `<cluster>` to `[a-z0-9-]` (the `/idea` slugification § 2b uses) —
  a single path segment under `docs/step-2-planning/jam-`. NEVER accept raw operator input as a directory
  component; reject any `<cluster>` that does not resolve to one segment (a `../`-style slug must not escape
  the planning tree — the `roadmap.js` ~L60-66 / SA-002 precedent).
- **Move-only-staging (unchanged).** Convergence uses `git mv`/`git rm` + the README Edit/Write only; no
  `git push`, no commit (the operator commits in § 5).
- **Upsert, never fork.** One jam folder per cluster slug, forever; reopen-and-append, never `jam-<slug>-2`.

### Jam end-of-life — `ARCHIVED-` filename prefix (graduation convention)

When a jam is **graduated** (its threads routed to `/roadmap` or a build, and you don't want it surfacing on
the next sweep), mark the workspace with the `ARCHIVED-` filename prefix — the jam folder STAYS put (git
history + `source/*` links survive) while the filename declares it graduated:

```bash
git mv docs/step-2-planning/jam-<slug>/README.md docs/step-2-planning/jam-<slug>/ARCHIVED-README.md
# list every archived jam:  find docs/step-2-planning -maxdepth 2 -name 'ARCHIVED-*'
```

This is a localized status-by-filename marker for the jam-graduation case (ADR-049; moved here from
`/planner jam` by ADR-112 Wave 3). No sibling archive directory is introduced.

### 5. Regenerate the dashboard + commit guidance

After the moves, regenerate the dashboard. **Resolve the script path per ADR-031** — `.claude/scripts/`
FIRST (consumer-local override wins), else `core/scripts/` (dogfooding inside claude-infra). Apply this to
EVERY core-script shell-out:

```bash
# ADR-031 substrate path resolution: .claude/scripts in a consumer, core/scripts in claude-infra.
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
python3 "$S/docs-index.py"     # regenerate docs/INDEX.md
```

Then instruct ONE operator-visible commit, e.g.:

```bash
git add -A && git commit -m "chore(inbox): /sweep — <N> moves (promote/backlog/park/drop), INDEX regenerated"
```

The operator reviews `git status` and commits. `/sweep` stages and routes; it does not push.

## Notes

- **On-demand only** (operator-resolved 2026-06-12): `/sweep` never runs itself, never nags.
- **The shelves are operator authority:** a `backlog`/`park` verdict IS the operator's go to move a file
  into `docs/step-1-ideas/backlog/` / `docs/step-1-ideas/parked/`. Agents may PROPOSE shelving elsewhere, but only `/sweep`'s
  inline answer (or an explicit operator instruction) moves one in.
- **Convergence is in-skill (ADR-112 Wave 3).** `/sweep` owns the jam convergence the retired
  `/idea-jam`/`/bulk-jam`/`/planner jam` doors used to (PEC-T8/T9). The `ingest-to-jam`/`new-cluster` verdicts
  reach the § Jam convergence pass directly — there is no external convergence door to route to. The
  transcript-CAPTURE verb lives at the standalone **`/idea-ingest`** door (capture ≠ convergence; ADR-112
  resolved Open Q#2 — `/bulk-jam` is fully retired, split into `/sweep` + `/idea-ingest`).
- See `docs/decisions/ADR-087-doc-lifecycle-location-is-status.md` (D2.5, D6),
  `docs/decisions/ADR-089-ideas-backlog-two-shelf-model.md` (D2-D4),
  `docs/decisions/ADR-112-engine-topology-plan-detect-slice-once.md` (Wave 3 jam absorption), and
  `docs/step-1-ideas/README.md`.
