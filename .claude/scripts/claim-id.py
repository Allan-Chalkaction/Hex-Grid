#!/usr/bin/env python3
"""claim-id.py — collision-safe allocation primitive (ADR-072).

Single allocator for ADR numbers, run folders, and arbitrary paths, using POSIX atomic
primitives (`O_CREAT|O_EXCL` for files, `mkdir(2)` for directories — both fail closed on a
losing race). Replaces the "scan-max-then-write" pattern that produced the ADR-061 collision
(two concurrent sessions both compute next=N, both write `ADR-NNN-*.md` — last writer wins
and one ADR's content vanishes).

The key insight: ANY read-then-write number allocation race-loses. The fix is *claim-first*:
attempt to create the target atomically, on failure (someone else won the race) bump and
retry. There is no shared state to corrupt — the FS itself is the lock.

Subcommands:

    adr  <slug>                   atomically claim the next free `ADR-NNN-<slug>.md`
    run  <KIND> <slug>            atomically claim a run folder
                                  `docs/step-5-pipeline/<date>/<HHmm>-<KIND>-<slug>/`
    path <target>                 generic O_EXCL claim of an arbitrary file path

Each subcommand prints a parseable final-line summary
(`CLAIM-ADR: number=NNN path=...` / `CLAIM-RUN: path=...` /
`CLAIM-PATH: path=...` or `CLAIM-PATH: FAILED path=...`). Exit 0 on success; non-zero on
validation error or lost race (`path` subcommand only — `adr`/`run` retry on collision).

Safety invariants (the script enforces these structurally, not by convention):
    - Slug and KIND inputs are validated against a strict regex BEFORE interpolation: no
      path separators, no `..`, no leading `-`, no NUL or newline, non-empty, kebab.
    - All target paths are resolved (without following symlinks at the leaf) and asserted
      to live within the intended parent dir — defeats `slug=../../etc/passwd` traversal.
    - `os.O_EXCL` defeats the symlink-swap attack: if `target` is a pre-existing symlink,
      open() with O_EXCL fails rather than following the link.
    - `os.mkdir` (NOT `exist_ok=True`) fails on collision so a losing race is observable.
    - subprocess is not invoked. No `shell=True`. Stdlib only.

Out of scope (ADR-072 follow-ons — separate work):
    - PostToolUse hook that catches an Edit/Write that "moves" a freshly-claimed ADR to
      a different number (the human/agent rename-back-in error path).
    - Refactoring every existing `os.makedirs(exist_ok=True)` call site to use this.
    - Cross-machine / distributed locking.
    - A stale-stub `--gc` sweep for never-completed `adr` claims.
"""
import argparse
import datetime
import os
import re
import sys

# Slug / KIND validation — single source of truth. Same shape as graduate-jam.py: lowercase
# alphanumerics + hyphens; must start with [a-z0-9]; no leading hyphen, no path separator,
# no `..`, no NUL/newline. Bounded length so an attacker cannot push a hostile path past
# PATH_MAX through us.
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")
# KIND tokens used in run-folder names. The substrate uses uppercase ASCII tags
# (NIMBLE, WAVE, CHAIN, ROADMAP, PLANNER, AUDIT, …). Match graduate-jam.py's bounded length.
KIND_RE = re.compile(r"^[A-Z][A-Z0-9-]{0,31}$")
# ADR file pattern — must match adr-index.py (ADR-NNN[-slug].md, NNN is 2-4 digits).
ADR_FILE_RE = re.compile(r"^ADR-(\d{2,4})(?:-(.+))?\.md$")
# ADR number-lock pattern. The .lock file is the slug-independent claim sentinel that
# serializes concurrent `adr` claims (see cmd_adr docstring).
ADR_LOCK_RE = re.compile(r"^ADR-(\d{2,4})\.lock$")
# Run-folder date/time formats (validated so a poisoned --date can't traverse out of the
# pipeline parent — SA-002). YYYY-MM-DD and HHmm.
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
HHMM_RE = re.compile(r"^\d{4}$")
# Bounded retry on collision — a session in a pathological race storm should fail loud
# rather than spin forever. 1000 is well above any realistic concurrent-claim count.
MAX_CLAIM_ATTEMPTS = 1000


