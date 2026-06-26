#!/usr/bin/env python3
"""persist-run-artifacts.py — orchestrator-side artifact-sync for Workflow runs.

# Binding invariant (ADR-068 — load-bearing for OBS-W1-PERSIST):
#
#     The journal is the RUNTIME's; persist READS, the Workflow script NEVER
#     writes one.
#
# The native CC RUNTIME owns `agent-*.jsonl` at
# `~/.claude/projects/<slug>/<session>/subagents/` — it is the runtime's
# transcript of each subagent's life. This script may READ a journal as a
# FALLBACK input source when the structured Workflow return is absent/empty
# (the dropped-return cliff — see ADR-068 Context for the two live failures
# that drove this). The Workflow scripts (`core/scripts/workflows/*.js`)
# NEVER write a journal, NEVER mutate one, and have no filesystem access
# at all (preserves ADR-039 contract 2's write-side verbatim). The negative
# invariant guard (AC-016) is enforceable by grep on this file + the .js
# engine scripts; no code path here opens a journal for write.

THE FLAG-1 PIECE (T5a #1 AC). A Workflow script has NO filesystem access, and
read-only agents (e.g. Explore) cannot Write. So knowledge artifacts cannot be
written from inside the workflow. The contract is:

    the Workflow script RETURNS a structured payload;
    the ORCHESTRATOR persists findings/* + run-log.md from that return.

This helper makes that persistence MECHANICAL and TESTABLE rather than prose the
orchestrator might skip. Given the nimble preset's return JSON + run metadata, it
deterministically writes the run folder's knowledge artifacts and updates the thin
manifest. The orchestrator calls it once, immediately after the Workflow returns,
BEFORE any consolidated-surface / commit step.

## Journal-read fallback (ADR-068 — spike-positive branch)

When the structured return is absent / empty / missing required keys, the script
falls back to reading the native CC per-agent journal as its persist INPUT source.
The fallback fires DETERMINISTICALLY based on primary-input shape (no new CLI flag
— operator can't forget it). Triggering rule + safety properties:

  - PRIMARY input: `--return-file` (and, after idea-pipeline T-010 lands,
    `--workflow-output` — currently DEFERRED, see deferrals-log).
  - FALLBACK input: the current orchestrator session's `agent-*.jsonl` journals,
    discovered via the same path-resolution algorithm as
    `core/scripts/lib/native-transcript-path.sh` (Bash; Python re-implements the
    algorithm here — the algorithm is the spec; both implementations stay
    byte-identical).
  - Scope-bounded: only journals under the CURRENT session's `subagents/` dir;
    never globbed broadly; never reads another session's journals (AC-024).
  - Crash-safe: malformed JSONL → exit non-zero with `PERSIST-RUN:
    error=malformed-journal path=<path> line=<N>` on stderr, write NOTHING
    (AC-022). Permission-denied → exit non-zero with `PERSIST-RUN:
    error=permission-denied path=<path>`, write NOTHING (AC-017).
  - Idempotent: re-using the existing `_w()` atomic-write contract (tmp +
    os.replace) — re-running the persist produces the same artifacts (AC-012).
  - Provenance: `run-log.md` ALWAYS records `Input source: workflow-return`
    (happy path; AC-021) or `Input source: journal-fallback (native CC
    transcript)` (fallback; AC-020). When the fallback fires, the script also
    emits `PERSIST-RUN: source=journal-fallback path=<journal_path>` on
    stderr (AC-020).

Input: the workflow return object (the nimble.js return shape):
    {
      "exploreMap":  ["...", ...],          # explore agent outputs
      "implementation": "COMPLETION_REPORT", # implementer text
      "review":      {"verdict","summary","findings":[...]},      # code-reviewer
      "conformance": {"verdict","summary","findings":[...]},      # spec-conformance
      "allFindings": [...],
      "criterionFindings": [...],            # surface-worthy (ADR-018 crit-1..5)
      "surfaceRequired": bool
    }
Absent keys are tolerated (a chain that ran fewer agents writes fewer files).

Writes, under {run_dir}:
    findings/explore-{i}.md         (one per exploreMap entry)
    findings/implementer.md
    findings/code-reviewer.md       (if review present)
    findings/spec-conformance.md    (if conformance present)
    run-log.md                      (verdicts + finding counts + surface state)
    manifest.json                   (thin manifest: steps -> complete, run status)

Usage:
    persist-run-artifacts.py --run-dir D --return-file R.json
        [--slug S] [--task T] [--chain a,b,c] [--no-manifest]

Idempotent: re-running overwrites the same files deterministically. Exit 0 ok.
"""
import json, os, sys, argparse, subprocess, datetime, glob, re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _die(msg, code=2):
    sys.stderr.write(f"persist-run-artifacts: {msg}\n")
    sys.exit(code)


# ----------------------------------------------------------------------------
# Journal-read fallback (ADR-068 — preserves ADR-039 contract 2 write-side).
# READS the native CC per-agent journal; NEVER writes one. The Workflow script
# also NEVER writes a journal (verified by AC-016 negative grep on
# core/scripts/workflows/*.js).
# ----------------------------------------------------------------------------

# Required keys for "primary input is usable" — the trigger for the fallback.
# If a return is missing ALL of these (the dropped-return shape) the fallback
# fires. The set is the UNION of every shape a real Workflow return carries:
#
#   - nimble:       exploreMap / implementation / review / conformance
#   - orchestrated: implementResults / cto / spec / tickets / archPre / archFinal
#                   (also short-circuit shapes: just cto + stoppedAt + surfaceRequired)
#   - chain:        steps[]
#   - roadmap:      roadmapMarkdown / waveSpecMarkdown / findings
#
# Track-shaped meta-keys also count as "usable" — `track` + `stoppedAt` +
# `surfaceRequired` + `criterionFindings` indicate a structured return even if
# every agent step short-circuited (e.g. a cto NO-GO that stopped before
# implementation). The predicate is permissive on the happy/short-circuit side
# and only the genuinely-missing-everything shape triggers the journal-read
# fallback (preserves the orchestrated short-circuit test surface — see
# `core/scripts/test-orchestrated-engine.sh` B3).
_FALLBACK_TRIGGER_KEYS = (
    # nimble
    "exploreMap", "implementation", "review", "conformance",
    # orchestrated
    "implementResults", "cto", "spec", "archPre", "archFinal",
    "integrate", "tickets", "uiSpec", "contextualReviews",
    # chain
    "steps",
    # roadmap
    "roadmapMarkdown", "waveSpecMarkdown", "findings", "waves",
    # track-shaped meta (short-circuit returns)
    "track", "stoppedAt", "surfaceRequired", "criterionFindings",
)


