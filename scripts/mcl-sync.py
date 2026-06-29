#!/usr/bin/env python3
"""mcl-sync.py — keep wave manifest.json files in sync with build progress so
Mission Control Lite (MCL) shows live ticket status.

MCL (read-only, file-watcher) renders tickets from <run_dir>/manifest.json
(thin-manifest/1). This helper updates that file as the build proceeds; MCL's
chokidar watcher (200ms) picks the change up automatically — no MCL changes,
no API.

Usage:
  mcl-sync.py complete <TICKET_KEY> [<commit_sha>]   # mark a ticket complete
  mcl-sync.py start    <TICKET_KEY>                   # mark a ticket in_progress
  mcl-sync.py status                                  # print every wave's ticket states

It finds the manifest by scanning the MAIN worktree's docs/step-*-pipeline
(and step-*-done) for a manifest.json whose tickets[] contains the key. Safe to
call from a git worktree — it resolves the main working tree first. Idempotent.
"""
import json, os, re, sys, subprocess, datetime, glob

def now(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def main_worktree_root():
    # Resolve the primary working tree even when called from a linked worktree.
    try:
        cdir = subprocess.check_output(["git","rev-parse","--git-common-dir"],
                                       text=True).strip()
        cdir = os.path.abspath(cdir)
        # common dir is <main>/.git → main root is its parent
        root = os.path.dirname(cdir) if os.path.basename(cdir) == ".git" else cdir
        return root
    except Exception:
        return os.getcwd()

def find_manifests(root):
    pats = [os.path.join(root,"docs","step-*-pipeline","*","*","manifest.json"),
            os.path.join(root,"docs","step-*-done","*","*","manifest.json")]
    out = []
    for p in pats: out += glob.glob(p)
    return out

def load(p):
    try: return json.load(open(p))
    except Exception: return None

def save(p, m):
    tmp = p + ".tmp"
    json.dump(m, open(tmp,"w"), indent=2)
    os.replace(tmp, p)

def recompute_wave(m):
    ts = m.get("tickets",[])
    if ts and all(t.get("status")=="complete" for t in ts):
        m["status"]="complete"
    elif any(t.get("status") in ("in_progress","complete") for t in ts):
        m["status"]="running"
        # surface current phase = first in-progress (else next pending)
        cur = next((t for t in ts if t.get("status")=="in_progress"), None)
        if cur:
            m["steps"]=[{"phase":"implement","status":"running","note":f"building {cur['key']}"}]
            m["current_ticket"]=cur["key"]

def update_ticket(root, key, new_status, sha=None):
    for p in find_manifests(root):
        m = load(p)
        if not m: continue
        for t in m.get("tickets",[]):
            if t.get("key")==key:
                if new_status=="complete" and t.get("status")=="complete":
                    return p, False  # idempotent
                t["status"]=new_status
                if sha: t["commit_sha"]=sha
                m["updated_at"]=now()
                recompute_wave(m)
                save(p, m)
                return p, True
    return None, False

def cmd_status(root):
    for p in find_manifests(root):
        m = load(p)
        if not m: continue
        ts = m.get("tickets",[])
        done = sum(1 for t in ts if t.get("status")=="complete")
        print(f"{m.get('slug','?')} [{m.get('status','?')}] {done}/{len(ts)} — "+
              ", ".join(f"{t['key']}:{t['status']}" for t in ts))

if __name__=="__main__":
    if len(sys.argv)<2:
        print(__doc__); sys.exit(2)
    root = main_worktree_root()
    cmd = sys.argv[1]
    if cmd=="status":
        cmd_status(root)
    elif cmd in ("complete","start"):
        if len(sys.argv)<3: print("need TICKET_KEY", file=sys.stderr); sys.exit(2)
        key = sys.argv[2]
        sha = sys.argv[3] if len(sys.argv)>3 else None
        st = "complete" if cmd=="complete" else "in_progress"
        p, changed = update_ticket(root, key, st, sha)
        if p: print(f"{'updated' if changed else 'noop'}: {key} -> {st} in {os.path.relpath(p, root)}")
        else: print(f"no manifest contains ticket {key}", file=sys.stderr)
    else:
        print(__doc__); sys.exit(2)