def _die(msg, code=2):
    sys.stderr.write(f"claim-id: {msg}\n")
    sys.exit(code)


def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sanitize_marker_value(s, max_len=128):
    """Strip NUL/CR/newline and clamp length. The ownership marker is structured key-value
    (`claimed-by: <session> at <iso>`); a value MUST NOT span lines or terminate the line
    early, or a crafted session id could forge a second `claimed-by:` line / close an HTML
    comment and inject content (SA-001). This is the integrity substrate the planned
    ownership-enforcement hook will trust, so sanitize at the single chokepoint."""
    if s is None:
        return "unknown"
    s = str(s).replace("\x00", "").replace("\r", " ").replace("\n", " ")
    return s[:max_len] or "unknown"


def _session_id(override):
    """Resolve the session id. Order: --session-id flag, then $CLAUDE_CODE_SESSION_ID, else
    'unknown'. Sanitized for marker safety (SA-001). Used only for the in-file ownership
    marker — advisory, but load-bearing for the ownership hook follow-on."""
    raw = override if override else os.environ.get("CLAUDE_CODE_SESSION_ID", "unknown")
    return _sanitize_marker_value(raw)


def _validate_slug(slug):
    """Reject anything the regex doesn't accept. Reject explicit traversal substrings before
    the regex check so the error message is precise."""
    if slug is None or slug == "":
        _die("slug must be non-empty")
    if "\x00" in slug or "\n" in slug or "\r" in slug:
        _die("slug must not contain NUL or newline")
    if slug.startswith("-"):
        _die(f"slug must not start with '-': {slug!r}")
    if ".." in slug:
        _die(f"slug must not contain '..': {slug!r}")
    if "/" in slug or "\\" in slug:
        _die(f"slug must not contain a path separator: {slug!r}")
    if not SLUG_RE.match(slug):
        _die(f"invalid slug (must be kebab, ≤80 chars): {slug!r}")
    return slug


def _validate_kind(kind):
    """Strict uppercase kebab — KIND is a folder-name component, same anti-traversal rules."""
    if kind is None or kind == "":
        _die("kind must be non-empty")
    if "\x00" in kind or "\n" in kind or "\r" in kind:
        _die("kind must not contain NUL or newline")
    if kind.startswith("-"):
        _die(f"kind must not start with '-': {kind!r}")
    if ".." in kind:
        _die(f"kind must not contain '..': {kind!r}")
    if "/" in kind or "\\" in kind:
        _die(f"kind must not contain a path separator: {kind!r}")
    if not KIND_RE.match(kind):
        _die(f"invalid kind (must be UPPERCASE-KEBAB, ≤32 chars): {kind!r}")
    return kind


def _assert_within(target, parent):
    """Assert `target` lives inside `parent` after symlink-resolving the parent. We
    canonicalize the parent ONCE via realpath (so macOS `/var/folders/...` ↔ `/private/var/...`
    or any other symlinked parent agrees with itself), then compare the dirname of the
    canonicalized target against the canonicalized parent. The leaf basename is NEVER
    resolved (we are about to create it via O_EXCL/mkdir, so no pre-existing symlink can
    sit there). Defense-in-depth against a future caller passing a crafted slug that somehow
    slips the regex."""
    parent_real = os.path.realpath(parent)
    # Resolve the dirname of the target (the part that already exists on disk) but keep
    # the basename literal. This canonicalizes any symlinks in the parent chain without
    # following a leaf symlink swap.
    target_dir_real = os.path.realpath(os.path.dirname(target) or ".")
    leaf = os.path.basename(target)
    target_abs = os.path.join(target_dir_real, leaf) if leaf else target_dir_real
    if not (target_abs == parent_real or target_abs.startswith(parent_real + os.sep)):
        _die(f"path escapes parent dir: {target_abs} not under {parent_real}")
    return target_abs


def _max_existing_adr_number(adr_dir):
    """Scan adr_dir for ADR-NNN-*.md files and return the max NNN. Returns 0 if none."""
    if not os.path.isdir(adr_dir):
        _die(f"adr dir does not exist: {adr_dir}")
    max_num = 0
    for fname in os.listdir(adr_dir):
        m = ADR_FILE_RE.match(fname)
        if m:
            try:
                n = int(m.group(1))
                if n > max_num:
                    max_num = n
            except ValueError:
                continue
    return max_num


