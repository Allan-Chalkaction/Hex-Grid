#!/usr/bin/env python3
"""launch-manifest.py — the thin FLEET index for /launch (T10, ADR-045-adjacent).

The cross-session, disk+git source of truth for an overnight/parallel fleet of autonomous orchestrated
runs (one per locked wave spec). A fresh session reconstructs full fleet state from this manifest + the
per-feature branches alone — NO shared session context required (T10 AC-7). It is deliberately separate
from run-manifest.py (per-TICKET, inside one wave); this indexes per-FEATURE (one wave each).

Schema `fleet-manifest/2`:
  { schema, slug, created_at, updated_at, concurrency, token_ceiling,
    features: [ {label, kind, spec, status, branch, run_dir, sha} ] }
  kind   ∈ orchestrated | nimble | chain | loop   (default orchestrated; absent in a v1 file → orchestrated)
  status ∈ queued | running | done | blocked | failed

A `fleet-manifest/1` file (no `kind` field) is read transparently — every feature defaults to
kind="orchestrated" in memory (ADR-053 multi-track build queue, back-compatible).

Subcommands:
  init   --path P --slug S [--concurrency K] [--token-ceiling N]
  add    --path P --spec SPEC [--kind K] [--label L] [--branch B]   # queue a feature (kind default orchestrated)
  set    --path P --label L --status S [--branch B] [--run-dir D] [--sha SHA]
  next   --path P                                      # concurrency-aware dispatch decision (see cmd_next)
  summary --path P                                     # status counts (fan-in review)
  read   --path P
"""
import json, os, sys, argparse, datetime

SCHEMA = "fleet-manifest/2"
STATUSES = {"queued", "running", "done", "blocked", "failed"}
KINDS = {"orchestrated", "nimble", "chain", "loop"}
# STAGE_KINDS — a SECOND, DISJOINT verb taxonomy (ADR-132 D-1). A build-kind (KINDS, above) is TERMINAL: its
# output is a merged build, archived to step-6-done/queue/. A stage-kind's output is a SPEC routed to
# step-3-specs/ — never a merged build, never archived. Build-kinds and stage-kinds are disjoint (a stage-kind
# is NEVER folded into KINDS — that would make the daemon try to BUILD it). Data-only here; the daemon routing
# that CONSUMES this set lives in core/skills/queue-chew/SKILL.md (D2). `sweep` is deliberately NOT in the set
# (Phase-1 boundary — it needs an unattended-convergence mode that does not exist yet; deferred, not lost).
STAGE_KINDS = {"roadmap"}
# kind -> branch infix; the fan-in step enumerates these (ADR-053).
_BRANCH_INFIX = {"orchestrated": "wave", "nimble": "nimble", "chain": "chain", "loop": "loop"}


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _die(msg, code=2):
    sys.stderr.write(f"launch-manifest: {msg}\n")
    sys.exit(code)


def _atomic_write(path, obj):
    obj["updated_at"] = _now()
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def _read(path):
    if not os.path.isfile(path):
        _die(f"fleet manifest not found: {path}")
    with open(path, encoding="utf-8") as fh:
        m = json.load(fh)
    # Back-compat (ADR-053): a fleet-manifest/1 file has no `kind` — default it in memory.
    for feat in m.get("features", []):
        feat.setdefault("kind", "orchestrated")
    return m


def _feat(m, label):
    for f in m["features"]:
        if f["label"] == label:
            return f
    return None


def cmd_init(a):
    # Fail LOUD on a missing/empty/whitespace --slug (AC-009 / SHR4-B2): argparse already requires the flag's
    # PRESENCE, but `--slug ""` / `--slug "  "` would otherwise write a null/empty-slug manifest that fails
    # opaquely downstream. Non-zero exit + stderr, never a silent empty-slug manifest.
    if not a.slug or not a.slug.strip():
        _die("init requires a non-empty --slug", code=2)
    m = {
        "schema": SCHEMA, "slug": a.slug, "created_at": _now(), "updated_at": _now(),
        "concurrency": a.concurrency, "token_ceiling": a.token_ceiling, "features": [],
    }
    _atomic_write(a.path, m)
    print(a.path)