def _journal_resolve_main(start_dir):
    """Resolve the MAIN repo path from any cwd inside the repo or a worktree.

    Mirrors `core/scripts/lib/native-transcript-path.sh::native_transcript_resolve_main`.
    Returns the absolute main repo path; raises on failure (no .git found).
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=start_dir, capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        raise RuntimeError(f"not in a git repo (start_dir={start_dir})") from e
    if not os.path.isabs(out):
        out = os.path.join(start_dir, out)
    # Do NOT realpath: the runtime's slug uses the OPERATOR-FACING path
    # (e.g. /Users/x on macOS, NOT the canonical /private/Users/x). Mirror
    # `core/scripts/lib/native-transcript-path.sh::native_transcript_resolve_main`,
    # which uses `cd "$(dirname "$common")" && pwd` — that's a plain logical
    # path resolution, not a `pwd -P` realpath.
    return os.path.abspath(os.path.dirname(out))


def _journal_repo_slug(repo_path):
    """Algorithm: replace '/' with '-' in the absolute repo path (keeps leading '-').

    Mirrors `core/scripts/lib/native-transcript-path.sh::native_transcript_repo_slug`.
    """
    return repo_path.replace("/", "-")


def _journal_session_dir(session_id, start_dir):
    """Return the absolute `<projects>/<slug>/<session>/subagents/` dir.

    Scope-bounded: returns ONE specific session's subagents dir; the caller must
    not glob beyond it (AC-024). Returns None if the dir does not exist (the
    fallback then emits a deterministic refuse-clean error).
    """
    main = _journal_resolve_main(start_dir)
    slug = _journal_repo_slug(main)
    home = os.path.expanduser("~")
    d = os.path.join(home, ".claude", "projects", slug, session_id, "subagents")
    return d if os.path.isdir(d) else None


def _journal_iter_records(path):
    """Yield (lineno, record) for each parseable JSONL record in *path*.

    Reads the file once, line by line. Raises ValueError on the FIRST malformed
    line (the caller catches and emits the `error=malformed-journal line=N` line
    and exits non-zero without writing anything — AC-022). Raises PermissionError
    on permission-denied (caller emits `error=permission-denied` — AC-017).

    READ-ONLY. Opens the file with mode='r' (no write, no append, no truncation).
    Does not modify file mtime/atime beyond what the OS does for a normal read.
    """
    with open(path, encoding="utf-8") as f:  # READ-only mode (no 'w'/'a').
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                raise ValueError(f"line={lineno}: {e.msg}") from e
            yield lineno, rec


def _journal_extract_agent_text(records, meta):
    """Build the markdown text for a single agent's findings file from its journal.

    Strategy: render the agent's `agentType` (from meta.json) + the LAST assistant
    record's text content as the canonical "report" — this matches what a
    happy-path Workflow return would have surfaced (the agent's terminal message
    is the deliverable). Earlier records (tool-use chatter) are not duplicated
    into the persisted findings; the full journal stays available at its native
    path if a debugger needs it.

    Returns (agent_type, markdown_text). Robust to records lacking expected
    fields (the journal IS the runtime's substrate; structure is stable but the
    extractor MUST not crash on a malformed sub-shape).
    """
    agent_type = (meta or {}).get("agentType") or "agent"
    last_text = ""
    for _ln, rec in records:
        if rec.get("type") != "assistant":
            continue
        msg = rec.get("message") or {}
        content = msg.get("content")
        # CC stores `content` either as a string OR as a list of typed blocks
        # ({"type":"text","text":...}, {"type":"tool_use",...}, …). Pull text.
        if isinstance(content, str):
            last_text = content
        elif isinstance(content, list):
            chunks = []
            for blk in content:
                if isinstance(blk, dict) and blk.get("type") == "text" and blk.get("text"):
                    chunks.append(str(blk["text"]))
            if chunks:
                last_text = "\n\n".join(chunks)
    return agent_type, (last_text or "").strip()


def _journal_session_id():
    """The current orchestrator session id. The fallback bounds itself to THIS
    session — never another session's journals (AC-024).
    """
    return os.environ.get("CLAUDE_CODE_SESSION_ID") or ""


def _journal_synthesize_return(run_dir):
    """Read the current-session journals + synthesize a return-shaped dict the
    nimble persist branch (the default `main()` path) can consume.

    Triggered only when the primary input is unusable (the deterministic-trigger
    rule — AC-018). Returns the synthesized dict. May raise:
        FileNotFoundError — no session id / subagents dir not present
        PermissionError   — journal unreadable
        ValueError        — malformed JSONL (carries `line=N`)

    Scope-bound (AC-024): the fallback enumerates only the CURRENT
    `$CLAUDE_CODE_SESSION_ID`'s `subagents/` directory — never broadly globs
    the runtime transcript dir, never reads another session's journals. The
    runtime maintains one subagents/ dir per orchestrator session, so the
    session-id bound is the natural scope. The run folder is also confirmed
    accessible (the script's --run-dir is the only write target).
    """
    session_id = _journal_session_id()
    if not session_id:
        raise FileNotFoundError("no CLAUDE_CODE_SESSION_ID in env (fallback needs the orchestrator session)")
    subagents_dir = _journal_session_dir(session_id, run_dir)
    if not subagents_dir:
        raise FileNotFoundError(f"session subagents dir not found for session={session_id}")

    # Confirm the run-dir is accessible (write target).
    try:
        os.path.getmtime(run_dir)
    except OSError as e:
        raise FileNotFoundError(f"run-dir not accessible: {run_dir}") from e

    # AC-024: enumerate ONLY the current-session subagents dir; never glob outside.
    journals = sorted(glob.glob(os.path.join(subagents_dir, "agent-*.jsonl")))
    if not journals:
        raise FileNotFoundError(
            f"no agent-*.jsonl under {subagents_dir} "
            f"(session={session_id}, run_dir={run_dir})"
        )

    explore_map = []
    implementer_text = ""
    review = None
    conformance = None

    for jpath in journals:
        # Load meta sibling (best-effort — meta absent does not block the fallback).
        meta_path = jpath[:-len(".jsonl")] + ".meta.json"
        meta = {}
        if os.path.isfile(meta_path):
            try:
                with open(meta_path, encoding="utf-8") as f:
                    meta = json.load(f)
            except (OSError, ValueError):
                meta = {}

        # Iterate records (READ-only). Raises on malformed; caller refuses-clean.
        try:
            records = list(_journal_iter_records(jpath))
        except PermissionError:
            # AC-017: refuse-clean with the path on stderr; the caller exits non-zero.
            raise PermissionError(jpath)
        except ValueError as e:
            # AC-022: re-raise with the path embedded so main() can emit
            # `error=malformed-journal path=<path> line=<N>` deterministically.
            raise ValueError(f"path={jpath} {e}") from e

        agent_type, text = _journal_extract_agent_text(records, meta)
        if not text:
            continue

        # Route into the synthesized return by agent class. Conservative: anything
        # not obviously a gate/implementer becomes an explore entry.
        at_lc = (agent_type or "").lower()
        if at_lc in ("implementer", "wave-implementer"):
            # Multiple implementer dispatches concatenate (rare in nimble; the
            # ordered text preserves chronology by sorted-path enumeration).
            implementer_text = (implementer_text + "\n\n" + text).strip() if implementer_text else text
        elif at_lc == "code-reviewer":
            review = {"verdict": "FALLBACK", "summary":
                      "Synthesized from native CC journal (workflow-return dropped). "
                      "See raw transcript for findings shape.", "findings": [], "_raw": text}
        elif at_lc == "spec-conformance":
            conformance = {"verdict": "FALLBACK", "summary":
                           "Synthesized from native CC journal (workflow-return dropped).",
                           "findings": [], "_raw": text}
        else:
            explore_map.append(f"### {agent_type}\n\n{text}")

    return {
        # Mark the source so downstream persist routes (and run-log) can detect.
        "_input_source": "journal-fallback",
        "_journal_paths": journals,
        # Synthesize a nimble-shaped return (most conservative — works with the
        # default branch of main(); orchestrated/chain detection in main() will
        # see no `track`/`implementResults`/`steps` and route to nimble persist).
        "exploreMap": explore_map,
        "implementation": implementer_text,
        "review": review,
        "conformance": conformance,
        "allFindings": [],
        "criterionFindings": [],
        "surfaceRequired": False,
    }


def _primary_input_usable(r):
    """The deterministic-trigger predicate (AC-018). Return True iff the parsed
    primary input has at least one of the keys a real Workflow return carries.

    No CLI flag (AC-019). The rule is purely shape-driven so the operator can't
    forget to enable the fallback.
    """
    if not isinstance(r, dict):
        return False
    return any(r.get(k) for k in _FALLBACK_TRIGGER_KEYS)


# ----------------------------------------------------------------------------
# Notable-artifact filter (ADR-080 D1 — amends ADR-068).
#
# `rules-artifact-surfacing.md` asks the orchestrator to filter the written
# artifacts against a notable-class allowlist and SendUserFile each match. The
# filter is a list intersection — not judgment — so it moves into the script
# (one source of truth; the rule file shrinks to a pointer). The orchestrator's
# residual duty is purely: SendUserFile everything in `notable`.
#
# Allowlist (notable classes), codified from the rule:
#   - jam READMEs:        docs/step-2-planning/jam-*/README.md | index.md
#   - specs:              docs/step-3-specs/**/roadmap.md
#                         docs/step-3-specs/**/waves/<wave>/<wave>.md
#                         docs/step-3-specs/**/waves/<wave>/<wave>-prompts.md
#   - ADRs:               docs/decisions/ADR-*.md
#   - end-of-run run-log: <any run folder>/run-log.md
#   - locked roadmaps:    <any run folder>/locked.md
#
# Exclusions (enforced by construction — these never match the allowlist, but
# called out so the filter stays honest as the allowlist evolves):
#   - findings/*                         (per-agent fan-out the chain streams)
#   - manifest.json / run-manifest.json  (control-flow state)
#   - fixtures (core/scripts/{tests,test-fixtures}/**)
#   - docs/step-1-ideas/*              (author-once backlog inbox: ideas + DEFER-/FOLLOWUP-; ADR-087)
#   - docs/step-1-ideas/RAW-*  /  docs/deferrals/OPEN-*  (legacy pre-ADR-087 layouts; kept until migration)
# ----------------------------------------------------------------------------

# Excluded path fragments — a written path matching ANY of these is never notable,
# even if a future allowlist rule would otherwise admit it (defense-in-depth so
# the two lists can't drift into mutual contradiction).
_NOTABLE_EXCLUDE_SUBSTRINGS = (
    "/findings/",
    "core/scripts/tests/",
    "core/scripts/test-fixtures/",
    "/docs/step-1-ideas/",   # ADR-087: the one inbox — all scratch funnel
    "/docs/step-1-ideas/RAW-",  # legacy (pre-ADR-087)
    "/docs/deferrals/OPEN-",    # legacy (pre-ADR-087)
    "recalled-facts",           # AMS-T7/AC-014: per-run scratch (regenerable; ambient recall), never surfaced
)


def _norm_rel(path):
    """Normalize a written path to a forward-slash form for matching.

    persist writes a mix of run-folder-relative and repo-root-relative paths; the
    allowlist matches on the trailing structure (docs/... or .../run-log.md), so we
    only need POSIX-normalized separators, not absolute resolution.
    """
    return str(path).replace("\\", "/")


def compute_notable(written):
    """Pure filter: return the subset of *written* that is a notable artifact
    (ADR-080 D1). Order-preserving; deduplicated; exclusions win over the allowlist.

    Matches on path structure only — no filesystem access — so it is cheaply
    unit-testable (test-persist-notable.sh imports this via `python3 -c`).
    """
    notable = []
    seen = set()
    for raw in (written or []):
        p = _norm_rel(raw)
        if p in seen:
            continue
        base = p.rsplit("/", 1)[-1]

        # Exclusions win first.
        if any(frag in p for frag in _NOTABLE_EXCLUDE_SUBSTRINGS):
            continue
        if base in ("manifest.json", "run-manifest.json"):
            continue

        is_notable = False

        # Jam READMEs: docs/step-2-planning/jam-*/{README,index}.md
        if "docs/step-2-planning/jam-" in p and base in ("README.md", "index.md"):
            is_notable = True
        # Specs under docs/step-3-specs/**: roadmap.md + wave spec/prompts.
        elif "docs/step-3-specs/" in p:
            if base == "roadmap.md":
                is_notable = True
            elif "/waves/" in p and base.endswith(".md"):
                # <wave>.md and <wave>-prompts.md (any .md under a waves/<wave>/ dir).
                is_notable = True
        # ADRs: docs/decisions/ADR-*.md
        elif "docs/decisions/" in p and base.startswith("ADR-") and base.endswith(".md"):
            is_notable = True
        # End-of-run run-log + locked roadmap snapshot (any run folder).
        elif base in ("run-log.md", "locked.md"):
            is_notable = True

        if is_notable:
            seen.add(p)
            notable.append(raw)
    return notable


# ----------------------------------------------------------------------------
# AMS-T2 (wave-1-writes, AC-001/AC-002/AC-021) — post-persist memory write seam.
#
# Captures the notable run artifacts into the Graphiti memory graph AS THEY ARE
# PERSISTED, so downstream recall (W2/W3) has content to work against. Binding
# constraints (do not weaken):
#   - SOURCE OF TRUTH (AC-001): the caller passes compute_notable(written)'s
#     notable[] DIRECTLY. This helper NEVER re-enumerates the notable classes
#     (no `if "docs/decisions/" in path`, no parallel allowlist — the F-006 drift
#     trap, ADR-080 D1). It iterates the list it is given, as-is (already
#     order-preserving + deduplicated).
#   - SINGLE WRITE FUNNEL (AC-003): each artifact reaches the graph ONLY via
#     graphiti-ingest-doc.py, which wraps graphiti_write.write_fact() (scrub →
#     fail-closed group_id → content-hash idempotency). No add_episode / Graphiti()
#     here. group_id is derived fail-closed (the same _resolve_group_id the funnel
#     uses) — never a hand-assembled permissive string.
#   - OFF-BY-DEFAULT + FAIL-OPEN (AC-021): gated behind the opt-in flag file
#     .claude/agent-memory/graphiti-capture-enabled (mirrors the SessionEnd
#     capture gate). Absent flag -> silent no-op. Any failure (engine down,
#     docker missing, no API key, derivation error) logs ONE stderr line and is
#     swallowed — the persist itself ALWAYS returns its structured payload
#     (ADR-039 contract 2). Removing this call leaves persist fully functional.
# ----------------------------------------------------------------------------

def _repo_root():
    """Repo root for the capture seam — core/scripts/<this> -> two parents up. Fail-open to cwd."""
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        return os.path.dirname(os.path.dirname(here))
    except Exception:
        return os.getcwd()


def _memory_capture_enabled(repo_root):
    """True iff the opt-in capture flag exists (off-by-default — AC-021)."""
    try:
        return os.path.isfile(os.path.join(
            repo_root, ".claude", "agent-memory", "graphiti-capture-enabled"))
    except Exception:
        return False


def _derive_capture_group(repo_root):
    """Fail-closed group_id for the capture seam (AC-003/AC-AUTH).

    Delegates to graphiti_write._resolve_group_id (the funnel's own resolver) so a
    derivation miss quarantines to unsorted:NEEDS_TRIAGE — never a permissive shared
    group, never a hand-assembled string. Returns None on any failure (caller no-ops).
    """
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        if here not in sys.path:
            sys.path.insert(0, here)
        import graphiti_write as gw  # noqa: E402 — the safe write core
        return gw._resolve_group_id(None, repo_root)
    except Exception as e:  # noqa: BLE001 — fail-open
        print(f"graphiti-capture: group derivation skipped ({e})", file=sys.stderr)
        return None


def _write_notable_to_memory(notable, repo_root, dry_run=False):
    """Capture each notable artifact to memory via the ingest CLI (AC-002 wire-to-consumer).

    Called once per persist site, immediately after compute_notable(written). Consumes the
    notable[] list DIRECTLY (AC-001 — no re-enumeration). Off-by-default + fail-open (AC-021).
    Returns the count of artifacts for which an ingest invocation was issued (0 when disabled
    or on any error) — used by the test harness to assert fires-once-per-artifact.
    """
    try:
        if not notable:
            return 0
        # Honor an explicit dry-run override (test path) without requiring the live flag,
        # but the LIVE capture path is still gated by the enable flag (off-by-default).
        if not dry_run and not _memory_capture_enabled(repo_root):
            return 0
        group_id = _derive_capture_group(repo_root)
        if not group_id:
            return 0
        here = os.path.dirname(os.path.abspath(__file__))
        ingest = os.path.join(here, "graphiti-ingest-doc.py")
        if not os.path.isfile(ingest):
            return 0
        fired = 0
        for path in notable:
            abspath = path if os.path.isabs(path) else os.path.join(repo_root, path)
            cmd = ["python3", ingest, abspath, "--group-id", group_id,
                   "--repo-root", repo_root]
            if dry_run:
                cmd.append("--dry-run")
            try:
                subprocess.run(cmd, capture_output=True, text=True, timeout=120)
                fired += 1
            except Exception as e:  # noqa: BLE001 — one artifact's failure never blocks the rest
                print(f"graphiti-capture: ingest failed for {path} ({e})", file=sys.stderr)
        return fired
    except Exception as e:  # noqa: BLE001 — the whole seam is fail-open (AC-021)
        print(f"graphiti-capture: seam skipped ({e})", file=sys.stderr)
        return 0


# ----------------------------------------------------------------------------
# Auto-close-out seam (SHR3-T1 / ADR-100 — wires the deterministic completion step).
#
# Close-out was orchestrator MEMORY, not code: nothing auto-fired closeout-run.py,
# so a completed run leaked in step-5-pipeline/ whenever the orchestrator forgot the
# verb. This seam makes the MOVE a deterministic side-effect of TERMINAL-COMPLETION
# persistence — the same call that lands findings/run-log conveys the finished run
# out of the pipeline. Binding constraints (do not weaken):
#
#   - TERMINAL-ONLY (AC-001): fires ONLY when a persist path computed run_status ==
#     "complete". A surfaced/blocked/in-flight run NEVER triggers the MOVE.
#   - REUSE, do not reimplement (AC-001): delegates to closeout-run.run_closeout —
#     the SAME MOVE + waiting-on-you render + OUT-bookend scope gate + ADR-087
#     tolerances. No move logic is duplicated here.
#   - SCOPE-GATE-HONORING (AC-003): does NOT pass skip_scope_check. An unaccounted
#     decided atom refluxes to docs/step-1-ideas/from-<run>/ and the move is HELD
#     (run_closeout returns 3) exactly as the manual path does. The HELD outcome is
#     surfaced (logged), never silently swallowed into a clean wrap.
#   - IDEMPOTENT + FAIL-OPEN (AC-002): wrapped in try/except so it NEVER crashes
#     persist (ADR-039 contract 2 — persist must always return its payload). An
#     already-moved run is a no-op (run_closeout/closeout treat a step-6-done folder
#     as a no-op exit 0); a malformed/absent manifest or missing source warns +
#     continues (closeout-run.py is already tolerant, ADR-087 §5e).
#   - STAGE-ONLY (no commit/push): inherited from closeout-run.py verbatim.
# ----------------------------------------------------------------------------

def _run_under_pipeline(run_dir):
    """True iff run_dir lives under <repo-of-run_dir>/docs/step-5-pipeline/. Resolves
    the repo root FROM THE RUN_DIR (not the script location), so close-out only ever
    conveys a run that actually sits in that repo's pipeline. This is the safety guard
    that keeps the auto path from `git mv`-ing an out-of-tree / temp-fixture run into
    THIS repo's step-6-done (it also makes the wiring inert for engine tests that drive
    persist on a throwaway run dir). Fail-closed: any resolution failure → do not fire."""
    try:
        ad = os.path.abspath(run_dir)
        out = subprocess.run(["git", "-C", ad, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=False)
        if out.returncode != 0 or not out.stdout.strip():
            return False
        root = os.path.abspath(out.stdout.strip())
        pipeline = os.path.join(root, "docs", "step-5-pipeline") + os.sep
        return ad.startswith(pipeline)
    except Exception:
        return False


def _auto_closeout(run_dir, run_status):
    """Fire the deterministic close-out MOVE on terminal completion. Fail-open: a
    failure here NEVER affects persist's primary duty. Returns the close-out exit
    code (0 clean / no-op, 3 HELD) for the test harness, or None when not fired.

    Fires ONLY when (a) the run is terminal-complete AND (b) run_dir actually lives
    under its repo's docs/step-5-pipeline/ (the production shape). The pipeline guard
    is the safety floor — a persist driven on an out-of-tree / temp run dir is a no-op,
    so close-out can never `git mv` a foreign run into this repo's step-6-done."""
    if run_status != "complete":
        return None
    if not _run_under_pipeline(run_dir):
        # Not a pipeline-resident run (out-of-tree / temp fixture) — auto-close-out is inert.
        return None
    try:
        # closeout-run.py has a hyphen — load it by file path (not importable by name).
        import importlib.util
        here = os.path.dirname(os.path.abspath(__file__))
        co_path = os.path.join(here, "closeout-run.py")
        spec = importlib.util.spec_from_file_location("closeout_run", co_path)
        closeout_run = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(closeout_run)
        # No skip_scope_check (AC-003): the OUT-bookend scope gate stays live, so an
        # unaccounted atom refluxes + HOLDs the move exactly as the manual path does.
        rc = closeout_run.run_closeout(run_dir)
        if rc == 3:
            print("PERSIST-RUN: closeout=HELD (scope gate refused a clean wrap — "
                  "unaccounted atom refluxed to step-1-ideas/from-<run>/)", file=sys.stderr)
        else:
            print("PERSIST-RUN: closeout=moved (terminal-complete run conveyed to step-6-done)",
                  file=sys.stderr)
        return rc
    except Exception as e:  # noqa: BLE001 — fail-open; persist always completes (AC-002)
        print(f"PERSIST-RUN: auto-closeout skipped (persist unaffected): {e}", file=sys.stderr)
        return None


def _w(path, text):
    # CR-010: atomic write (tmp + os.replace) so a crash mid-write never leaves a truncated
    # knowledge artifact (adr.md / spec.md / run-log.md) for a downstream reader.
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text if text.endswith("\n") else text + "\n")
    os.replace(tmp, path)