def _max_existing_adr_number_or_lock(adr_dir):
    """Like `_max_existing_adr_number` but ALSO considers `ADR-NNN.lock` files. The lock
    is a reservation; an unfinished claim (or one in flight) reserves the number even
    before the slug-stamped .md file lands. Returns 0 if neither exist."""
    if not os.path.isdir(adr_dir):
        _die(f"adr dir does not exist: {adr_dir}")
    max_num = 0
    for fname in os.listdir(adr_dir):
        m = ADR_FILE_RE.match(fname) or ADR_LOCK_RE.match(fname)
        if m:
            try:
                n = int(m.group(1))
                if n > max_num:
                    max_num = n
            except ValueError:
                continue
    return max_num


def _stub_body(num, slug, session_id, when):
    """The minimal ADR stub written on claim. First line is the ownership marker (an HTML
    comment so it renders invisibly in the markdown but stays grep-friendly). The body is
    intentionally tiny — the human/agent fills it in immediately after; the stub exists
    only to claim the number atomically."""
    title_slug = slug.replace("-", " ").strip() or "claimed"
    return (
        f"<!-- claimed-by: {session_id} at {when} -->\n"
        f"# ADR-{num:03d} — {title_slug}\n\n"
        f"**Status:** Proposed\n"
        f"**Date:** {when[:10]}\n\n"
        f"## Context\n\n"
        f"_(stub claimed by `core/scripts/claim-id.py adr {slug}` "
        f"at {when}. Fill in the decision body now — this stub MUST be overwritten "
        f"with the real ADR content. ADR-072 is the binding contract for the claim.)_\n"
    )


def _excl_create(path, content_bytes):
    """Atomically create `path` for exclusive write. Returns True on success, False on
    `FileExistsError` (lost the race). Uses O_EXCL which fails closed if the path already
    exists OR is a dangling symlink — defeats both prior-file and symlink-swap attacks.
    Permissions 0o644 (rw-r--r--) — typical for substrate-written docs/scripts.
    `os.umask` may further restrict; that's the operator's prerogative."""
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except FileExistsError:
        return False
    except OSError as e:
        # ENAMETOOLONG / ELOOP / EACCES / ENOSPC / EROFS / ENOTDIR — fail with the
        # script's error contract rather than dumping a traceback (SA-003).
        _die(f"could not create {path}: {e}")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(content_bytes)
    except Exception:
        # Best-effort cleanup if write fails partway. The O_EXCL guarantee is the
        # claim is ours; if we cannot complete, remove the empty file so a retry can win.
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    return True


# --- adr -------------------------------------------------------------------

def cmd_adr(args):
    """Atomically claim the next free ADR number.

    The naive approach — O_EXCL on `ADR-NNN-<slug>.md` — race-loses when concurrent claims
    use DIFFERENT slugs (each filename is unique, so O_EXCL succeeds for BOTH, and both win
    the same NNN). The fix: claim the NUMBER first via a slug-independent sentinel
    `ADR-NNN.lock`, then write the slug-stamped ADR file under that protection. Two
    concurrent claims targeting the same NNN race on the SAME `.lock` filename — one wins,
    one bumps.

    The `.lock` is left in place as the number-reservation record (it is the proof the
    number is taken). Cleanup is out of scope (ADR-072 follow-on `--gc`)."""
    slug = _validate_slug(args.slug)
    adr_dir = args.dir or os.path.join("docs", "decisions")
    if not os.path.isdir(adr_dir):
        _die(f"adr dir does not exist: {adr_dir}")

    session_id = _session_id(args.session_id)
    when = _now_iso()
    num = _max_existing_adr_number_or_lock(adr_dir) + 1

    for attempt in range(MAX_CLAIM_ATTEMPTS):
        # Step 1: claim the number via a slug-independent lock file. O_EXCL on this name
        # is what serializes concurrent claims across DIFFERENT slugs.
        lock_name = f"ADR-{num:03d}.lock"
        lock_path = os.path.join(adr_dir, lock_name)
        _assert_within(lock_path, adr_dir)
        lock_body = (f"claimed-by: {session_id}\nclaimed_at: {when}\nslug: {slug}\n"
                     f"# This lock reserves ADR-{num:03d}. Created by core/scripts/claim-id.py "
                     f"(ADR-072). Remove only after the claimed ADR file is in place.\n").encode("utf-8")
        if not _excl_create(lock_path, lock_body):
            # Lost the race on this number. Bump past anything that's now visible.
            num = max(num + 1, _max_existing_adr_number_or_lock(adr_dir) + 1)
            continue

        # Step 2: with the number locked, write the slug-stamped ADR file. The lock holds
        # the number even if a sibling concurrent claim is also using this same slug
        # (which would normally let O_EXCL pick a winner anyway — but the lock is the
        # truth source).
        candidate = f"ADR-{num:03d}-{slug}.md"
        target = os.path.join(adr_dir, candidate)
        _assert_within(target, adr_dir)
        body = _stub_body(num, slug, session_id, when).encode("utf-8")
        if not _excl_create(target, body):
            # Vanishingly unlikely (we just acquired the number's lock) but possible if
            # the operator hand-created an ADR with this exact name between the lock
            # acquisition and now. Treat as a lost race: leave the lock as a tombstone
            # for that number, bump, retry.
            num = max(num + 1, _max_existing_adr_number_or_lock(adr_dir) + 1)
            continue

        print(f"CLAIM-ADR: number={num:03d} path={target}")
        return

    _die(f"could not claim an ADR number after {MAX_CLAIM_ATTEMPTS} attempts (slug={slug!r})")


