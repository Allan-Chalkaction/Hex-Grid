#!/usr/bin/env python3
"""graphiti-ingest-doc — verbatim, section-chunked ingestion of structured documents.

Implements the "documents are ingested faithful-verbatim, chunked" strategy
(docs/step-1-ideas/2026-06-10-ingestion-strategy-by-content-type.md): split a doc by `##`
section, strip only the markdown noise that extracts into junk entities (HTML comments, code-fence
markers), keep the EXACT prose, stamp provenance, and write each chunk through
graphiti_write.write_fact — the safe core (scrub → fail-closed group_id → idempotent content-hash →
OpenAI text-embedding-3-small@1024 embedder, which MATCHES the MCP server's embedder so the corpus is
searchable via search_memory_facts).

  python3 core/scripts/graphiti-ingest-doc.py docs/decisions/ADR-018-*.md --group-id claude-infra-adrs
  python3 core/scripts/graphiti-ingest-doc.py 'docs/decisions/ADR-0*.md' --group-id ... --dry-run

Per-file: one episode per `##` section (the H1 title is prepended to each chunk for context + entity
linking). Provenance is the source_path + the section heading anchor. Sections shorter than --min-chars
are skipped (noise). Idempotent: re-running skips unchanged chunks.
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import graphiti_write as gw  # noqa: E402 — the safe write core
import graphiti_lockstate as gls  # noqa: E402 — GCE-T4 lock-state skip/supersede decision

# AMS-T4 (wave-1-writes, AC-005): the directly-authored-ADR ("ADR first") birth path.
# ADRs are routinely orchestrator-authored OUTSIDE any engine run, so the AMS-T2 persist
# seam (engine-only) never sees them. This arm captures a newly-added/modified
# docs/decisions/ADR-*.md at commit time via the existing verbatim ingester — forward-only,
# off-by-default, fail-open. It REUSES write_fact()'s idempotency (content-hash dedup), so a
# re-fire on an amended ADR only writes the changed `##` sections.
_ADR_RE = re.compile(r"(^|/)docs/decisions/ADR-[^/]*\.md$")


def _changed_adrs(ref, repo_root):
    """Return repo-relative docs/decisions/ADR-*.md files changed in *ref*'s commit.

    Uses `git diff-tree` so it works as a post-commit trigger (the commit already exists).
    Fail-open: any git error returns an empty list (the caller no-ops). Forward-only — only
    Added/Modified paths in this one commit, never a backfill walk of the whole corpus.
    """
    try:
        out = subprocess.run(
            ["git", "-C", repo_root, "diff-tree", "--no-commit-id", "--name-only",
             "--diff-filter=AM", "-r", ref],
            capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            return []
        return [ln.strip() for ln in out.stdout.splitlines()
                if ln.strip() and _ADR_RE.search(ln.strip())]
    except Exception as e:  # noqa: BLE001 — fail-open
        print(f"changed-adrs: git lookup skipped ({e})", file=sys.stderr)
        return []


def _derive_group(repo_root):
    """Fail-closed group_id (delegates to the funnel's own resolver — never hand-assembled)."""
    try:
        return gw._resolve_group_id(None, repo_root)
    except Exception as e:  # noqa: BLE001 — fail-open
        print(f"changed-adrs: group derivation skipped ({e})", file=sys.stderr)
        return None


def _anchor(heading: str) -> str:
    return re.sub(r'[^a-z0-9]+', '-', heading.lower()).strip('-')


def split_sections(text: str):
    """Return (h1_title, [(heading, body), ...]) split on level-2 `## ` headings."""
    lines = text.splitlines()
    title = next((l[2:].strip() for l in lines if l.startswith('# ')), 'Document')
    sections, head, buf = [], 'Preamble', []
    for l in lines:
        if l.startswith('## '):
            if buf:
                sections.append((head, '\n'.join(buf).strip()))
            head, buf = l.lstrip('#').strip(), []
        elif l.startswith('# '):
            continue  # the H1 title is captured separately + prepended per chunk
        else:
            buf.append(l)
    if buf:
        sections.append((head, '\n'.join(buf).strip()))
    return title, sections


def clean(body: str) -> str:
    """Strip ONLY the markdown noise that extracts poorly — keep all prose verbatim."""
    body = re.sub(r'<!--.*?-->', '', body, flags=re.S)   # HTML comments (claimed-by stamps)
    body = re.sub(r'^\s*```.*$', '', body, flags=re.M)   # code-fence markers (keep inner text)
    body = re.sub(r'\n{3,}', '\n\n', body)               # collapse blank runs
    return body.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('paths', nargs='*', help='doc file(s) or glob(s)')
    ap.add_argument('--group-id', default=None,
                    help='explicit group_id (required unless --changed-adrs derives it fail-closed)')
    ap.add_argument('--repo-root', default=str(HERE.parent.parent), help='for source_path provenance')
    ap.add_argument('--min-chars', type=int, default=60, help='skip sections shorter than this')
    ap.add_argument('--dry-run', action='store_true')
    # AMS-T4 (AC-005): commit-time / non-engine directly-authored-ADR capture. Resolves the
    # changed ADR set from *ref*'s commit and derives the group_id fail-closed (no --group-id needed).
    ap.add_argument('--changed-adrs', metavar='REF', default=None,
                    help='ingest docs/decisions/ADR-*.md changed in REF (e.g. HEAD) — group derived fail-closed')
    args = ap.parse_args()

    group_id = args.group_id
    if args.changed_adrs:
        repo_for_diff = str(Path(args.repo_root).resolve())
        adrs = _changed_adrs(args.changed_adrs, repo_for_diff)
        if not adrs:
            print('changed-adrs: no directly-authored ADR changed — no-op')
            return 0
        # Make the ADR paths absolute against the repo root so glob picks them up regardless of cwd.
        args.paths = list(args.paths) + [os.path.join(repo_for_diff, a) for a in adrs]
        if not group_id:
            group_id = _derive_group(repo_for_diff)
            if not group_id:
                print('changed-adrs: no group derivable — fail-open no-op', file=sys.stderr)
                return 0

    if not args.paths:
        print('no paths given (pass file/glob args or --changed-adrs REF)', file=sys.stderr)
        return 2
    if not group_id:
        print('--group-id is required (or use --changed-adrs to derive it)', file=sys.stderr)
        return 2

    files = sorted({p for pat in args.paths for p in glob.glob(pat)})
    if not files:
        print('no files matched', file=sys.stderr)
        return 2
    repo_root = Path(args.repo_root).resolve()

    # CR-002: resolve the group_id ONCE — with cwd=None, exactly as write_fact resolves it below — so
    # the lock-state ledger and write_fact's manifest hash share ONE hash domain. Without this the
    # lock-state hash is computed over the RAW id while write_fact hashes the RESOLVED id, so the two
    # ledgers reference different content_hashes for the same chunk whenever resolution canonicalizes
    # or quarantines the id. Idempotent (re-resolving an already-resolved id is identity); falls back
    # to the raw id if resolution is unavailable, preserving prior behavior.
    try:
        gid = gw._resolve_group_id(args.group_id, None)
    except Exception:  # noqa: BLE001
        gid = args.group_id

    total_chunks = ok = skipped = failed = 0
    for f in files:
        fp = Path(f).resolve()
        try:
            rel = str(fp.relative_to(repo_root))
        except ValueError:
            rel = str(fp)
        title, sections = split_sections(fp.read_text(encoding='utf-8'))
        for head, body in sections:
            body = clean(body)
            char_count = len(body)
            if char_count < args.min_chars:
                continue
            total_chunks += 1
            chunk = f'{title} — §{head}\n\n{body}'
            # GCE-T4 lock-state consult (AC-012 wire-to-consumer): decide skip-vs-supersede-vs-create
            # for THIS chunk's content before riding write_fact. The decision composes with (does not
            # replace) write_fact's manifest/Neo4j idempotency gate. A locked doc whose content is
            # unchanged -> 'skip' (no re-ingest); a locked doc whose content CHANGED -> 'supersede':
            # the changed content has a NEW content_hash, so write_fact misses the manifest dedup and
            # takes the CREATE arm, writing a NEW episode — Graphiti's bi-temporal model then invalidates
            # the contradicted prior facts. Supersession is native/temporal, NOT a manifest update_uuid
            # rewrite (a changed hash never hits the manifest UPDATE arm). A first-time or non-locked
            # doc -> 'create' (manifest gate still dedups exact duplicates).
            # content_hash must match write_fact's: _content_hash(gid, scrub(text)[0]) over the RESOLVED
            # gid (CR-002). Scrub first (the same mandatory scrub write_fact applies) so the lock-state
            # hash and the manifest hash agree for this chunk.
            chash = gls.content_hash(gid, gw.scrub(chunk)[0])
            # chunk-scoped lock-state key: one record per (doc, section) so a multi-chunk doc tracks
            # each section's content independently. derive_lock_state strips the #anchor for taxonomy.
            chunk_key = f'{rel}#{_anchor(head)}'
            decision = gls.lockstate_decision(chunk_key, chash)
            if decision == 'skip':
                skipped += 1
                # reference-only diagnostic (AC-009/AC-018b): title/heading/source_path, NO body.
                print(f'  skip  {title} §{head}  (locked, unchanged · {rel})')
                continue
            try:
                res = gw.write_fact(
                    chunk,
                    group_id=gid,
                    source_description=f'{title}',
                    name=f'{title} §{head}'[:200],
                    dry_run=args.dry_run,
                    source_path=rel,
                    heading_anchor=_anchor(head),
                    # a changed LOCKED doc supersedes: its new content_hash misses the manifest dedup,
                    # so write_fact CREATEs a new episode and Graphiti's bi-temporal model invalidates
                    # the prior facts. force= only bypasses the Neo4j _already_written fast-path (a no-op
                    # for a new hash); kept for intent/forward-compat — NOT a manifest update_uuid rewrite.
                    force=(decision == 'supersede'),
                )
                status = (res or {}).get('status', 'ok') if isinstance(res, dict) else 'ok'
                # AC-008 latent-defect reconciliation: write_fact returns status ∈
                # {dry-run, duplicate, written, error} and NEVER 'skipped'. Map 'duplicate' (the
                # manifest/Neo4j idempotency hit) onto the skipped accounting; leave 'written'/'dry-run'
                # on the ok arm. write_fact's status vocabulary is NOT altered.
                if status == 'duplicate':
                    skipped += 1
                    print(f'  skip  {title} §{head}  (duplicate · {rel})')
                    # CR-003: converge the lock-state ledger even on a manifest-duplicate so a later
                    # run short-circuits at the lock-state 'skip' instead of re-consulting write_fact.
                    # Without this, a locked doc that first ingests as a duplicate never records lock
                    # state and re-invokes write_fact on every subsequent run.
                    if not args.dry_run:
                        gls.record(chunk_key, chash, gls.derive_lock_state(chunk_key),
                                   datetime.now(timezone.utc).isoformat())
                else:
                    ok += 1
                    sup = ' [supersede]' if decision == 'supersede' else ''
                    print(f'  {"DRY " if args.dry_run else "OK  "} {title} §{head}{sup}  ({char_count} chars)')
                    # record the lock-state for this path so a later unchanged re-ingest of a locked
                    # doc resolves to 'skip' (reference-only record — AC-018a; never a body).
                    if not args.dry_run:
                        gls.record(chunk_key, chash, gls.derive_lock_state(chunk_key),
                                   datetime.now(timezone.utc).isoformat())
            except Exception as e:  # noqa: BLE001
                failed += 1
                print(f'  FAIL  {title} §{head}: {e}', file=sys.stderr)

    print(f'\n{"[dry-run] " if args.dry_run else ""}files={len(files)} chunks={total_chunks} '
          f'written={ok} skipped={skipped} failed={failed}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
