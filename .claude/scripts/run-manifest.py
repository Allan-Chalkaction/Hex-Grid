#!/usr/bin/env python3
"""run-manifest.py — the v2 *thin manifest* for Workflow-engine runs.

The thin manifest replaces the v1 bespoke state machine (workflow-phases.json +
big phase .md files + most of advance-workflow-phase.sh + waves.json) with one
small JSON file per run that records only the durable runtime state that must
survive a cross-session interrupt: the chain, each step's status, and commit SHAs.

It is deliberately minimal — generic over nimble (single chain) and
orchestrated (multi-ticket, T5b). For nimble a run is a single chain of steps;
for orchestrated the same chain records the preset phases AND an additive
`tickets[]` array records the per-ticket queue (status / dep-order / SHA /
planned_files) that `/resume` walks across sessions.

Schema (`{run_dir}/manifest.json`) — `tickets` is ADDITIVE (T5b); nimble never
writes it, so the nimble single-chain path is byte-for-byte unchanged:
    {
      "schema": "thin-manifest/1",
      "slug": "1530-metrics-summary",
      "run_dir": "docs/step-5-pipeline/.../1530-NIMBLE-metrics-summary",
      "track": "nimble",                 # nimble | orchestrated | chain
      "chain": ["explore","implement","gate"],
      "status": "running",               # running | complete | blocked | surfaced
      "steps": [                          # one per chain phase, in order
        {"phase":"explore","status":"complete","note":null},
        {"phase":"implement","status":"complete","note":null},
        {"phase":"gate","status":"complete","note":"APPROVE+CONFORMS"}
      ],
      "tickets": [                        # ORCHESTRATED ONLY (absent for nimble)
        {"key":"T-001","status":"complete","depends_on":[],
         "commit_sha":"abc123","planned_files":["core/x.py"],"acceptance":["AC-001"],"note":null},
        {"key":"T-002","status":"pending","depends_on":["T-001"],
         "commit_sha":null,"planned_files":["core/y.py"],"acceptance":["AC-002"],"note":null}
      ],                                  # acceptance = the W1 AC-NNN atom chain (ADR-103 W3)
      "commit_sha": null,                 # set at commit (wave-level)
      "surface_required": false,
      "created_at": "ISO8601Z",
      "updated_at": "ISO8601Z"
    }

Subcommands:
    init        --run-dir D --slug S --track T --chain a,b,c   [--out PATH] [--force]
    read        PATH
    set-status  PATH STATUS                                   # run-level status
    set-step    PATH PHASE STATUS [--note TEXT]
    set-sha     PATH SHA                                      # wave-level commit sha
    next        PATH        # first step whose status != complete, else 'COMPLETE'
    # --- orchestrated tickets[] (T5b, additive) ---
    set-tickets PATH --tickets-file F.json   # (re)populate tickets[] from a JSON array
    set-ticket  PATH KEY STATUS [--sha SHA] [--note TEXT]     # mutate one ticket
    next-ticket PATH        # first DEP-READY ticket whose status != complete;
                            # 'COMPLETE' | 'BLOCKED:<key>' | 'WAITING:<key>'

All writes are atomic (tmp + os.replace). Exit 0 ok, 2 on validation error.
"""
import json, os, sys, argparse, datetime

SCHEMA = "thin-manifest/1"
RUN_STATUSES = {"running", "complete", "blocked", "surfaced"}
STEP_STATUSES = {"pending", "running", "complete", "blocked"}
TICKET_STATUSES = {"pending", "running", "complete", "blocked"}


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _die(msg, code=2):
    sys.stderr.write(f"run-manifest: {msg}\n")
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
        _die(f"manifest not found: {path}")
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def cmd_init(a):
    chain = [c.strip() for c in a.chain.split(",") if c.strip()]
    if not chain:
        _die("--chain must list at least one phase")
    out = a.out or os.path.join(a.run_dir, "manifest.json")
    if os.path.isfile(out) and not a.force:          # CR-005: fail closed, don't clobber
        _die(f"manifest already exists: {out} (pass --force to overwrite)")
    now = _now()
    m = {
        "schema": SCHEMA,
        "slug": a.slug,
        "run_dir": a.run_dir,
        "track": a.track,
        "chain": chain,
        "status": "running",
        "steps": [{"phase": p, "status": "pending", "note": None} for p in chain],
        "commit_sha": None,
        "surface_required": False,
        "created_at": now,
        "updated_at": now,
    }
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    _atomic_write(out, m)
    print(out)