def _findings_block(obj):
    """Render a gate agent's findings list as markdown."""
    lines = []
    for f in (obj.get("findings") or []):
        lines.append(
            f"- **{f.get('id','?')}** "
            f"[{f.get('severity','?')} · {f.get('criterion_match','?')} · {f.get('recommended_disposition','?')}] "
            f"{(f.get('detail','') or '').strip()}"
        )
    return "\n".join(lines) if lines else "_(no findings)_"


ORCH_CHAIN = "cto,architect-pre,spec,ui-spec,decompose,explore,implement,integrate,gate,architect-final"


def persist_chain(a, r, run_dir, findings_dir):
    """Persist the CUSTOM-CHAIN return shape (T5c) — an ordered, heterogeneous step list.

    A custom chain (`/chain a,b,c`) runs an operator-supplied agent sequence. Unlike nimble
    (fixed keys: exploreMap/implementation/review/conformance) the chain's steps are arbitrary,
    so we write one findings file per step from the ordered `steps[]` array. The thin manifest
    records track="chain" with the step labels as the chain (each agent = one step), so /resume's
    single-chain `next` walks it unchanged.

    Knowledge artifacts written under {run_dir}:
        findings/{NN}-{agent}.md   (one per chain step — text for think/implement, verdict+findings for gate)
        run-log.md
        manifest.json              (thin manifest, track="chain"; steps = the agent labels)
    """
    written = []
    steps = r.get("steps") or []
    if not isinstance(steps, list):
        steps = []

    # which step labels carried a surface-worthy (criterion) finding -> their manifest step is blocked
    crit_f = r.get("criterionFindings") or []
    all_f = (r.get("allFindings") or []) + [f for f in (r.get("warnFindings") or []) if f not in (r.get("allFindings") or [])]  # ADR-086 D4: WARN-class entries ride the payload
    blocked_labels = {f.get("step") for f in crit_f if isinstance(f, dict) and f.get("step")}
    surface = bool(r.get("surfaceRequired"))

    # --- one findings file per chain step (in order) ---
    labels = []
    for i, s in enumerate(steps, 1):
        if not isinstance(s, dict):
            continue
        label = s.get("label") or f"{i:02d}-step"
        labels.append(label)
        role = s.get("role", "?")
        agent_name = s.get("agent", "?")
        p = os.path.join(findings_dir, f"{label}.md")
        if role == "gate":
            verdict = s.get("verdict") or "—"
            _w(p, f"# {label} — {agent_name} (gate)\n\nROLE: gate\nVERDICT: {verdict}\n\n"
                  f"{(s.get('summary', '') or '').strip()}\n\n## Findings\n{_findings_block(s)}\n")
        else:
            _w(p, f"# {label} — {agent_name} ({role})\n\nROLE: {role}\n\n"
                  f"_Persisted by the orchestrator from the workflow return (FLAG-1: scripts have no FS "
                  f"access; read-only agents cannot Write)._\n\n{str(s.get('text', '') or '').strip()}\n")
        written.append(p)

    # run status: a chain surfaces or it completes (criterion findings drive the surface; a null
    # implement/gate step is recorded as a criterion finding by chain.js, so it surfaces here too).
    run_status = "surfaced" if surface else "complete"

    # --- run-log.md ---
    seq = " → ".join(f"{s.get('agent', '?')}:{s.get('role', '?')}" for s in steps if isinstance(s, dict))
    input_source = getattr(a, "_input_source", "workflow-return")
    input_source_label = (
        "journal-fallback (native CC transcript)"
        if input_source == "journal-fallback" else "workflow-return"
    )
    runlog = [
        "# Run log — custom chain (Workflow engine)\n",
        f"**Slug:** {a.slug or os.path.basename(run_dir.rstrip('/'))} · **Track:** chain · **Persisted:** {_now()}\n",
        f"**Input source:** {input_source_label}\n",
        f"## Task\n\n{a.task or '_(see prompt.md)_'}\n",
        "## Chain (operator-supplied)\n",
        f"`{seq or '(empty)'}`\n",
        "_A custom chain runs the operator's ordered agent list under the shared autonomy contract "
        "(ADR-036 consolidated surface). Roles: think (free-form analysis) · implement (in-place) · "
        "gate (schema-forced findings)._\n",
        "## Steps\n",
    ]
    for s in steps:
        if not isinstance(s, dict):
            continue
        label = s.get("label", "?")
        if s.get("role") == "gate":
            extra = f"verdict={s.get('verdict') or '—'}"
        else:
            extra = "ok" if s.get("text") else "null-return"
        runlog.append(f"- **{label}** [{s.get('role', '?')}] {s.get('agent', '?')} — {extra}"
                      + ("  ⚠ surfaced" if label in blocked_labels else ""))
    runlog += [
        "\n## Outcome\n",
        f"- steps: {len([s for s in steps if isinstance(s, dict)])}",
        f"- findings: {len(all_f)} total, {len(crit_f)} criterion-matched (surface-worthy)",
        f"- surface required: **{surface}** → run status: **{run_status}**",
        "\n## Knowledge-artifact note\n",
        "All findings + this log were persisted by the orchestrator from the workflow's structured "
        "return (FLAG-1: scripts have no FS access; read-only agents cannot Write). Any implement-role "
        "step authored its deliverable directly in the working tree.\n",
    ]
    _w(os.path.join(run_dir, "run-log.md"), "\n".join(runlog))
    written.append(os.path.join(run_dir, "run-log.md"))

    # --- thin manifest (track=chain; steps = the agent labels) ---
    if not a.no_manifest:
        man = os.path.join(run_dir, "manifest.json")
        slug = a.slug or os.path.basename(run_dir.rstrip("/"))
        chain = ",".join(labels) or "chain"
        rm = [sys.executable, os.path.join(SCRIPT_DIR, "run-manifest.py")]
        if not os.path.isfile(man):
            subprocess.run(rm + ["init", "--run-dir", run_dir, "--slug", slug,
                                 "--track", "chain", "--chain", chain], check=True,
                           stdout=subprocess.DEVNULL)
        for label in labels:
            if label in blocked_labels:
                st, note = "blocked", "criterion finding(s) — surfaced"
            else:
                st, note = "complete", None
            args = rm + ["set-step", man, label, st]
            if note:
                args += ["--note", note]
            subprocess.run(args, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(rm + ["set-status", man, run_status], check=True, stdout=subprocess.DEVNULL)
        written.append(man)

    _notable = compute_notable(written)
    _write_notable_to_memory(_notable, _repo_root())  # AMS-T2 seam (off-by-default, fail-open)
    return {"written": written, "notable": _notable, "track": "chain",
            "run_status": run_status, "surface_required": surface, "steps": len(labels)}


def persist_orchestrated(a, r, run_dir, findings_dir):
    """Persist the ORCHESTRATED return shape (T5b) — multi-ticket.

    Knowledge artifacts written under {run_dir}:
        cto-evaluation.md, adr.md (the pre-pass ADR — FLAG-1), spec.md,
        ui-spec-addendum.md (if UI), findings/explore-{i}.md,
        findings/implementer-{key}.md (one per ticket), findings/integrate.md,
        findings/code-reviewer.md, findings/spec-conformance.md,
        findings/{contextual}.md, findings/architect-review-final.md,
        run-log.md, manifest.json (thin manifest WITH tickets[]).
    """
    written = []

    def doc(name, body):
        p = os.path.join(run_dir, name)
        _w(p, body)
        written.append(p)

    # --- front-half knowledge artifacts (orchestrator persists; FLAG-1) ---
    cto = r.get("cto")
    if isinstance(cto, dict):
        body = cto.get("evaluation_markdown") or cto.get("rationale") or ""
        doc("cto-evaluation.md",
            f"# CTO evaluation\n\nRECOMMENDATION: {cto.get('recommendation','?')}\n\n{body.strip()}\n")
    arch_pre = r.get("archPre")
    if isinstance(arch_pre, dict) and arch_pre.get("adr_markdown"):
        # the ADR the pre-pass authored — the highest-value knowledge artifact (D4 pass 1)
        doc("adr.md", arch_pre["adr_markdown"].strip() + "\n")
    # AMS-T7 (ADR-099 Mechanism B): the wave-start recall block the engine returned in
    # payload.recalledFacts (script returns, orchestrator persists — ADR-039 contract 2). Written ONCE
    # per wave, BEFORE the first ticket dispatches, so every downstream agent inherits it passively via
    # the run folder (AC-002). ALWAYS written when the key is present (even empty — the off-by-default /
    # cold-start fail-open state is an empty file, not a missing one). It is a scratch run artifact
    # (regenerable, per-run) and is excluded from compute_notable() via the "recalled-facts" substring
    # above (AC-014) — never surfaced to the operator.
    recalled = r.get("recalledFacts")
    if isinstance(recalled, str):
        framed = recalled.strip()
        body = (
            "# Recalled long-term memory (Graphiti) — wave-level, may be stale\n\n"
            "_Recalled once at wave start (ADR-099 Mechanism B); inherited passively by every ticket/agent. "
            "Recalled facts MAY be stale — verify load-bearing facts against the source._\n\n"
        )
        body += (framed + "\n") if framed else "_(no recalled facts — disabled, empty graph, or cold-start; fail-open)_\n"
        doc("recalled-facts.md", body)
    spec = r.get("spec")
    if isinstance(spec, dict) and spec.get("spec_markdown"):
        doc("spec.md", spec["spec_markdown"].strip() + "\n")
    ui = r.get("uiSpec")
    if isinstance(ui, dict) and ui.get("ui_spec_markdown"):
        doc("ui-spec-addendum.md", ui["ui_spec_markdown"].strip() + "\n")

    # --- explore findings ---
    explore = r.get("exploreMap") or []
    if isinstance(explore, str):
        explore = [explore]
    for i, b in enumerate(explore, 1):
        p = os.path.join(findings_dir, f"explore-{i}.md")
        _w(p, f"# Explore findings {i}\n\n_Persisted by the orchestrator from the workflow return._\n\n{str(b).strip()}\n")
        written.append(p)

    # --- per-ticket implementer reports ---
    impl = r.get("implementResults") or []
    for t in impl:
        if not isinstance(t, dict):
            continue
        key = t.get("ticket_key", "T-?")
        p = os.path.join(findings_dir, f"implementer-{key}.md")
        _w(p, f"# Implementer — {key}\n\nSTATUS: {t.get('status','?')}\nSHA: {t.get('sha','') or '—'}\n"
              f"FILES: {', '.join(t.get('files_changed') or []) or '—'}\n\n{str(t.get('report','')).strip()}\n")
        written.append(p)

    # --- integration ---
    integ = r.get("integrate")
    if isinstance(integ, dict):
        p = os.path.join(findings_dir, "integrate.md")
        _w(p, f"# Integration\n\nSTATUS: {integ.get('status','?')}\nINTEGRATED_HEAD: {integ.get('integrated_head','') or '—'}\n"
              f"MERGED: {', '.join(integ.get('merged') or []) or '—'}\nSTALE: {', '.join(integ.get('stale') or []) or '—'}\n\n"
              f"{str(integ.get('report','')).strip()}\n")
        written.append(p)

    # --- gate agents over the integrated diff ---
    review = r.get("review")
    if isinstance(review, dict):
        p = os.path.join(findings_dir, "code-reviewer.md")
        _w(p, f"# code-reviewer (integrated wave)\n\nVERDICT: {review.get('verdict','?')}\n\n"
              f"{(review.get('summary','') or '').strip()}\n\n## Findings\n{_findings_block(review)}\n")
        written.append(p)
    conf = r.get("conformance")
    if isinstance(conf, dict):
        p = os.path.join(findings_dir, "spec-conformance.md")
        _w(p, f"# spec-conformance (integrated wave)\n\nVERDICT: {conf.get('verdict','?')}\n\n"
              f"{(conf.get('summary','') or '').strip()}\n\n## Findings\n{_findings_block(conf)}\n")
        written.append(p)
    for c in (r.get("contextualReviews") or []):
        if not isinstance(c, dict):
            continue
        res = c.get("result")
        if not isinstance(res, dict):
            continue
        name = c.get("type") or "contextual-review"
        p = os.path.join(findings_dir, f"{name}.md")
        _w(p, f"# {name} (integrated wave)\n\nVERDICT: {res.get('verdict','?')}\n\n"
              f"{(res.get('summary','') or '').strip()}\n\n## Findings\n{_findings_block(res)}\n")
        written.append(p)
    arch_final = r.get("archFinal")
    if isinstance(arch_final, dict):
        p = os.path.join(findings_dir, "architect-review-final.md")
        _w(p, f"# architect-review (final / integration pass — D4)\n\nVERDICT: {arch_final.get('verdict','?')}\n\n"
              f"{(arch_final.get('summary','') or '').strip()}\n\n## Findings\n{_findings_block(arch_final)}\n")
        written.append(p)

    # --- derive ticket statuses + run status ---
    tickets = r.get("tickets") or []
    impl_by_key = {t.get("ticket_key"): t for t in impl if isinstance(t, dict)}
    merged = set((integ or {}).get("merged") or []) if isinstance(integ, dict) else set()
    stale = set((integ or {}).get("stale") or []) if isinstance(integ, dict) else set()
    surface = bool(r.get("surfaceRequired"))
    crit_f = r.get("criterionFindings") or []
    all_f = (r.get("allFindings") or []) + [f for f in (r.get("warnFindings") or []) if f not in (r.get("allFindings") or [])]  # ADR-086 D4: WARN-class entries ride the payload

    ticket_specs = []
    for t in tickets:
        if not isinstance(t, dict):
            continue
        key = t.get("key", "T-?")
        ir = impl_by_key.get(key)
        if key in merged:
            st, sha = "complete", (ir.get("sha") if ir else None)
        elif key in stale:
            st, sha = "blocked", (ir.get("sha") if ir else None)
        elif ir and ir.get("status") == "complete":
            # implemented but not (yet) integrated — pending integration
            st, sha = "pending", ir.get("sha")
        elif ir and ir.get("status") in ("refused", "blocked"):
            st, sha = "blocked", (ir.get("sha") or None)
        else:
            st, sha = "pending", None
        ticket_specs.append({
            "key": key, "status": st, "depends_on": t.get("depends_on") or [],
            "commit_sha": sha or None, "planned_files": t.get("planned_files") or [],
            "acceptance": t.get("acceptance") or [],   # W1 atom chain → manifest (ADR-103 W3/CR-001 continuity)
            "note": (ir.get("status") if ir and ir.get("status") != "complete" else None),
        })

    gate_ran = isinstance(review, dict) and isinstance(conf, dict)
    # which phases actually ran (presence-based) — drives both the chain and step statuses
    ran = {"cto": isinstance(cto, dict), "architect-pre": isinstance(arch_pre, dict),
           "spec": isinstance(spec, dict), "ui-spec": isinstance(ui, dict),
           "decompose": bool(tickets), "explore": bool(explore),
           "implement": bool(impl), "integrate": isinstance(integ, dict),
           "gate": gate_ran, "architect-final": isinstance(arch_final, dict)}
    all_tickets_complete = bool(ticket_specs) and all(t["status"] == "complete" for t in ticket_specs)
    if surface:
        run_status = "surfaced"
    elif not all_tickets_complete or not gate_ran:
        run_status = "blocked"
    else:
        run_status = "complete"

    # --- run-log.md ---
    rv = review.get("verdict", "—") if isinstance(review, dict) else "—"
    cv = conf.get("verdict", "—") if isinstance(conf, dict) else "—"
    afv = arch_final.get("verdict", "—") if isinstance(arch_final, dict) else "—"
    stopped = r.get("stoppedAt")
    ctx_names = [c.get("type") for c in (r.get("contextualReviews") or []) if isinstance(c, dict)]
    input_source = getattr(a, "_input_source", "workflow-return")
    input_source_label = (
        "journal-fallback (native CC transcript)"
        if input_source == "journal-fallback" else "workflow-return"
    )
    runlog = [
        "# Run log — orchestrated (Workflow engine)\n",
        f"**Slug:** {a.slug or os.path.basename(run_dir.rstrip('/'))} · **Track:** orchestrated · **Persisted:** {_now()}\n",
        f"**Input source:** {input_source_label}\n",
        f"## Task\n\n{a.task or '_(see prompt.md)_'}\n",
        "## Chain\n",
        "`cto → architect-pre (writes ADR) → pm-spec → [ui-spec] → [decompose] → explore → "
        "∥implement-per-ticket (worktree) → integrate (staleness-guarded) → batch-gate → architect-final`\n",
        "_Both architect passes (D4). Gate roster (D5): code-reviewer + spec-conformance"
        + (f" + {', '.join(ctx_names)}" if ctx_names else "") + "._\n",
        "## Tickets\n",
    ]
    for t in ticket_specs:
        runlog.append(f"- **{t['key']}** [{t['status']}] sha={t['commit_sha'] or '—'} "
                      f"deps={t['depends_on'] or '[]'} files={t['planned_files'] or '[]'}")
    runlog += [
        "\n## Outcome\n",
        f"- cto: **{(cto or {}).get('recommendation','—') if isinstance(cto, dict) else '—'}** · "
        f"architect-pre: **{(arch_pre or {}).get('verdict','—') if isinstance(arch_pre, dict) else '—'}**",
        f"- integration: **{(integ or {}).get('status','—') if isinstance(integ, dict) else '—'}** "
        f"({len(merged)} merged{', ' + str(len(stale)) + ' stale' if stale else ''})",
        f"- code-reviewer: **{rv}** · spec-conformance: **{cv}** · architect-final: **{afv}**",
        f"- findings: {len(all_f)} total, {len(crit_f)} criterion-matched (surface-worthy)",
        f"- surface required: **{surface}**" + (f" · stopped at: **{stopped}**" if stopped else "")
        + f" → run status: **{run_status}**",
        "\n## Knowledge-artifact note\n",
        "All artifacts persisted by the orchestrator from the workflow's structured return "
        "(FLAG-1: scripts have no FS access; read-only agents cannot Write). Deliverable CODE was "
        "authored by per-ticket implementers in worktrees and integrated into the wave branch.\n",
    ]
    _w(os.path.join(run_dir, "run-log.md"), "\n".join(runlog))
    written.append(os.path.join(run_dir, "run-log.md"))

    # --- thin manifest (chain steps + tickets[] + run status) ---
    if not a.no_manifest:
        man = os.path.join(run_dir, "manifest.json")
        slug = a.slug or os.path.basename(run_dir.rstrip("/"))
        # chain = the phases that actually ran (so a no-UI / short-circuited run has no
        # misleading 'pending' steps); fall back to the full ORCH_CHAIN if nothing ran.
        chain = ",".join([p for p in ORCH_CHAIN.split(",") if ran.get(p)]) or ORCH_CHAIN
        rm = [sys.executable, os.path.join(SCRIPT_DIR, "run-manifest.py")]
        if not os.path.isfile(man):
            subprocess.run(rm + ["init", "--run-dir", run_dir, "--slug", slug,
                                 "--track", "orchestrated", "--chain", chain], check=True,
                           stdout=subprocess.DEVNULL)
        # tickets[] (CR-009: crash-safe tmp file — never leak .tickets.tmp.json on a failed set-tickets)
        if ticket_specs:
            import tempfile
            fd, tf = tempfile.mkstemp(prefix=".tickets-", suffix=".json", dir=run_dir)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(ticket_specs, f)
                subprocess.run(rm + ["set-tickets", man, "--tickets-file", tf], check=True, stdout=subprocess.DEVNULL)
            finally:
                try:
                    os.remove(tf)
                except OSError:
                    pass
        # chain step statuses (chain already = the phases that ran)
        phases = [c.strip() for c in chain.split(",") if c.strip()]
        for ph in phases:
            if ran.get(ph):
                st = "complete"
                note = None
                if ph == "gate" and surface:
                    st, note = "blocked", f"{len(crit_f)} criterion finding(s)"
                args = rm + ["set-step", man, ph, st]
                if note:
                    args += ["--note", note]
                subprocess.run(args, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(rm + ["set-status", man, run_status], check=True, stdout=subprocess.DEVNULL)
        written.append(man)

    _notable = compute_notable(written)
    _write_notable_to_memory(_notable, _repo_root())  # AMS-T2 seam (off-by-default, fail-open)
    return {"written": written, "notable": _notable, "track": "orchestrated",
            "run_status": run_status, "surface_required": surface, "tickets": len(ticket_specs),
            "code_reviewer": rv, "spec_conformance": cv, "architect_final": afv}


def persist_roadmap(a, r, run_dir, findings_dir):
    """Persist the ROADMAP return shape (ADR-055) — the advisory planning funnel on the engine.

    roadmap.js dispatches only advisor/authoring agents and RETURNS the finalized markdown (the
    AUTHORING agent's output) — agents cannot write the canonical docs/step-3-specs file, so the orchestrator
    persists it here (FLAG-1 contract 2). This is what keeps the orchestrator light + fixes role-purity.

    Knowledge artifacts:
        findings/{name}.md          (one per r["findings"] key: research / cto-advisor / round-1-recommended-reply / …)
        {run_dir}/round-1-draft.md  (the authored draft)
        {run_dir}/locked.md         (autonomous only — the finalized content)
        docs/step-3-specs/<epic>/roadmap.md                            (Phase E, autonomous — the CANONICAL artifact)
        docs/step-3-specs/<epic>/waves/<wave>/<wave>.md (+ -prompts.md) (Phase W, autonomous — CANONICAL; schema-checked)
        manifest.json               (thin manifest, track="roadmap")

    Attended runs (r["attended"]) do NOT write the canonical file — the orchestrator presents the round
    boundary and the operator locks; only the run-folder draft + findings are written.
    """
    written = []
    rm_phase = r.get("phase")
    epic = r.get("epicSlug") or (a.slug or os.path.basename(run_dir.rstrip("/")))
    wave = r.get("waveSlug")
    attended = bool(r.get("attended"))
    surface = bool(r.get("surfaceRequired"))

    # --- findings (one file per authoring/advisor agent output) ---
    for name, body in (r.get("findings") or {}).items():
        safe = "".join(c if (c.isalnum() or c in "-_.") else "-" for c in str(name))
        p = os.path.join(findings_dir, f"{safe}.md")
        _w(p, f"# {name}\n\n_Persisted by the orchestrator from the roadmap workflow return "
              f"(FLAG-1: scripts have no FS access; agents cannot Write)._\n\n{str(body).strip()}\n")
        written.append(p)

    # --- WARN-class findings (ADR-086 D4: informational, never surface-forcing) ---
    warn_f = r.get("warnFindings") or []
    if warn_f:
        p = os.path.join(findings_dir, "warn-findings.md")
        lines = ["# WARN findings (ADR-086 — informational, no halt)\n"]
        for wf in warn_f:
            if isinstance(wf, dict):
                lines.append(f"- **{wf.get('id') or wf.get('kind') or 'WARN'}**: "
                             f"{wf.get('detail') or wf.get('title') or wf}")
            else:
                lines.append(f"- {wf}")
        _w(p, "\n".join(lines) + "\n")
        written.append(p)

    # --- the authored draft (always written to the run folder) ---
    draft_md = r.get("roadmapMarkdown") if rm_phase == "E" else (r.get("waveSpecMarkdown") or "")
    if draft_md:
        dp = os.path.join(run_dir, "round-1-draft.md")
        _w(dp, str(draft_md))
        written.append(dp)

    canonical = None
    schema_ok = None
    wave_results = []   # fan-out: [(slug, canonical_path, schema_ok)]

    def _write_wave(epic_slug, wave_slug, wave_md, prompts_md):
        """Write docs/step-3-specs/<epic>/waves/<wave>/<wave>.md (+ -prompts.md) and schema-check it.
        Returns (canonical_path, schema_ok|None)."""
        wdir = os.path.join("docs", "step-3-specs", epic_slug, "waves", wave_slug)
        cpath = os.path.join(wdir, f"{wave_slug}.md")
        _w(cpath, str(wave_md))
        written.append(cpath)
        if prompts_md and str(prompts_md).strip():
            pp = os.path.join(wdir, f"{wave_slug}-prompts.md")
            _w(pp, str(prompts_md))
            written.append(pp)
        # schema-parse sanity check (non-fatal): the '# Wave:' must parse for /orchestrated.
        ok = None
        try:
            wm = os.path.join(SCRIPT_DIR, "wave-manifest.py")
            cp = subprocess.run([sys.executable, wm, "write-from-plan", cpath, "/tmp/_roadmap_wavecheck.json"],
                                capture_output=True, text=True)
            ok = (cp.returncode == 0)
            if not ok:
                note = os.path.join(findings_dir, f"_schema-check-{wave_slug}.md")
                _w(note, f"# Wave schema check — FAILED ({wave_slug})\n\n`wave-manifest.py write-from-plan {cpath}` "
                         f"exited {cp.returncode}. The '# Wave:' schema must parse before /orchestrated can "
                         f"ingest it. Fix the spec.\n\n```\n{(cp.stderr or cp.stdout or '').strip()[:1200]}\n```\n")
                written.append(note)
        except Exception as e:  # pragma: no cover — defensive; never crash persist
            ok = None
            sys.stderr.write(f"persist-run-artifacts: roadmap schema check skipped ({wave_slug}): {e}\n")
        return cpath, ok

    if not attended and not surface and draft_md and str(draft_md).strip():
        # autonomous finalize: snapshot locked.md + write the CANONICAL artifact (paths are repo-root relative).
        _w(os.path.join(run_dir, "locked.md"), str(draft_md))
        written.append(os.path.join(run_dir, "locked.md"))
        if rm_phase == "E":
            canonical = os.path.join("docs", "step-3-specs", epic, "roadmap.md")
            _w(canonical, str(draft_md))
            written.append(canonical)
            # FAN-OUT (ADR-055 ext): a Phase E run also returns one wave spec per authored wave — persist each,
            # so one /roadmap plans the whole epic end-to-end (roadmap.md + every waves/<wave>/ folder).
            for wv in (r.get("waves") or []):
                wslug = wv.get("slug")
                wmd = wv.get("waveSpecMarkdown")
                if wslug and wmd and str(wmd).strip():
                    wc, wok = _write_wave(epic, wslug, wmd, wv.get("wavePromptsMarkdown"))
                    wave_results.append((wslug, wc, wok))
        elif rm_phase == "W" and wave:
            canonical, schema_ok = _write_wave(epic, wave, draft_md, r.get("wavePromptsMarkdown"))

    run_status = "surfaced" if (attended or surface) else "complete"

    # --- run-log.md ---
    input_source = getattr(a, "_input_source", "workflow-return")
    input_source_label = (
        "journal-fallback (native CC transcript)"
        if input_source == "journal-fallback" else "workflow-return"
    )
    runlog = [
        f"# Run log\n",
        f"**Slug:** {a.slug or os.path.basename(run_dir.rstrip('/'))} · **Track:** roadmap (Workflow engine, ADR-055) "
        f"· **Phase:** {rm_phase} · **Persisted:** {_now()}\n",
        f"**Input source:** {input_source_label}\n",
        f"## Epic / wave\n\n- epic: `{epic}`" + (f"\n- wave: `{wave}`" if wave else "") + "\n",
        "## Outcome\n",
        f"- mode: **{'attended (round boundary)' if attended else 'autonomous (finalized)'}**",
        f"- canonical artifact: {('`' + canonical + '`') if canonical else '_(not finalized — attended/surfaced)_'}",
        (f"- wave schema parses: **{schema_ok}**" if rm_phase == "W" and schema_ok is not None else ""),
        (("- fanned-out waves: " + ", ".join(
            f"`{s}` (schema {'ok' if ok else 'FAIL' if ok is False else '?'})" for (s, _c, ok) in wave_results))
         if wave_results else ""),
        f"- surface required: **{surface}** → run status: **{run_status}**",
        "\n## Knowledge-artifact note\n",
        "The roadmap draft + findings were authored by the funnel's agents and persisted by the orchestrator "
        "from the workflow's structured return (FLAG-1: scripts have no FS access; agents cannot Write). The "
        "orchestrator drove no funnel ceremony (ADR-055).\n",
    ]
    _w(os.path.join(run_dir, "run-log.md"), "\n".join([x for x in runlog if x != ""]))
    written.append(os.path.join(run_dir, "run-log.md"))

    # --- thin manifest ---
    if not a.no_manifest:
        man = os.path.join(run_dir, "manifest.json")
        slug = a.slug or os.path.basename(run_dir.rstrip("/"))
        rm = [sys.executable, os.path.join(SCRIPT_DIR, "run-manifest.py")]
        if not os.path.isfile(man):
            subprocess.run(rm + ["init", "--run-dir", run_dir, "--slug", slug,
                                 "--track", "roadmap", "--chain", "research,decompose,author,self-qa,finalize"],
                           check=True, stdout=subprocess.DEVNULL)
        subprocess.run(rm + ["set-status", man, run_status], check=True, stdout=subprocess.DEVNULL)
        written.append(man)

    _notable = compute_notable(written)
    _write_notable_to_memory(_notable, _repo_root())  # AMS-T2 seam (off-by-default, fail-open)
    return {"written": written, "notable": _notable, "track": "roadmap",
            "run_status": run_status,
            "phase": rm_phase, "canonical": canonical, "wave_schema_ok": schema_ok,
            "waves": [{"slug": s, "canonical": c, "schema_ok": ok} for (s, c, ok) in wave_results],
            "surface_required": surface}


def main():
    ap = argparse.ArgumentParser(prog="persist-run-artifacts")
    ap.add_argument("--run-dir", required=True)
    # ADR-068: --return-file is OPTIONAL now. When the file is missing, empty,
    # or does not yield a usable primary input, the journal-read fallback fires
    # deterministically (no new CLI flag — AC-019).
    ap.add_argument("--return-file", default=None, help="JSON file with the workflow return object")
    ap.add_argument("--slug", default=None)
    ap.add_argument("--task", default="")
    ap.add_argument("--chain", default="explore,implement,gate")
    ap.add_argument("--no-manifest", action="store_true")
    a = ap.parse_args()

    run_dir = a.run_dir
    if not os.path.isdir(run_dir):
        os.makedirs(run_dir, exist_ok=True)
    findings_dir = os.path.join(run_dir, "findings")
    os.makedirs(findings_dir, exist_ok=True)

    # ------------------------------------------------------------------
    # Primary input: --return-file (and, after idea-pipeline T-010 lands,
    # --workflow-output; DEFERRED — AC-025). Compose-clean with that future
    # flag: the trigger predicate evaluates the FINAL parsed `r`, regardless
    # of which CLI flag built it. Adding --workflow-output later only adds
    # another way to populate `r` before the fallback check runs.
    # ------------------------------------------------------------------
    r = None
    primary_load_error = None
    if a.return_file:
        if os.path.isfile(a.return_file):
            try:
                with open(a.return_file, encoding="utf-8") as f:
                    r = json.load(f)
            except (OSError, json.JSONDecodeError) as e:
                primary_load_error = str(e)
                r = None
        else:
            primary_load_error = f"return file not found: {a.return_file}"

    # ------------------------------------------------------------------
    # Deterministic fallback trigger (ADR-068 §1): the fallback fires when the
    # primary input is absent / empty / missing required keys. No flag.
    # ------------------------------------------------------------------
    input_source = "workflow-return"
    if r is None or not _primary_input_usable(r):
        # Journal-read fallback. Refuses-clean on permission-denied (AC-017)
        # and malformed JSONL (AC-022) — writes NOTHING on failure.
        try:
            r = _journal_synthesize_return(run_dir)
        except PermissionError as e:
            sys.stderr.write(
                f"PERSIST-RUN: error=permission-denied path={e.args[0] if e.args else '?'}\n"
            )
            sys.exit(3)
        except ValueError as e:
            # Carries `line=N: <reason>` (AC-022).
            msg = str(e)
            m = re.search(r"line=(\d+)", msg)
            line_n = m.group(1) if m else "?"
            # Best-effort: identify WHICH journal raised (the synthesize routine
            # iterates per file; we re-raise with the path embedded in the message
            # only if the caller provided it — here we record an `unknown` path
            # rather than misattribute. The tests exercise both shapes.)
            path_match = re.search(r"path=(\S+)", msg)
            path_str = path_match.group(1) if path_match else "<unknown>"
            sys.stderr.write(
                f"PERSIST-RUN: error=malformed-journal path={path_str} line={line_n}\n"
            )
            sys.exit(4)
        except FileNotFoundError as e:
            # No journal at all (no env session id, no subagents dir, no
            # within-window journals). The script writes nothing — the operator
            # gets a clear "we couldn't fall back either" message.
            sys.stderr.write(
                f"PERSIST-RUN: error=fallback-unavailable detail={e}\n"
                f"PERSIST-RUN: primary-load-error={primary_load_error or '(no --return-file given)'}\n"
            )
            sys.exit(5)
        input_source = "journal-fallback"
        # AC-020: machine-parseable line on stderr the moment the fallback fires.
        jpaths = r.get("_journal_paths") or []
        first = jpaths[0] if jpaths else "<unknown>"
        sys.stderr.write(f"PERSIST-RUN: source=journal-fallback path={first}\n")
        # Strip private bookkeeping keys before downstream persist consumes `r`.
        r.pop("_journal_paths", None)
        r.pop("_input_source", None)

    if not isinstance(r, dict):
        _die("return JSON must be an object")

    # Stash provenance on the args namespace so the nimble run-log renderer can
    # emit `Input source:` (AC-020/021). The orchestrated/chain/roadmap branches
    # have their own run-log renderers; they currently route only on a real
    # workflow-return (track field present) — so the fallback ALWAYS reaches the
    # default nimble path below and the provenance line lands there.
    a._input_source = input_source

    # T5b: orchestrated runs have a different (richer, multi-ticket) return shape. Route on the
    # explicit `track` field (CR-007); the `implementResults` heuristic is only a fallback for a
    # track-less return. The nimble single-chain path below is unchanged.
    track = r.get("track")
    if track == "orchestrated" or (track is None and "implementResults" in r):
        out = persist_orchestrated(a, r, run_dir, findings_dir)
        # SHR3-T1: terminal-completion auto-close-out (fail-open; no-op unless run_status=="complete").
        _auto_closeout(run_dir, out.get("run_status"))
        print(json.dumps(out, indent=2))
        return
    # T5c: custom-chain runs have an ordered, heterogeneous `steps[]` shape. Route on the explicit
    # `track` field (the `steps` heuristic is a fallback for a track-less return). Nimble below is unchanged.
    if track == "chain" or (track is None and "steps" in r and "agents" in r):
        out = persist_chain(a, r, run_dir, findings_dir)
        _auto_closeout(run_dir, out.get("run_status"))  # SHR3-T1 terminal-completion close-out
        print(json.dumps(out, indent=2))
        return
    # ADR-055: roadmap runs as a Workflow script; its return carries authored markdown the orchestrator
    # persists (incl. the canonical docs/step-3-specs artifact). Route on the explicit track.
    if track == "roadmap" or (track is None and ("roadmapMarkdown" in r or "waveSpecMarkdown" in r)):
        out = persist_roadmap(a, r, run_dir, findings_dir)
        _auto_closeout(run_dir, out.get("run_status"))  # SHR3-T1 terminal-completion close-out
        print(json.dumps(out, indent=2))
        return

    written = []

    # --- explore findings (one file per agent output) ---
    explore = r.get("exploreMap") or []
    if isinstance(explore, str):
        explore = [explore]
    for i, body in enumerate(explore, 1):
        p = os.path.join(findings_dir, f"explore-{i}.md")
        _w(p, f"# Explore findings {i}\n\n_Persisted by the orchestrator from the workflow return "
              f"(scripts have no FS access; Explore agents cannot Write)._\n\n{str(body).strip()}\n")
        written.append(p)

    # --- implementer COMPLETION_REPORT ---
    if r.get("implementation"):
        p = os.path.join(findings_dir, "implementer.md")
        _w(p, f"# Implementer COMPLETION_REPORT\n\n{str(r['implementation']).strip()}\n")
        written.append(p)

    # --- integration (ADR-046: nimble implements in a worktree, then integrates) ---
    integ = r.get("integrate")
    if isinstance(integ, dict):
        p = os.path.join(findings_dir, "integrate.md")
        _w(p, f"# Integration\n\nSTATUS: {integ.get('status','?')}\n"
              f"INTEGRATED_HEAD: {integ.get('integrated_head','') or '—'}\n"
              f"BASE_SHA: {integ.get('base_sha','') or '—'}\n\n"
              f"{(integ.get('report','') or '').strip()}\n")
        written.append(p)

    # --- gate agents ---
    review = r.get("review")
    if isinstance(review, dict):
        p = os.path.join(findings_dir, "code-reviewer.md")
        _w(p, f"# code-reviewer\n\nVERDICT: {review.get('verdict','?')}\n\n"
              f"{(review.get('summary','') or '').strip()}\n\n## Findings\n{_findings_block(review)}\n")
        written.append(p)
    conf = r.get("conformance")
    if isinstance(conf, dict):
        p = os.path.join(findings_dir, "spec-conformance.md")
        _w(p, f"# spec-conformance\n\nVERDICT: {conf.get('verdict','?')}\n\n"
              f"{(conf.get('summary','') or '').strip()}\n\n## Findings\n{_findings_block(conf)}\n")
        written.append(p)
    # CR-001: persist the optional contextual gate (ui-review / db-migration-reviewer /
    # security-auditor) — its findings must NOT be silently dropped (audit trail; crit-3).
    ctx = r.get("contextualReview")
    if isinstance(ctx, dict):
        name = r.get("contextualType") or "contextual-review"
        p = os.path.join(findings_dir, f"{name}.md")
        _w(p, f"# {name}\n\nVERDICT: {ctx.get('verdict','?')}\n\n"
              f"{(ctx.get('summary','') or '').strip()}\n\n## Findings\n{_findings_block(ctx)}\n")
        written.append(p)

    # --- run-log.md ---
    all_f = (r.get("allFindings") or []) + [f for f in (r.get("warnFindings") or []) if f not in (r.get("allFindings") or [])]  # ADR-086 D4: WARN-class entries ride the payload
    crit_f = r.get("criterionFindings") or []
    surface = bool(r.get("surfaceRequired"))
    rv = (review or {}).get("verdict", "—") if isinstance(review, dict) else "—"
    cv = (conf or {}).get("verdict", "—") if isinstance(conf, dict) else "—"
    # CR-002: both mandatory gate agents must have returned. If either died (null),
    # the gate did NOT clean-pass — block rather than silently marking complete.
    gate_complete = isinstance(review, dict) and isinstance(conf, dict)
    if surface:
        run_status = "surfaced"
    elif not gate_complete:
        run_status = "blocked"
    else:
        run_status = "complete"
    # ADR-068 provenance line: ALWAYS records which input source produced the
    # persisted artifacts. AC-020 (fallback-fired) / AC-021 (happy path).
    input_source = getattr(a, "_input_source", "workflow-return")
    input_source_label = (
        "journal-fallback (native CC transcript)"
        if input_source == "journal-fallback" else "workflow-return"
    )
    runlog = [
        f"# Run log\n",
        f"**Slug:** {a.slug or os.path.basename(run_dir.rstrip('/'))} · **Track:** nimble (Workflow engine) · **Persisted:** {_now()}\n",
        f"## Task\n\n{a.task or '_(see prompt.md)_'}\n",
        "## Chain\n",
        f"`{a.chain}` — explore ∥ → implement → batch-gate (code-reviewer ∥ spec-conformance) → consolidated-surface\n",
        "## Outcome\n",
        f"- Input source: {input_source_label}",
        f"- code-reviewer: **{rv}**",
        f"- spec-conformance: **{cv}**",
        f"- findings: {len(all_f)} total, {len(crit_f)} criterion-matched (surface-worthy)",
        f"- surface required: **{surface}** → run status: **{run_status}**",
        f"- agents: {len(explore)} explore + implementer + "
        + " ".join([n for n, present in [
            ("code-reviewer", isinstance(review, dict)),
            ("spec-conformance", isinstance(conf, dict)),
            (r.get("contextualType") or "contextual", isinstance(r.get("contextualReview"), dict)),
        ] if present]),
        "\n## Artifacts\n",
        "`prompt.md` · `spec.md` (if authored) · `findings/*` · `run-log.md` · `manifest.json`\n",
        "## Knowledge-artifact note\n",
        "All findings + this log were persisted by the orchestrator "
        + ("from the native CC per-agent journal as the fallback INPUT source (ADR-068; the structured "
           "Workflow return was absent/empty — the journal is the RUNTIME's; persist READS, the Workflow "
           "script NEVER writes one)." if input_source == "journal-fallback"
           else "from the workflow's structured return (FLAG-1 contract: scripts have no FS access; "
                "Explore cannot Write).") + "\n",
    ]
    _w(os.path.join(run_dir, "run-log.md"), "\n".join(runlog))
    written.append(os.path.join(run_dir, "run-log.md"))

    # --- thin manifest (steps -> complete, run status) ---
    if not a.no_manifest:
        man = os.path.join(run_dir, "manifest.json")
        slug = a.slug or os.path.basename(run_dir.rstrip("/"))
        rm = [sys.executable, os.path.join(SCRIPT_DIR, "run-manifest.py")]
        if not os.path.isfile(man):
            subprocess.run(rm + ["init", "--run-dir", run_dir, "--slug", slug,
                                 "--track", "nimble", "--chain", a.chain], check=True,
                           stdout=subprocess.DEVNULL)
        # mark steps: explore/implement complete; gate blocked if surfaced or a gate agent died
        for phase in [c.strip() for c in a.chain.split(",") if c.strip()]:
            st = "complete"
            note = None
            if phase == "gate":
                if surface:
                    st, note = "blocked", f"{len(crit_f)} criterion finding(s)"
                elif not gate_complete:
                    st, note = "blocked", "gate agent(s) returned null (died) — re-run required"
                else:
                    note = f"{rv}+{cv}"
            args = rm + ["set-step", man, phase, st]
            if note:
                args += ["--note", note]
            subprocess.run(args, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(rm + ["set-status", man, run_status], check=True, stdout=subprocess.DEVNULL)
        written.append(man)

    _notable = compute_notable(written)
    _write_notable_to_memory(_notable, _repo_root())  # AMS-T2 seam (off-by-default, fail-open)
    # SHR3-T1: terminal-completion auto-close-out (fail-open; no-op unless run_status=="complete").
    _auto_closeout(run_dir, run_status)
    print(json.dumps({"written": written, "notable": _notable,
                      "run_status": run_status,
                      "surface_required": surface, "review": rv, "conformance": cv}, indent=2))


if __name__ == "__main__":
    main()
