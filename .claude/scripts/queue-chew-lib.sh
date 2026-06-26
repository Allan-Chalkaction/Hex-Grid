# shellcheck shell=bash
# queue-chew-lib.sh — the SOURCEABLE deterministic mechanics of the /queue-chew daemon (ADR-124, queue v1.1).
#
# WHY THIS FILE EXISTS (the architecture spine — read first).
# The chew daemon (core/skills/queue-chew/SKILL.md) is a markdown SKILL that runs as a SESSION LOOP, NOT a
# Workflow script — because a no-FS Workflow script physically cannot poll docs/step-4-queue/pending/ for
# cross-session producer appends (the "no-FS → session-loop" rationale, queue-chew/SKILL.md L20-28). That
# rationale is PRESERVED: this lib is SOURCED by a session WITH FS access; it is not a Workflow script and
# does not violate the no-FS contract.
#
# What it extracts: the daemon's DETERMINISTIC mechanics (pick, input validation SA-001/002/003, the
# pending→running drain git mv, target resolution, the success/failure outcome branch + base advance, and
# the park-vs-halt arbiter). These were previously prose-only in the SKILL and therefore untestable; pulling
# them into a sourceable lib makes them EXECUTABLE + unit-testable (test-queue-chew-e2e.sh).
#
# THE REAL DISPATCH IS THE SESSION'S, BETWEEN TWO DETERMINISTIC HALVES (SHR3-T4 / ADR-124). v1.1 had a single
# `qc_run_one` that called `launch_workflow` INLINE — pretending a bash function could dispatch+await a real
# top-level Workflow. It cannot: that await is a SESSION-LEVEL mechanic. SHR3-T4 splits the iteration into
# `qc_next` (before-dispatch: pick / SA-001/002/003 / allowlist / drain / target / readiness — NO dispatch)
# and `qc_settle` (after-dispatch: outcome branch / move / arbiter — takes launch_rc + dirty as ARGS). The
# LLM (the chew SKILL session loop) drives the REAL top-level /orchestrated|/nimble|… Workflow + BLOCKS on its
# <task-notification> BETWEEN them. `launch_workflow` is DEMOTED OUT of the production path entirely — NO
# production drain function (qc_next / qc_settle) calls it; the ONLY surviving call site is a TEST-ONLY stub
# in test-queue-chew-e2e.sh (simulates a build: writes an output file, returns rc 0/N). The security boundary:
# no production drain can invoke an unisolated inline dispatch (pair with SHR3-T3's worktree isolation).
#
# ENTRY-AS-FOLDER (ADR-124). A queue entry is a FOLDER docs/step-4-queue/<stage>/<entry>/ containing the moved source
# artifact + sidecar.json {label, verb, seq, after?, planned_files?, target}. The build target is the
# in-queue artifact at <stage>/<entry>/<sidecar.target> (default target "." = the entry folder). The
# within-queue drain (pending→running→{done,failed} INSIDE docs/step-4-queue/) is PRESERVED — only the producer
# move-IN (artifact → pending/<entry>/) is new (ADR-124 EXTENDS ADR-123 D-3; the poll is preserved, entries
# never move OUT during the drain).
#
# PORTABILITY (ADR-124). `_canon` (os.path.realpath) replaces every `realpath -m` — os.path.realpath
# canonicalizes a MISSING path cross-platform (BSD macOS + GNU linux); GNU-only `realpath -m` is banned.
#
# Sourced, not executed. The caller (the SKILL session, or the test) sources this file, defines
# `launch_workflow`, sets QUEUE_DIR (default docs/step-4-queue), then drives the loop via the functions below.
#
# -----------------------------------------------------------------------------------------------------------
# SHELL-PORTABILITY AUDIT (SHR4-B1, AC-007). THE WHOLE LIB IS SOURCED INTO THE OPERATOR'S zsh SESSION, so every
# construct here runs under STOCK zsh, not bash CI's shell. The settled-archive word-split (AC-006) was the
# symptom; this is the disease audit. Each shell-divergent construct class was reviewed and made portable;
# SHR4-B3's dual-shell (bash+zsh) test matrix is the RUNTIME proof of this audit.
#
#   1. UNQUOTED `$var` in `for … in` (THE divergence — zsh's SH_WORD_SPLIT is OFF by default, so an unquoted
#      space-joined `$var` iterates as ONE token under zsh, not field-split as in bash). FOUND + FIXED at TWO
#      sites: `qc_archive_settled` `for label in $settled` (AC-006) AND `qc_arbiter_decide` `for d in $all_deps`
#      (AC-007). BOTH now NEWLINE-join the Python emit and iterate via `while IFS= read -r … done <<< "$var"`,
#      which splits on newlines IDENTICALLY under bash + zsh. No other `for … in $var` over a shell var remains
#      (the Python-side `for` loops in the heredocs are Python, not shell — out of scope).
#   2. `[[ … =~ … ]]` regex shape-checks (`:~`-class, SA-001/SA-003 guards). `[[` + `=~` are supported in zsh;
#      the EREs used here are simple anchored char-classes (`^[a-z0-9][a-z0-9-]*$`) that match identically
#      under bash + zsh `=~` (no backref / no PCRE / no `setopt RE_MATCH_PCRE`). PORTABLE — kept as-is.
#   3. ARITHMETIC `$(( … ))` (`moved=$((moved+1))`). POSIX arithmetic — identical under bash + zsh. PORTABLE.
#   4. `local` scoping. Supported in both (zsh function-local). PORTABLE.
#   5. ARRAYS — NONE used (no `${arr[0]}` / `${arr[@]}`), so the bash-0-indexed / zsh-1-indexed divergence is
#      not reachable. Lists are passed as newline-joined strings (#1), never shell arrays — by design.
#   6. PROCESS SUBSTITUTION `<(…)` — NONE. Here-strings `<<< "$var"` (#1) are used instead; `<<<` is supported
#      in both shells. `read` carries only `-r` (POSIX) — no bash-only flags.
#   7. `printf '%s'` / `printf '%d'` — POSIX format specifiers, identical under both.
# RESULT: no divergence-class construct remains. The dual-shell matrix (SHR4-B3) exercises the public surface
# (qc_next / qc_settle / qc_archive_settled / qc_queue_dir / …) under stock zsh to prove it at runtime.
# -----------------------------------------------------------------------------------------------------------