def cmd_read(a):
    print(json.dumps(_read(a.path), indent=2))


def cmd_set_status(a):
    if a.status not in RUN_STATUSES:
        _die(f"invalid run status '{a.status}' (allowed: {sorted(RUN_STATUSES)})")
    m = _read(a.path)
    m["status"] = a.status
    if a.status == "surfaced":
        m["surface_required"] = True
    elif a.status == "complete":
        m["surface_required"] = False   # CR-004: recording completion clears a prior surface
    _atomic_write(a.path, m)
    print(f"status={a.status}")


def cmd_set_step(a):
    if a.status not in STEP_STATUSES:
        _die(f"invalid step status '{a.status}' (allowed: {sorted(STEP_STATUSES)})")
    m = _read(a.path)
    hit = False
    for s in m["steps"]:
        if s["phase"] == a.phase:
            s["status"] = a.status
            if a.note is not None:
                s["note"] = a.note
            hit = True
            break
    if not hit:
        _die(f"phase '{a.phase}' not in chain {[s['phase'] for s in m['steps']]}")
    _atomic_write(a.path, m)
    print(f"{a.phase}={a.status}")


def cmd_set_sha(a):
    m = _read(a.path)
    m["commit_sha"] = a.sha
    _atomic_write(a.path, m)
    print(f"commit_sha={a.sha}")


def cmd_next(a):
    m = _read(a.path)
    for s in m["steps"]:
        if s["status"] == "blocked":          # CR-003: blocked is terminal, not "resume here"
            print(f"BLOCKED:{s['phase']}")
            return
        if s["status"] != "complete":
            print(s["phase"])
            return
    print("COMPLETE")


# --- orchestrated tickets[] (T5b, additive) -------------------------------

def _validate_tickets(tickets):
    """Shape-validate a tickets[] list. Returns the normalized list or _die()s."""
    if not isinstance(tickets, list):
        _die("tickets must be a JSON array")
    keys = set()
    norm = []
    for i, t in enumerate(tickets):
        if not isinstance(t, dict):
            _die(f"ticket[{i}] must be an object")
        key = t.get("key")
        if not key or not isinstance(key, str):
            _die(f"ticket[{i}] missing non-empty string 'key'")
        if key in keys:
            _die(f"duplicate ticket key '{key}'")
        keys.add(key)
        status = t.get("status", "pending")
        if status not in TICKET_STATUSES:
            _die(f"ticket '{key}' invalid status '{status}' (allowed: {sorted(TICKET_STATUSES)})")
        dep = t.get("depends_on", []) or []
        if not isinstance(dep, list) or any(not isinstance(d, str) for d in dep):
            _die(f"ticket '{key}' depends_on must be a list of string keys")
        pf = t.get("planned_files", []) or []
        if not isinstance(pf, list) or any(not isinstance(p, str) for p in pf):
            _die(f"ticket '{key}' planned_files must be a list of strings")
        # acceptance: the W1 AC-NNN atom chain, carried through normalization (ADR-103 W3/CR-001) so the
        # closeout OUT-bookend reflux dossier ships the decided atoms. Additive; defaults [] (back-compat).
        acc = t.get("acceptance", []) or []
        if not isinstance(acc, list) or any(not isinstance(x, str) for x in acc):
            _die(f"ticket '{key}' acceptance must be a list of strings")
        norm.append({
            "key": key, "status": status, "depends_on": dep,
            "commit_sha": t.get("commit_sha"), "planned_files": pf,
            "acceptance": acc,
            "note": t.get("note"),
        })
    # every depends_on must reference a real key (no orphans)
    for t in norm:
        for d in t["depends_on"]:
            if d not in keys:
                _die(f"ticket '{t['key']}' depends_on unknown key '{d}'")
    # acyclic (CR-003: reject dependency cycles — symmetric with the orchestrated.js up-front check)
    by_key = {t["key"]: t for t in norm}
    WHITE, GREY, BLACK = 0, 1, 2
    colour = {k: WHITE for k in keys}

    def _dfs(k):
        colour[k] = GREY
        for d in by_key[k]["depends_on"]:
            if colour[d] == GREY:
                return True
            if colour[d] == WHITE and _dfs(d):
                return True
        colour[k] = BLACK
        return False

    for t in norm:
        if colour[t["key"]] == WHITE and _dfs(t["key"]):
            _die(f"ticket dependency cycle detected (through '{t['key']}')")
    return norm