# --- run -------------------------------------------------------------------

def _today_date():
    return datetime.date.today().isoformat()


def _now_hhmm():
    return datetime.datetime.now().strftime("%H%M")


def cmd_run(args):
    kind = _validate_kind(args.kind)
    slug = _validate_slug(args.slug)
    date = args.date or _today_date()
    hhmm = args.time or _now_hhmm()
    # Validate date/time so a poisoned --date (e.g. '../../../escaped') can't move the
    # parent out from under the containment check (SA-002).
    if not DATE_RE.match(date):
        _die(f"date must be YYYY-MM-DD: {date!r}")
    if not HHMM_RE.match(hhmm):
        _die(f"time must be HHmm (4 digits): {hhmm!r}")
    base = args.dir or os.path.join("docs", "step-5-pipeline")
    date_dir = os.path.join(base, date)
    # Ensure the dated parent exists (this is the v2 substrate convention; mkdir with
    # exist_ok is safe here — the SHARED dir is not the claim target, the run subdir is).
    try:
        os.makedirs(date_dir, exist_ok=True)
    except OSError as e:
        _die(f"could not create dated parent {date_dir}: {e}")

    session_id = _session_id(args.session_id)
    when = _now_iso()

    base_name = f"{hhmm}-{kind}-{slug}"
    for attempt in range(MAX_CLAIM_ATTEMPTS):
        candidate = base_name if attempt == 0 else f"{base_name}-{attempt + 1}"
        target = os.path.join(date_dir, candidate)
        _assert_within(target, date_dir)
        try:
            os.mkdir(target)
        except FileExistsError:
            continue
        # Write the .owner sentinel inside the claimed dir. Best-effort — if this
        # fails we still own the dir (mkdir won), but the marker is informative.
        try:
            with open(os.path.join(target, ".owner"), "w", encoding="utf-8") as f:
                f.write(f"session_id: {session_id}\nclaimed_at: {when}\nkind: {kind}\nslug: {slug}\n")
        except OSError:
            pass
        print(f"CLAIM-RUN: path={target}")
        return

    _die(f"could not claim a run folder after {MAX_CLAIM_ATTEMPTS} attempts "
         f"(kind={kind!r}, slug={slug!r})")


# --- path -------------------------------------------------------------------