# _canon PATH — print the canonical absolute path, canonicalizing even a MISSING path component.
#   Replaces GNU-only `realpath -m`. os.path.realpath is the cross-platform (BSD+GNU) equivalent: it resolves
#   symlinks and normalizes `..` WITHOUT requiring the path to exist. Used EVERYWHERE the daemon needs a
#   canonical path for a containment check. NO `realpath -m` may remain anywhere in the queue surface.
_canon() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# qc_queue_dir — resolve the queue root once (default docs/step-4-queue; overridable via QUEUE_DIR for the test).
qc_queue_dir() { printf '%s' "${QUEUE_DIR:-docs/step-4-queue}"; }

# -----------------------------------------------------------------------------------------------------------
# WORKTREE ISOLATION SEAM (SHR3-T3 / ADR-046, binding — security-relevant).
# -----------------------------------------------------------------------------------------------------------
# qc_worktree_dir → print the WORKTREE ROOT the daemon's git operations run against. This is the isolation
#   seam: a background chew daemon MUST run its git ops (rev-parse HEAD / status --porcelain) inside a
#   DEDICATED worktree, NEVER the operator's interactive main repo root. An unisolated daemon that flips HEAD
#   in the operator's tree corrupts the operator's live session (ADR-046 isolation doctrine).
#     - In PRODUCTION the chew SKILL session establishes a dedicated worktree BEFORE any dispatch (via
#       `git worktree add`) and exports QC_WORKTREE pointing at it; the qc_* git operations target that path.
#     - In a NON-isolated/test context QC_WORKTREE is unset and this resolves to the current repo root, so the
#       deterministic mechanics are unit-testable in a plain temp repo (the test asserts the SEAM, not a real
#       second worktree).
#   The resolver is the single point of truth a test asserts against: the daemon's git ops target
#   `qc_worktree_dir`, NOT `$(git rev-parse --show-toplevel)` of the operator's tree.
qc_worktree_dir() {
  if [ -n "${QC_WORKTREE:-}" ]; then printf '%s' "$QC_WORKTREE"; return 0; fi
  git rev-parse --show-toplevel 2>/dev/null || printf '%s' "${PWD}"
}

# qc_git WORKTREE_ARGS…  → run a git command scoped to the daemon's worktree root (qc_worktree_dir). Every
#   daemon git op that could mutate or read HEAD MUST go through this seam so it targets the isolated
#   worktree, never the operator's interactive tree (SHR3-T3 / ADR-046). `git -C <dir>` is the scoping
#   primitive; `qc_worktree_dir` is the dir. Used for the post-dispatch HEAD/tree observation the session
#   hands to qc_settle.
qc_git() { git -C "$(qc_worktree_dir)" "$@"; }

# qc_worktree_dirty  → print the worktree's done-vs-failed DIRTINESS read with the load-bearing transient-path
#   exclusion (SHR4-B1, AC-008 — the LIB half; the LOAD-BEARING layer of the two-layer AC-008 fix). Empty
#   output = clean tree (the success precondition qc_apply_outcome / qc_arbiter_decide branch on); non-empty =
#   dirty (a failed/ outcome + possible HALT).
#
#   WHY THE EXCLUDE IS LOAD-BEARING (ADR-130 D-3). A clean, SUCCESSFUL build whose worktree dir carries only
#   TRANSIENT `.claude/` pollution (a `.claude/worktrees/` checkout, `.claude/agent-memory/` run state) would
#   otherwise read DIRTY and flip a green build to `failed/` — a false failure that strands an unattended
#   overnight drain. `git status --porcelain -- . ':(exclude).claude/'` scopes the read to real source change
#   and excludes the transient `.claude/` subtree. This LIB exclude fail-safes EVEN WHEN the consumer's
#   `.gitignore` is incomplete (the SHR4-B4 `setup.sh` `.gitignore` scaffold is the BELT; this is the
#   SUSPENDERS — both ship; the lib exclude does NOT rely on the scaffold).
#
#   PATHSPEC NOTE (binding): `:(exclude).claude/` is a git pathspec MAGIC PREFIX — it MUST follow the `-- .`
#   path separator EXACTLY (a `:(exclude)` without a preceding positive pathspec, or a malformed prefix,
#   silently matches NOTHING → the exclude no-ops → re-dirties everything). The `-- . ':(exclude).claude/'`
#   form (positive `.` + negative `.claude/`) is verified to resolve.
#
#   Routed through the `qc_worktree_dir` isolation seam (SHR3-T3 / ADR-046) — reads the daemon's WORKTREE, not
#   the operator's interactive tree. The SKILL's settle loop MAY route its `DIRTY=` read through this helper so
#   the load-bearing exclude lives in ONE sourceable place (the SKILL-side `DIRTY=` text itself is Wave A's).
qc_worktree_dirty() {
  git -C "$(qc_worktree_dir)" status --porcelain -- . ':(exclude).claude/' 2>/dev/null
}

# qc_scripts_dir — resolve the substrate scripts prefix (consumer-safe — ADR-031).
qc_scripts_dir() { local s=.claude/scripts; [ -d "$s" ] || s=core/scripts; printf '%s' "$s"; }