def cmd_set_tickets(a):
    if not os.path.isfile(a.tickets_file):
        _die(f"tickets file not found: {a.tickets_file}")
    with open(a.tickets_file, encoding="utf-8") as f:
        raw = json.load(f)
    # accept either a bare array or {"tickets":[...]}
    if isinstance(raw, dict) and "tickets" in raw:
        raw = raw["tickets"]
    m = _read(a.path)
    m["tickets"] = _validate_tickets(raw)
    _atomic_write(a.path, m)
    print(f"tickets={len(m['tickets'])}")


def cmd_set_ticket(a):
    if a.status not in TICKET_STATUSES:
        _die(f"invalid ticket status '{a.status}' (allowed: {sorted(TICKET_STATUSES)})")
    m = _read(a.path)
    if not isinstance(m.get("tickets"), list):
        _die("manifest has no tickets[] (not an orchestrated run?)")
    hit = False
    for t in m["tickets"]:
        if t["key"] == a.key:
            t["status"] = a.status
            if a.sha is not None:
                t["commit_sha"] = a.sha
            if a.note is not None:
                t["note"] = a.note
            hit = True
            break
    if not hit:
        _die(f"ticket '{a.key}' not in {[t['key'] for t in m['tickets']]}")
    _atomic_write(a.path, m)
    print(f"{a.key}={a.status}")


def cmd_next_ticket(a):
    """First DEP-READY ticket whose status != complete.

    - 'COMPLETE'      — every ticket complete.
    - 'BLOCKED:<key>' — a ticket is blocked (terminal; operator must see it). Reported
                        ahead of pending work so a blocked wave halts rather than skipping.
    - 'WAITING:<key>' — the lowest incomplete ticket is gated on an incomplete dependency
                        AND no other ticket is dep-ready (a dependency stall worth surfacing).
    - '<key>'         — the first dep-ready, non-complete ticket to run/resume.
    """
    m = _read(a.path)
    tickets = m.get("tickets")
    if not isinstance(tickets, list) or not tickets:
        _die("manifest has no tickets[] (not an orchestrated run?)")
    by_key = {t["key"]: t for t in tickets}
    # blocked is terminal — surface it before anything else
    for t in tickets:
        if t["status"] == "blocked":
            print(f"BLOCKED:{t['key']}")
            return
    incomplete = [t for t in tickets if t["status"] != "complete"]
    if not incomplete:
        print("COMPLETE")
        return
    # dep-ready = all depends_on are complete
    for t in incomplete:
        if all(by_key[d]["status"] == "complete" for d in t["depends_on"]):
            print(t["key"])
            return
    # nothing dep-ready but work remains -> dependency stall
    print(f"WAITING:{incomplete[0]['key']}")


def main():
    p = argparse.ArgumentParser(prog="run-manifest")
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("init"); pi.set_defaults(fn=cmd_init)
    pi.add_argument("--run-dir", required=True)
    pi.add_argument("--slug", required=True)
    pi.add_argument("--track", required=True)
    pi.add_argument("--chain", required=True)
    pi.add_argument("--out")
    pi.add_argument("--force", action="store_true")

    pr = sub.add_parser("read"); pr.set_defaults(fn=cmd_read); pr.add_argument("path")
    ps = sub.add_parser("set-status"); ps.set_defaults(fn=cmd_set_status); ps.add_argument("path"); ps.add_argument("status")
    pp = sub.add_parser("set-step"); pp.set_defaults(fn=cmd_set_step)
    pp.add_argument("path"); pp.add_argument("phase"); pp.add_argument("status"); pp.add_argument("--note")
    px = sub.add_parser("set-sha"); px.set_defaults(fn=cmd_set_sha); px.add_argument("path"); px.add_argument("sha")
    pn = sub.add_parser("next"); pn.set_defaults(fn=cmd_next); pn.add_argument("path")

    # orchestrated tickets[] (T5b)
    pt = sub.add_parser("set-tickets"); pt.set_defaults(fn=cmd_set_tickets)
    pt.add_argument("path"); pt.add_argument("--tickets-file", required=True)
    pk = sub.add_parser("set-ticket"); pk.set_defaults(fn=cmd_set_ticket)
    pk.add_argument("path"); pk.add_argument("key"); pk.add_argument("status")
    pk.add_argument("--sha"); pk.add_argument("--note")
    pnt = sub.add_parser("next-ticket"); pnt.set_defaults(fn=cmd_next_ticket); pnt.add_argument("path")

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