def cmd_path(args):
    target = args.target
    if target is None or target == "":
        _die("target must be non-empty")
    if "\x00" in target or "\n" in target or "\r" in target:
        _die("target must not contain NUL or newline")
    # Reject `..` ANYWHERE in the raw target before realpath — otherwise a mid-string
    # `./a/../b` poisons the very parent the containment check trusts (CR-001). The leaf
    # check below alone is insufficient.
    if ".." in target.split(os.sep):
        _die(f"target must not contain '..' path segments: {target!r}")
    # The path subcommand is generic — we cannot validate slug-shape on the leaf, but we
    # CAN enforce that the parent dir exists and that the leaf does not escape it via
    # `..`. The caller is trusted to pass a sane path; this is the escape-hatch.
    parent = os.path.dirname(target) or "."
    if not os.path.isdir(parent):
        _die(f"parent dir does not exist: {parent}")
    parent_real = os.path.realpath(parent)
    leaf = os.path.basename(target)
    if not leaf or leaf in (".", ".."):
        _die(f"target leaf must be a basename: {target!r}")
    # Canonicalize the parent (handles macOS /var ↔ /private/var) and append the literal
    # leaf — never resolve the leaf (we are about to create it via O_EXCL).
    target_abs = os.path.join(parent_real, leaf)
    if not target_abs.startswith(parent_real + os.sep):
        _die(f"target escapes parent dir: {target_abs} not under {parent_real}")

    session_id = _session_id(args.session_id)
    when = _now_iso()
    marker = f"# claimed-by: {session_id} at {when}\n".encode("utf-8")
    if _excl_create(target_abs, marker):
        print(f"CLAIM-PATH: path={target_abs}")
        return
    # Lost the race or pre-existing. `path` is a one-shot — no retry; the caller's
    # contract is "claim THIS path exactly."
    sys.stderr.write(f"claim-id: lost race or path already exists: {target_abs}\n")
    print(f"CLAIM-PATH: FAILED path={target_abs}")
    sys.exit(1)


# --- arg parsing -----------------------------------------------------------

def _build_parser():
    p = argparse.ArgumentParser(
        prog="claim-id",
        description="Collision-safe allocation primitive (ADR-072): claim ADR numbers, "
                    "run folders, or arbitrary paths atomically via POSIX O_EXCL/mkdir."
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    pa = sub.add_parser(
        "adr",
        help="atomically claim the next free ADR-NNN-<slug>.md under docs/decisions/",
        description="Scan docs/decisions/ for the max ADR-NNN, then atomically create "
                    "ADR-{max+1}-<slug>.md via O_EXCL. On collision, bump and retry "
                    "(bounded). Writes a stub with an ownership marker as the first line.")
    pa.set_defaults(fn=cmd_adr)
    pa.add_argument("slug", help="kebab-case slug (e.g. collision-safe-allocator)")
    pa.add_argument("--dir", help="override the docs/decisions/ dir (for tests)")
    pa.add_argument("--session-id",
                    help="override the session id stamped into the ownership marker "
                         "(default: $CLAUDE_CODE_SESSION_ID or 'unknown')")

    pr = sub.add_parser(
        "run",
        help="atomically claim a run folder docs/step-5-pipeline/<date>/<HHmm>-<KIND>-<slug>/",
        description="Create the run folder via os.mkdir (NOT exist_ok). On collision "
                    "(same dated dir + same HHmm), append -2, -3, … until a free name is "
                    "found (bounded). Writes a .owner sentinel inside on success.")
    pr.set_defaults(fn=cmd_run)
    pr.add_argument("kind", help="run kind (UPPERCASE: NIMBLE, WAVE, CHAIN, ROADMAP, PLANNER, AUDIT, …)")
    pr.add_argument("slug", help="kebab-case slug")
    pr.add_argument("--dir", help="override the docs/step-5-pipeline/ dir (for tests)")
    pr.add_argument("--date", help="override the date (YYYY-MM-DD, for tests)")
    pr.add_argument("--time", help="override HHmm (for tests)")
    pr.add_argument("--session-id",
                    help="override the session id stamped into .owner "
                         "(default: $CLAUDE_CODE_SESSION_ID or 'unknown')")

    pp = sub.add_parser(
        "path",
        help="generic O_EXCL claim of an arbitrary file path",
        description="Attempt to atomically create `target` via O_EXCL. On success write "
                    "an ownership marker and exit 0. On collision (lost race or "
                    "pre-existing file) exit non-zero — no retry.")
    pp.set_defaults(fn=cmd_path)
    pp.add_argument("target", help="absolute or relative path to claim exclusively")
    pp.add_argument("--session-id",
                    help="override the session id stamped into the marker "
                         "(default: $CLAUDE_CODE_SESSION_ID or 'unknown')")

    return p


def main():
    args = _build_parser().parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