# -----------------------------------------------------------------------------------------------------------
# COMPLETION-READ CHOKEPOINT (ADR-128 D-3 / examiner F-001/F-003, binding — the load-bearing correctness piece).
# -----------------------------------------------------------------------------------------------------------
# qc_completed_labels  → print the set of SUCCESSFULLY-COMPLETED entry-folder basenames, ONE per line, as the
#   UNION of the queue's transient success terminal (docs/step-4-queue/done/) AND the canonical archive
#   (docs/step-6-done/queue/). This is the SINGLE MANDATORY SOURCE for EVERY "is this entry completed?"
#   question — the dependency gate (qc_pick_entry) AND the operator-legibility "what is done?" surface.
#
#   WHY A CHOKEPOINT (ADR-128 D-3). queue-archive.py moves a settled done/ entry to step-6-done/queue/ — so
#   after archival the "what completed?" truth is the UNION of two folders, not bare done/. If any future
#   completion read globbed bare done/ it would go SILENTLY WRONG for an archived entry: a late
#   `pending after:<archived>` would never resolve (an archived predecessor would look un-done, blocking the
#   dependent forever). Routing EVERY completion read through this one helper makes "two folders" invisible
#   to callers and is the backstop the no-bare-glob test (AC-11) asserts against. NO bare done/ completion
#   glob may remain for the gating + legibility readers — they all read this.
#
#   Folder-as-truth: re-derives from the live folders each call (no cached state — ADR-093 overnight-resume).
#   `.gitkeep` / non-directory entries are ignored (only entry FOLDER basenames are completion labels).
#   step-6-done/ is NOT under QUEUE_DIR (it is a canonical sibling tree); the archive path is resolved
#   relative to QUEUE_DIR's parent so a QUEUE_DIR override (the test's temp root) keeps both folders co-located.
qc_completed_labels() {
  local q archive_base; q="$(qc_queue_dir)"
  # The archive lives at <queue-parent>/step-6-done/queue/ (sibling of step-4-queue). Overridable for the
  # test via QC_ARCHIVE_DIR so a temp repo can co-locate the two folders without the canonical path.
  if [ -n "${QC_ARCHIVE_DIR:-}" ]; then
    archive_base="$QC_ARCHIVE_DIR"
  else
    archive_base="$(dirname "$q")/step-6-done/queue"
  fi
  # DUAL-READ (ADR-128 Amendment 1 / SHR4-C3 — LOAD-BEARING). The archive base now holds BOTH layouts: the
  # new DATE-PARTITIONED step-6-done/queue/<date>/<label> sub-dirs AND the legacy FLAT step-6-done/queue/<label>
  # entries the pre-amendment shipped code already produced. The completion set must union BOTH — globbing only
  # the dated path would silently turn every flat-archived label into a forward-reference miss (a late
  # `pending after:<flat-archived>` would never resolve). A child of the base that matches ^YYYY-MM-DD$ is a
  # date PARTITION (recurse one level for its entry labels); any other child dir is a legacy FLAT entry label.
  # done/ stays flat (its immediate subdirs are labels). This is the date-aware dual-read the C2 amendment binds.
  QC_COMPLETED_DONE="$q/done" QC_COMPLETED_ARCHIVE="$archive_base" python3 - <<'PYEOF'
import os, re, sys
seen = set()
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")   # an ISO YYYY-MM-DD partition dir (not a completion label).

done_dir = os.environ.get("QC_COMPLETED_DONE", "")
if done_dir and os.path.isdir(done_dir):
    for name in os.listdir(done_dir):
        if os.path.isdir(os.path.join(done_dir, name)):
            seen.add(name)                 # done/ is FLAT: immediate subdirs are labels (.gitkeep ignored).

archive_base = os.environ.get("QC_COMPLETED_ARCHIVE", "")
if archive_base and os.path.isdir(archive_base):
    for child in os.listdir(archive_base):
        child_path = os.path.join(archive_base, child)
        if not os.path.isdir(child_path):
            continue                       # .gitkeep / stray files are never completion labels.
        if DATE_RE.match(child):
            # DATE-PARTITIONED layout: recurse one level — each subdir is an archived entry label.
            for label in os.listdir(child_path):
                if os.path.isdir(os.path.join(child_path, label)):
                    seen.add(label)
        else:
            # LEGACY FLAT layout: this child dir IS an archived entry label (dual-read backstop).
            seen.add(child)
for name in sorted(seen):
    print(name)
PYEOF
}

# -----------------------------------------------------------------------------------------------------------
# PICK — earliest-seq dep-ready entry (the daemon's documented selection contract).
# -----------------------------------------------------------------------------------------------------------
# qc_pick_entry  → prints the entry DIR basename of the next dep-ready pending entry (earliest seq whose
#   every `after` dep is already COMPLETED), or "" if none is dep-ready. Re-derives from the FOLDER each call
#   (no in-memory state — ADR-093 overnight-resume; matches test-queue-chew.sh pick_next, extended to the
#   entry-as-FOLDER shape: iterate pending/*/sidecar.json, not pending/*.json).
#   COMPLETION is the UNION done/ ∪ step-6-done/queue/, read through the MANDATORY qc_completed_labels()
#   chokepoint (ADR-128 D-3) — NOT a bare done/ glob — so a `pending after:<archived>` entry still resolves
#   dep-ready after its predecessor has been archived out of done/ (PLAN §4.3 / AC-2).
qc_pick_entry() {
  local q; q="$(qc_queue_dir)"
  # QC_SKIP (CR-002 skip-sink, Wave 4): a space/newline-separated set of entry names the SESSION has already
  # REJECTED (case 3) or REFUSED (case 4) this run. Excluding them stops `qc_pick_entry` from deterministically
  # re-selecting the same un-buildable entry every iteration — which would busy-loop an unattended daemon
  # instead of advancing to the next independent item and reaching WRAP. A skipped entry stays in pending/
  # (it is not this daemon's to terminally move); the skip is in-session only (a fresh run re-evaluates it).
  # QC_COMPLETED: the newline-separated completion set (done/ ∪ step-6-done/queue/) from the mandatory
  # qc_completed_labels() chokepoint — the ONLY sanctioned completion read (ADR-128 D-3; no bare done/ glob).
  QC_SKIP="${QC_SKIP:-}" QC_COMPLETED="$(qc_completed_labels)" python3 - "$q" <<'PYEOF'
import json, os, sys, glob
q = sys.argv[1]
skip = set(os.environ.get("QC_SKIP", "").split())
# COMPLETION membership = the union done/ ∪ step-6-done/queue/, supplied by the qc_completed_labels()
# chokepoint (ADR-128 D-3). This is NOT a bare done/ glob — an archived predecessor is still "done".
done = {x for x in os.environ.get("QC_COMPLETED", "").split("\n") if x}
cands = []
for side_path in sorted(glob.glob(os.path.join(q, "pending", "*", "sidecar.json"))):
    entry = os.path.basename(os.path.dirname(side_path))
    if entry in skip:
        continue                      # CR-002: already rejected/refused this session — never re-pick.
    try:
        side = json.load(open(side_path))
    except Exception:
        continue
    seq = side.get("seq", 0)
    after = side.get("after")
    # `after` may be a scalar label or a list of labels; normalize to a list.
    if after is None:
        after = []
    elif isinstance(after, str):
        after = [after]
    if all(dep in done for dep in after):
        cands.append((seq, entry))
cands.sort()
print(cands[0][1] if cands else "")
PYEOF
}