def cmd_add(a):
    m = _read(a.path)
    kind = a.kind or "orchestrated"
    if kind not in KINDS:
        _die(f"invalid kind '{kind}' (expected {'|'.join(sorted(KINDS))})")
    label = a.label or os.path.splitext(os.path.basename(a.spec))[0]
    if _feat(m, label):
        _die(f"duplicate feature label '{label}'")
    branch = a.branch or f"feature/{_BRANCH_INFIX[kind]}-{label}"
    m["features"].append({
        "label": label, "kind": kind, "spec": a.spec, "status": "queued",
        "branch": branch, "run_dir": None, "sha": None,
    })
    _atomic_write(a.path, m)
    print(label)


def cmd_set(a):
    m = _read(a.path)
    f = _feat(m, a.label)
    if f is None:
        # UPSERT (AC-009 / SHR4-B2): an unknown label appends a new feature record instead of `_die`ing, so a
        # resume/crash-recovery `set` that races ahead of `add` does not strand the drain. Mirror cmd_add's
        # append shape with sane defaults (kind=orchestrated, derived branch). The upsert is PLAIN/UNGATED at
        # this CLI layer BY DELIBERATE DESIGN (ADR-130 D-4): the real consent/typo boundary is the
        # producer-side `<kind> ∈ KINDS` fail-fast at `/queue add` (Wave C), NOT a competing `--create` gate
        # here. (Invalid *status* still dies below — only an unknown *label* upserts.)
        kind = "orchestrated"
        f = {
            "label": a.label, "kind": kind, "spec": None, "status": "queued",
            "branch": a.branch or f"feature/{_BRANCH_INFIX[kind]}-{a.label}",
            "run_dir": None, "sha": None,
        }
        m["features"].append(f)
    if a.status:
        if a.status not in STATUSES:
            _die(f"invalid status '{a.status}' (expected {'|'.join(sorted(STATUSES))})")
        f["status"] = a.status
    if a.branch:
        f["branch"] = a.branch
    if a.run_dir:
        f["run_dir"] = a.run_dir
    if a.sha:
        f["sha"] = a.sha
    _atomic_write(a.path, m)
    print(f["status"])


def cmd_next(a):
    """Concurrency-aware dispatch decision:
      RUN:<label>  — a queued feature may start (running count < concurrency)
      WAIT:<n>     — concurrency saturated (n running); poll again when one finishes
      DRAINING     — none queued, some still running
      COMPLETE     — none queued, none running (fleet done -> fan-in review)
    """
    m = _read(a.path)
    K = m.get("concurrency") or 1
    running = [f for f in m["features"] if f["status"] == "running"]
    queued = [f for f in m["features"] if f["status"] == "queued"]
    if queued and len(running) < K:
        print(f"RUN:{queued[0]['label']}")
    elif running:
        print(f"WAIT:{len(running)}" if queued else "DRAINING")
    else:
        print("COMPLETE")


def cmd_summary(a):
    m = _read(a.path)
    counts = {s: 0 for s in sorted(STATUSES)}
    for f in m["features"]:
        counts[f["status"]] = counts.get(f["status"], 0) + 1
    print(json.dumps({"slug": m["slug"], "total": len(m["features"]), "counts": counts}))


def cmd_read(a):
    print(json.dumps(_read(a.path), indent=2))


def main():
    p = argparse.ArgumentParser(prog="launch-manifest")
    sub = p.add_subparsers(required=True)

    pi = sub.add_parser("init"); pi.set_defaults(fn=cmd_init)
    pi.add_argument("--path", required=True); pi.add_argument("--slug", required=True)
    pi.add_argument("--concurrency", type=int, default=1); pi.add_argument("--token-ceiling", type=int, default=None)

    pa = sub.add_parser("add"); pa.set_defaults(fn=cmd_add)
    pa.add_argument("--path", required=True); pa.add_argument("--spec", required=True); pa.add_argument("--label", default=None)
    pa.add_argument("--kind", default="orchestrated"); pa.add_argument("--branch", default=None)

    pset = sub.add_parser("set"); pset.set_defaults(fn=cmd_set)
    pset.add_argument("--path", required=True); pset.add_argument("--label", required=True)
    pset.add_argument("--status", default=None); pset.add_argument("--branch", default=None)
    pset.add_argument("--run-dir", dest="run_dir", default=None); pset.add_argument("--sha", default=None)

    pn = sub.add_parser("next"); pn.set_defaults(fn=cmd_next); pn.add_argument("--path", required=True)
    psm = sub.add_parser("summary"); psm.set_defaults(fn=cmd_summary); psm.add_argument("--path", required=True)
    pr = sub.add_parser("read"); pr.set_defaults(fn=cmd_read); pr.add_argument("--path", required=True)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