# qc_sidecar_field ENTRY FIELD  → print sidecar.<FIELD> for a pending entry (empty if absent).
qc_sidecar_field() {
  local entry="$1" field="$2" q; q="$(qc_queue_dir)"
  python3 - "$q/pending/$entry/sidecar.json" "$field" <<'PYEOF'
import json, sys
try:
    side = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = side.get(sys.argv[2], "")
print(v if isinstance(v, str) else (v if v is not None else ""))
PYEOF
}

# -----------------------------------------------------------------------------------------------------------
# INPUT VALIDATION — the sidecar is UNTRUSTED (binding — security gate SA-001/002/003).
# Each validator returns 0 = OK, non-zero = REJECT (the caller does reject-and-skip / continue).
# -----------------------------------------------------------------------------------------------------------

# qc_validate_entry ENTRY  → SA-001. $ENTRY must be a single in-folder DIRECTORY basename:
#   ^[a-z0-9][a-z0-9-]*$ (no '/', no '..', no leading '-'), AND _canon of the source stays UNDER
#   docs/step-4-queue/pending/. Reject-and-skip on a miss (the daemon runs unattended; a crafted '../' entry would
#   otherwise steer the git mv outside docs/step-4-queue/).
qc_validate_entry() {
  local entry="$1" q src_real pend_real; q="$(qc_queue_dir)"
  # SA-003/SA-001 newline guard: bash `[[ =~ ]]` matches the WHOLE string (a `\n`-bearing value cannot slip
  # through the way `grep`'s per-line `^…$` anchors allowed — SA-FINDING-001).
  if ! [[ "$entry" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "queue-chew: REJECTED entry '$entry' — not a single in-folder directory basename (path-traversal guard SA-001)." >&2
    return 1
  fi
  src_real="$(_canon "$q/pending/$entry")"
  pend_real="$(_canon "$q/pending")"
  case "$src_real/" in
    "$pend_real"/*) : ;;
    *) echo "queue-chew: REJECTED entry '$entry' — _canon escapes $q/pending/ (path-traversal guard SA-001)." >&2
       return 1 ;;
  esac
  return 0
}

# qc_validate_kind KIND  → AC-010 BUILD-KINDS allowlist (fail-closed). Accept only {orchestrated,nimble,chain,
#   loop}; reject planning verbs (roadmap/sweep) and anything else. Reject-and-skip.
qc_validate_kind() {
  local kind="$1"
  case "$kind" in
    orchestrated|nimble|chain|loop) return 0 ;;
    roadmap|sweep)
      echo "queue-chew: REJECTED (kind=$kind) — planning verb is deferred to the planning-queue follow-on; the daemon does NOT drain it." >&2
      return 1 ;;
    *)
      echo "queue-chew: REJECTED (kind=$kind) — not a live BUILD KIND {orchestrated,nimble,chain,loop} (AC-010 allowlist)." >&2
      return 1 ;;
  esac
}

# qc_validate_label_kind LABEL KIND  → SA-003. Untrusted sidecar string fields shape-check ^[a-z0-9-]+$
#   before they reach echo/logs (the unattended run's only review surface — log-injection guard).
qc_validate_label_kind() {
  local label="$1" kind="$2"
  # bash `[[ =~ ]]` matches the WHOLE string, so a newline-bearing label/kind cannot forge a log line the way
  # `grep`'s per-line anchors allowed (SA-FINDING-001 — the unattended run's logs are the only review surface).
  if ! [[ "$kind" =~ ^[a-z0-9-]+$ ]] || ! [[ "$label" =~ ^[a-z0-9-]+$ ]]; then
    echo "queue-chew: REJECTED — \$KIND/\$LABEL failed ^[a-z0-9-]+\$ shape check (log-injection guard SA-003)." >&2
    return 1
  fi
  return 0
}

# qc_resolve_target ENTRY  → TARGET resolution + SA-002. Resolves and VALIDATES the build-input path for an
#   entry that is currently in running/ (the drain has already moved it). Prints the resolved TARGET path on
#   success (rc 0); prints nothing + rc non-zero on a containment miss (SA-002).
#     TARGET = $q/running/<entry>/<sidecar.target>   (default sidecar.target = "." = the entry folder)
#   SA-002 (ADR-124): the allowlisted root is flipped from docs/step-3-specs/ to docs/step-4-queue/ — validate
#   _canon($TARGET) resolves UNDER docs/step-4-queue/. The caller un-drains (running→pending) on a miss.
qc_resolve_target() {
  local entry="$1" q sub target target_real queue_real; q="$(qc_queue_dir)"
  sub="$(python3 - "$q/running/$entry/sidecar.json" <<'PYEOF'
import json, sys
try:
    side = json.load(open(sys.argv[1]))
except Exception:
    print(".")
    sys.exit(0)
t = side.get("target") or "."
print(t if isinstance(t, str) else ".")
PYEOF
)"
  target="$q/running/$entry/$sub"
  target_real="$(_canon "$target")"
  queue_real="$(_canon "$q")"
  case "$target_real/" in
    "$queue_real"/*) printf '%s' "$target"; return 0 ;;
    *) echo "queue-chew: REJECTED entry '$entry' — \$TARGET '$target' escapes the allowlisted root $q/ (spec-root guard SA-002)." >&2
       return 1 ;;
  esac
}

# -----------------------------------------------------------------------------------------------------------
# BUILD-READINESS ROUTING (ADR-124 Wave 2 / Fork B) — refuse a raw, un-roadmapped plan from an unattended
# orchestrated build by default.
# -----------------------------------------------------------------------------------------------------------
# qc_classify_readiness KIND TARGET  → prints "proceed" or "refuse" (rc 0). Only `orchestrated` carries the
#   PLANNED-spec vs raw-plan distinction; nimble/chain/loop always proceed (no decompose stage). For an
#   `orchestrated` build:
#     PLANNED spec (## Tickets + ### KEY: ticket graph) → "proceed" — a straight /orchestrated build; the
#       engine skips its own preamble (slice-once), because /roadmap already sliced it.
#     raw PLAN (no ticket graph) → "refuse" by DEFAULT (the conservative operator-tunable policy): a raw plan
#       would run the FULL cto/architect/pm-spec/decompose funnel UNATTENDED — a large UNREVIEWED build — so
#       the daemon refuses and tells the operator to `/roadmap` it first. OPT-IN: set QUEUE_ALLOW_RAW_PLAN=1
#       to permit the unattended decompose-live build (documented, NOT the default).
#   Mirrors orchestrated.js detectPlanned() via queue-detect-readiness.py — ONE detector shape. Fail-closed:
#   a NOT_PLANNED / unreadable verdict refuses by default (never silently decompose-live unattended).
qc_classify_readiness() {
  local kind="$1" target="$2" s verdict; s="$(qc_scripts_dir)"
  case "$kind" in
    orchestrated) : ;;
    *) printf 'proceed'; return 0 ;;
  esac
  verdict="$(python3 "$s/queue-detect-readiness.py" "$target" 2>/dev/null)"
  if [ "$verdict" = "PLANNED" ] || [ "${QUEUE_ALLOW_RAW_PLAN:-0}" = "1" ]; then
    printf 'proceed'; return 0
  fi
  printf 'refuse'; return 0
}

# -----------------------------------------------------------------------------------------------------------
# DRAIN — within-queue git mv (pending→running→{done,failed}). PRESERVED: entries never move OUT of docs/step-4-queue/.
# -----------------------------------------------------------------------------------------------------------
# qc_drain_to STAGE_FROM STAGE_TO ENTRY  → git mv the whole entry FOLDER between lifecycle stages. The drain
#   moves the entry out of pending/'s glob range (glob-never-re-picks idempotency). Uses `git mv` when the
#   entry is tracked, else falls back to plain `mv` (the e2e test fixture may not have staged the entry).
qc_drain_to() {
  local from="$1" to="$2" entry="$3" q; q="$(qc_queue_dir)"
  mkdir -p "$q/$to"
  if git mv "$q/$from/$entry" "$q/$to/$entry" 2>/dev/null; then
    return 0
  fi
  mv "$q/$from/$entry" "$q/$to/$entry"
}

# -----------------------------------------------------------------------------------------------------------
# POST-SETTLEMENT ARCHIVAL — done/ → step-6-done/queue/ (ADR-128 D-1, the canonical merge). NO git rm.
# -----------------------------------------------------------------------------------------------------------
# qc_archive_settled  → physically archive every SETTLED done/ entry to the canonical step-6-done/queue/
#   sub-namespace, deterministically and idempotently. Prints one "ARCHIVED <label>" line per moved entry on
#   stderr (the operator's review surface) and the count on stdout. Returns 0 (archival is never an
#   execution-class block — a no-op settled set is a normal outcome).
#
#   WHAT IT DOES (ADR-128 D-1/D-2):
#     1. Ask queue-archive.py for the settled set (the F9 predicate: a done/ entry is archivable iff no live
#        pending after: names it). On `decision:"withhold"` / abstain → nothing to do (return 0).
#     2. For each settled label: a BARE main-tree `git mv done/<label>/ → step-6-done/queue/<label>/`
#        (mirroring qc_drain_to exactly — CR-001) when the entry is git-tracked, else a plain `mv` (the test
#        fixture may not have staged it). The queue lifecycle folders (docs/step-4-queue/, docs/step-6-done/)
#        live in the operator's MAIN tree; qc_git (`git -C $(qc_worktree_dir)`) targets the build worktree
#        where done/<label> is NOT tracked, so routing the move through it silently fails the `git mv` and
#        corrupts the rename into an untracked delete+add. The no-HEAD-flip property is satisfied trivially:
#        a main-tree folder move never touches the build worktree, so it categorically cannot flip the
#        operator's HEAD — isolation here is by NOT touching the worktree, not by routing through it (ADR-128 D-1).
#   INVARIANT PRESERVATION (ADR-123 D-3):
#     - #2 crash-consistency: a SINGLE git mv per entry, NO second manifest step (status stays `done`; the
#       manifest is label-keyed, not path-keyed) — introduces no new mv-then-set window. A crash mid-archival
#       leaves a half-moved set the next idempotent pass completes (folder-as-truth).
#     - #4 done|failed split: only done/ (success) entries archive; failed/ is NEVER touched here (it stays
#       the ls-legible failure sink in the queue, ADR-128 D-5).
#   NO git rm — reversible by inverse git mv (location-is-status, ADR-087). Idempotent: a re-run over an
#   already-archived state finds an empty/withheld settled set and is a no-op; `.gitkeep` is never a
#   candidate (queue-archive.py ignores non-directories — AC-7).
#
#   The archive root is <queue-parent>/step-6-done/queue/ (overridable via QC_ARCHIVE_DIR for the test, so a
#   temp repo co-locates the two folders). step-6-done/ is a canonical sibling tree, NOT under QUEUE_DIR.
qc_archive_settled() {
  local q s archive_base archive_dir settled label moved=0
  q="$(qc_queue_dir)"; s="$(qc_scripts_dir)"
  # ADR-128 Amendment 1 (SHR4-C3): the archive is DATE-PARTITIONED — step-6-done/queue/<date>/<label>, where
  # <date> = the ARCHIVAL date (ISO YYYY-MM-DD via `date -u +%F`, mirroring closeout-run.py). archive_base is
  # the queue archive root (the QC_ARCHIVE_DIR override base, or the canonical sibling tree); the dated sub-dir
  # is appended under it. A re-run on a different day writes a new date sub-dir; the dual-read side
  # (qc_completed_labels) reads ACROSS all date sub-dirs ∪ the legacy flat layout.
  if [ -n "${QC_ARCHIVE_DIR:-}" ]; then archive_base="$QC_ARCHIVE_DIR"; else archive_base="$(dirname "$q")/step-6-done/queue"; fi
  archive_dir="$archive_base/$(date -u +%F)"

  # 1. The settled set (deterministic, zero-LLM). Parse only the `archivable` array.
  #    NEWLINE-join (AC-006 / SHR4-B1): a NEWLINE-separated set fed to `while IFS= read -r` (below) splits
  #    identically under bash AND zsh. The prior SPACE-join + `for label in $settled` split differently under
  #    zsh (unquoted-$var word-split divergence: zsh's SH_WORD_SPLIT is OFF by default, so `for label in
  #    $settled` iterated the whole space-joined blob as ONE label under zsh → archived 0 — the shipped bug).
  settled="$(python3 "$s/queue-archive.py" settled --queue-dir "$q" 2>/dev/null \
    | python3 -c "import json,sys
try:
    print('\n'.join(json.load(sys.stdin)['archivable']))
except Exception:
    pass" 2>/dev/null)"

  [ -n "$settled" ] || { printf '0'; return 0; }
  mkdir -p "$archive_dir"

  # 2. Move each settled entry with a BARE main-tree git mv (CR-001: NOT qc_git — the queue folders live in
  #    the operator's main tree, not the build worktree; a main-tree move can't flip the worktree's HEAD, so
  #    isolation is satisfied by not touching the worktree). Single git mv, no git rm.
  #    PORTABLE ITERATION (AC-006): `while IFS= read -r label` over a here-string of the NEWLINE-joined set —
  #    splits on newlines identically under bash + zsh (replaces the zsh-divergent `for label in $settled`).
  while IFS= read -r label; do
    [ -z "$label" ] && continue   # guard a trailing/empty newline-split iteration (never move an empty label).
    # Defense-in-depth: the label is a done/ entry-folder basename; shape-check before it reaches a path
    # (mirrors SA-001's ^[a-z0-9][a-z0-9-]*$). A malformed candidate is skipped + logged, never moved.
    if ! [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "queue-chew: SKIPPED archival of malformed settled label '$label' — failed ^[a-z0-9][a-z0-9-]*\$ shape check (defense-in-depth)." >&2
      continue
    fi
    # Idempotency / crash-safety: skip if the source is already gone (a prior pass moved it) or the label is
    # already archived ANYWHERE under the archive base — today's dated dir, ANOTHER date's dir, OR the legacy
    # FLAT layout (don't clobber, don't double-move across the date layer). The date-layer SKIP is binding
    # (ADR-128 Amendment 1): a label already at step-6-done/queue/<any-date>/<label> — or flat
    # step-6-done/queue/<label> — must SKIP, not re-archive under today's date.
    [ -d "$q/done/$label" ] || continue
    if QC_ARCH_BASE="$archive_base" QC_ARCH_LABEL="$label" python3 - <<'PYEOF'
import os, sys
base = os.environ["QC_ARCH_BASE"]; label = os.environ["QC_ARCH_LABEL"]
# Already archived if: a flat entry base/<label>/ exists, OR any dated sub-dir base/<date>/<label>/ exists.
if os.path.isdir(os.path.join(base, label)):
    sys.exit(0)   # legacy flat hit
if os.path.isdir(base):
    for d in os.listdir(base):
        if os.path.isdir(os.path.join(base, d, label)):
            sys.exit(0)   # dated hit (any date)
sys.exit(1)   # not archived anywhere → proceed
PYEOF
    then
      echo "queue-chew: archival SKIP '$label' — already at step-6-done/queue/ (flat or dated; idempotent, ADR-128 Amendment 1)." >&2
      continue
    fi
    if git mv "$q/done/$label" "$archive_dir/$label" 2>/dev/null; then
      :
    else
      mv "$q/done/$label" "$archive_dir/$label" || { echo "queue-chew: archival FAILED to move '$label' — left in done/ (next pass retries)." >&2; continue; }
    fi
    echo "queue-chew: ARCHIVED '$label' — done/ → step-6-done/queue/$(date -u +%F)/ (settled, date-partitioned, ADR-128 D-1 + Amendment 1)." >&2
    moved=$((moved+1))
  done <<< "$settled"
  printf '%s' "$moved"
  return 0
}

# -----------------------------------------------------------------------------------------------------------
# OUTCOME BRANCH — success→done/+advance base; failure→failed/+no-advance (ADR-123 terminal split, CR-001/002).
# -----------------------------------------------------------------------------------------------------------
# qc_apply_outcome ENTRY LAUNCH_RC DIRTY  → branch on the build OUTCOME (CR-001/002). Echoes the resolved
#   outcome ("done" | "failed") on stdout so the caller can advance PRIOR_TIP only on "done".
#   SUCCESS = LAUNCH_RC == 0 AND clean tree ($DIRTY empty) → running→done. FAILURE otherwise → running→failed.
#   (Manifest `set` + BUILD-STATUS regen are SESSION-level render mechanics handled by the SKILL, not here —
#   the lib owns only the deterministic folder transition + outcome classification.)
qc_apply_outcome() {
  local entry="$1" launch_rc="$2" dirty="$3"
  if [ "$launch_rc" -eq 0 ] && [ -z "$dirty" ]; then
    qc_drain_to running done "$entry"
    printf 'done'
    return 0
  fi
  qc_drain_to running failed "$entry"
  printf 'failed'
  return 0
}

# -----------------------------------------------------------------------------------------------------------
# ARBITER — park-vs-halt (AC-015, ADR-105 extended to the queue). CALLED ONLY ON FAILURE.
#   exit 0 = park-and-continue (drain the rest); exit 1 = HALT the stack (dirty/broken base).
# -----------------------------------------------------------------------------------------------------------
qc_arbiter_decide() {
  local label="$1" launch_rc="$2" dirty="$3" s; s="$(qc_scripts_dir)"
  local q; q="$(qc_queue_dir)"

  # condition (a) ALWAYS: skip the failed item's DECLARED dependents (both edge kinds — after X + derived
  # planned_files overlap) so they do not stack on the absent/failed base. Independent items still continue.
  local deps all_deps d
  deps="$("$s/queue-order.py" dependents --pending "$q/pending" --label "$label" 2>/dev/null)"
  # NEWLINE-join + `while IFS= read -r` (AC-007 / SHR4-B1): the same zsh word-split divergence class as the
  # archival loop — `for d in $all_deps` over an unquoted space-joined blob iterates as ONE token under stock
  # zsh (SH_WORD_SPLIT off). A newline-joined here-string fed to `while IFS= read -r` splits identically under
  # bash + zsh, so the skip-dependent log fires correctly for EACH dependent under the operator's shell.
  all_deps="$(printf '%s' "$deps" | python3 -c "import json,sys
try:
    print('\n'.join(json.load(sys.stdin)['all_deps']))
except Exception:
    pass" 2>/dev/null)"
  while IFS= read -r d; do
    [ -z "$d" ] && continue   # guard a trailing/empty newline-split iteration.
    # SA-003 (defense-in-depth): shape-check each dependent label before it reaches a log / sink.
    if ! [[ "$d" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "queue-chew: SKIPPED malformed dependent label '$d' of '$label' — failed ^[a-z0-9][a-z0-9-]*\$ shape check (defense-in-depth SA-003)." >&2
      continue
    fi
    echo "queue-chew: SKIP-DEPENDENT '$d' — its predecessor '$label' failed (ADR-105 condition a, arbiter)." >&2
  done <<< "$all_deps"

  if [ -n "$dirty" ]; then
    # condition (b): dirty/broken base → HALT the whole queue (execution-class block).
    echo "queue-chew: HALT — base-integrity check tripped after '$label' (broken base, dirty tree). Stopping the stack rather than stack-on-broken-base (ADR-105 condition b)." >&2
    return 1
  fi

  if [ -n "$all_deps" ]; then
    echo "queue-chew: '$label' failed (clean tree); declared dependents skipped, independent items continue (ADR-105 condition a, arbiter)." >&2
    return 0
  fi

  echo "queue-chew: PARK '$label' — failed (clean tree) but no downstream declares a dep; logging to autonomous-decisions-log.md and continuing to the next independent item (ADR-105 default — park-and-continue, arbiter)." >&2
  return 0
}

# ===========================================================================================================
# ONE ITERATION, SPLIT ACROSS THE REAL DISPATCH (SHR3-T4 / ADR-124).
#
# v1.1 `qc_run_one` PRETENDED to dispatch: it called `launch_workflow` INLINE then read git state inline. A
# bash function cannot dispatch-and-await a REAL top-level Workflow — that await is a SESSION-LEVEL mechanic
# (a session skill fires a top-level /orchestrated|/nimble and BLOCKS on its task-notification). The queue
# v1.1 meta-finding was *green gates on a non-functional daemon*. SHR3-T4 makes the dispatch REAL by splitting
# the deterministic body away from the launch/await and putting the LLM (the chew SKILL session loop) IN THE
# MIDDLE driving the real Workflow:
#
#   qc_next   (deterministic, BEFORE dispatch — pick / SA-001 / kind+label / SA-003 / AC-010 allowlist /
#              drain pending→running / SA-002 resolve+validate target / build-readiness routing). NO DISPATCH.
#        ↓    (LLM SEAM, in the SKILL: read qc_next's caller-visible vars → fire the REAL top-level Workflow
#              with --kind/--target/--base-sha → BLOCK/await its task-notification → observe launch_rc + the
#              worktree's new tip + dirty state — all in the daemon's WORKTREE per SHR3-T3.)
#   qc_settle (deterministic, AFTER dispatch — branch-on-outcome / move running→done|failed / arbiter /
#              reconcile). Takes launch_rc + dirty as ARGS the session passes; reads NO git state inline.
#
# `launch_workflow` is DEMOTED OUT of the production path entirely (SHR3-T4 / AC-010, the security boundary):
# no production drain function calls it; the only surviving call site is a TEST-ONLY stub in
# test-queue-chew-e2e.sh. No production drain may invoke an unisolated inline dispatch.
# ===========================================================================================================
# qc_next  → the BEFORE-DISPATCH deterministic half. Returns the same iteration codes as the old qc_run_one
#   pre-dispatch phase:
#     0  = ready-to-dispatch (entry drained to running/, target resolved & validated) → the SESSION dispatches
#     2  = nothing dep-ready → caller WRAPs / idles / exits (§ Termination)
#     3  = entry rejected (validation / allowlist / SA-002 containment miss, un-drained) → caller pops the next
#     4  = raw-plan REFUSED (Fork B, un-drained, left queued) → caller pops the next
#   Sets the caller-visible vars the SESSION needs to drive dispatch and hand back to qc_settle:
#     QC_LAST_ENTRY (drained entry folder name), QC_LAST_LABEL, QC_LAST_TARGET (resolved+validated build
#     input), QC_LAST_KIND. QC_LAST_OUTCOME is set only for the terminal pre-dispatch verdicts
#     ("empty"|"reject"|"refuse-raw-plan"); on rc 0 it is reset (the OUTCOME is decided by qc_settle).
#   NO DISPATCH happens here — the SA-002 un-drain-on-miss and the refuse-raw-plan un-drain both live HERE,
#   BEFORE any build, exactly as in the original (ordering byte-preserved through the split).
qc_next() {
  local q s entry kind label target
  q="$(qc_queue_dir)"; s="$(qc_scripts_dir)"
  QC_LAST_OUTCOME=""; QC_LAST_ENTRY=""; QC_LAST_LABEL=""; QC_LAST_TARGET=""; QC_LAST_KIND=""

  # 1. PICK — fresh FS read every iteration (the cross-session mailbox poll — NEVER cached).
  entry="$(qc_pick_entry)"
  if [ -z "$entry" ]; then QC_LAST_OUTCOME="empty"; return 2; fi
  QC_LAST_ENTRY="$entry"

  # 1a. SA-001 — entry folder-basename path-traversal guard (BEFORE any git mv).
  if ! qc_validate_entry "$entry"; then QC_LAST_OUTCOME="reject"; return 3; fi

  kind="$(qc_sidecar_field "$entry" verb)"
  label="$(qc_sidecar_field "$entry" label)"
  [ -n "$label" ] || label="$entry"
  QC_LAST_LABEL="$label"

  # 1b. SA-003 — shape-check untrusted $LABEL/$KIND before they reach logs.
  if ! qc_validate_label_kind "$label" "$kind"; then QC_LAST_OUTCOME="reject"; return 3; fi

  # 2. AC-010 BUILD-KINDS allowlist (fail-closed). A rejected planning verb is LEFT in pending/.
  if ! qc_validate_kind "$kind"; then QC_LAST_OUTCOME="reject"; return 3; fi
  QC_LAST_KIND="$kind"

  # 3. within-queue drain: pending/ → running/ (glob-never-re-picks).
  qc_drain_to pending running "$entry"

  # 3b. SA-002 — resolve + validate $TARGET (now under docs/step-4-queue/, the entry's in-queue artifact). On a
  #     containment miss, un-drain running→pending (nothing was built) and reject-and-skip.
  if ! target="$(qc_resolve_target "$entry")"; then
    qc_drain_to running pending "$entry"
    QC_LAST_OUTCOME="reject"; return 3
  fi
  QC_LAST_TARGET="$target"

  # 3c. BUILD-READINESS ROUTING (ADR-124 Wave 2 / Fork B). Refuse a raw, un-roadmapped plan from an unattended
  #     orchestrated build by DEFAULT — un-drain it (leave it queued for the operator to /roadmap), and skip.
  #     QUEUE_ALLOW_RAW_PLAN=1 opts into the unattended decompose-live build.
  if [ "$(qc_classify_readiness "$kind" "$target")" = "refuse" ]; then
    echo "queue-chew: REFUSED '$label' — orchestrated target is a RAW PLAN (not roadmapped: no '## Tickets' / '### KEY:' ticket graph). /roadmap it first, or set QUEUE_ALLOW_RAW_PLAN=1 to decompose-live unattended (ADR-124 Fork B — refuse raw plan is the default)." >&2
    qc_drain_to running pending "$entry"
    QC_LAST_OUTCOME="refuse-raw-plan"; return 4
  fi

  # READY-TO-DISPATCH. The entry is in running/, its target is resolved + validated. The SESSION now fires the
  # REAL top-level Workflow (--kind "$QC_LAST_KIND" --target "$QC_LAST_TARGET" --base-sha "$PRIOR_TIP"),
  # BLOCKS on its task-notification, then calls qc_settle with the observed launch_rc + worktree dirty state.
  # NO DISPATCH in the lib — that is deliberately the session's job (SHR3-T4).
  QC_LAST_OUTCOME=""   # the OUTCOME is qc_settle's to decide (not a pre-dispatch verdict)
  return 0
}

# qc_settle ENTRY LABEL LAUNCH_RC DIRTY  → the AFTER-DISPATCH deterministic half. The SESSION calls this with
#   the entry/label qc_next handed it, plus the launch_rc and the worktree DIRTY state IT OBSERVED after the
#   real dispatch+await (no inline git read — the lib is git-state-agnostic beyond what it is handed, header
#   intent preserved). Branches on outcome BEFORE any move (CR-001/002): SUCCESS (launch_rc 0 + clean tree) →
#   running→done + QC_LAST_OUTCOME=done; FAILURE → running→failed + arbiter (park / skip-dependent / halt).
#   Returns:
#     0  = item drained (success → done/, or parked/skip-dependent failure → failed/) → caller pops the next
#     1  = HALT the stack (arbiter condition b: dirty/broken base)
#   Sets QC_LAST_OUTCOME ("done"|"failed") + QC_LAST_ENTRY/QC_LAST_LABEL so the SESSION reconciles the EXACT
#   entry deterministically (CR-002 — never an `ls -dt` mtime inference). The session advances PRIOR_TIP from
#   the worktree's NEW tip ONLY on "done" (the lib never advances the base).
qc_settle() {
  local entry="$1" label="$2" launch_rc="$3" dirty="$4" outcome
  QC_LAST_ENTRY="$entry"; QC_LAST_LABEL="$label"

  # BRANCH ON OUTCOME *BEFORE* ANY MOVE (CR-001/002). Clean tree is the success precondition.
  outcome="$(qc_apply_outcome "$entry" "$launch_rc" "$dirty")"
  QC_LAST_OUTCOME="$outcome"

  if [ "$outcome" = "done" ]; then
    # SUCCESS — caller advances PRIOR_TIP from the worktree's NEW tip. (Manifest set + BUILD-STATUS regen: SKILL.)
    return 0
  fi

  # FAILURE — base NOT advanced (caller keeps PRIOR_TIP). Run the park-vs-halt arbiter.
  if qc_arbiter_decide "$label" "$launch_rc" "$dirty"; then
    return 0   # park-and-continue → caller pops the next independent item
  fi
  return 1     # HALT (dirty/broken base)
}
