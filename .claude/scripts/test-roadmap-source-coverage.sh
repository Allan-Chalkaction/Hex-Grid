#!/usr/bin/env bash
# Synthetic test harness for roadmap-source-coverage.py (ADR-103 W2 — the deterministic IN-bookend gate).
# Runs in a temp scratch dir. Exit 0 = all PASS; exit 1 = at least one FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/core/scripts/roadmap-source-coverage.py"
[ -f "$SCRIPT" ] || { echo "ERROR: $SCRIPT not found" >&2; exit 1; }

PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

SCRATCH=$(mktemp -d); trap "rm -rf '$SCRATCH'" EXIT; cd "$SCRATCH"

mk_jam() { mkdir -p "$1/source"; for s in "${@:2}"; do echo "idea" > "$1/source/$s.md"; done; }

# ---- AC1: fully-dispositioned roadmap passes (exit 0) ----
mk_jam jam-a alpha-idea beta-idea gamma-idea
cat > roadmap-a.md <<'EOF'
# Roadmap: a
## Source disposition
- alpha-idea: wave:wave-1-foo
- beta-idea: non-goal
- gamma-idea: defer:docs/step-1-ideas/gamma
## Waves
EOF
if python3 "$SCRIPT" check jam-a roadmap-a.md >/dev/null 2>&1; then
  ok "fully-dispositioned roadmap passes (exit 0)"
else
  ko "complete pass" "expected exit 0, got $?"
fi

# ---- AC2: an undispositioned source HALTS (exit 2) and is named ----
cat > roadmap-b.md <<'EOF'
# Roadmap: b
## Source disposition
- alpha-idea: wave:wave-1-foo
- beta-idea: non-goal
## Waves
EOF
out=$(python3 "$SCRIPT" check jam-a roadmap-b.md 2>&1); rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -q "gamma-idea"; then
  ok "undispositioned source halts (exit 2) and names the gap (gamma-idea)"
else
  ko "gap detection" "expected exit 2 naming gamma-idea, got rc=$rc out=$out"
fi

# ---- AC3: no jam / no sources → gate not applicable (exit 0) ----
mkdir -p jam-empty
if python3 "$SCRIPT" check jam-empty roadmap-a.md >/dev/null 2>&1; then
  ok "no source atoms → gate not applicable (exit 0)"
else
  ko "no-jam skip" "expected exit 0, got $?"
fi

# ---- AC4: defer: and non-goal both count as accounted (not just wave:) ----
mk_jam jam-c only-deferred
cat > roadmap-c.md <<'EOF'
# Roadmap: c
## Source disposition
- only-deferred: defer:docs/backlog/x
EOF
if python3 "$SCRIPT" check jam-c roadmap-c.md >/dev/null 2>&1; then
  ok "defer:/non-goal disposition counts as accounted"
else
  ko "defer accounted" "expected exit 0, got $?"
fi

# ---- AC5: a MALFORMED disposition does NOT count as accounted (can't pass by writing junk) ----
mk_jam jam-d sneaky-idea
cat > roadmap-d.md <<'EOF'
# Roadmap: d
## Source disposition
- sneaky-idea: handled
EOF
out=$(python3 "$SCRIPT" check jam-d roadmap-d.md 2>&1); rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "malformed"; then
  ok "malformed disposition rejected (junk value cannot pass the gate)"
else
  ko "malformed reject" "expected exit 2 + malformed warn, got rc=$rc"
fi

# ---- AC6: disposition section is scoped — a slug mentioned OUTSIDE the section does not count ----
mk_jam jam-e scoped-idea
cat > roadmap-e.md <<'EOF'
# Roadmap: e
## Waves
- scoped-idea: wave:wave-1
## Source disposition
EOF
out=$(python3 "$SCRIPT" check jam-e roadmap-e.md 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
  ok "disposition is section-scoped (mention outside '## Source disposition' does not count)"
else
  ko "section scoping" "expected exit 2, got rc=$rc"
fi

# ---- AC7: an UNREADABLE roadmap collapses to RC=3 — never a fail-open exit 1 (SA-001) ----
# A completeness gate must not pass scope because it couldn't read the file. chmod 000 → open() OSError → 3.
if [ "$(id -u)" != "0" ]; then
  mk_jam jam-f locked-idea
  echo "# r" > roadmap-f.md; chmod 000 roadmap-f.md
  python3 "$SCRIPT" check jam-f roadmap-f.md >/dev/null 2>&1; rc=$?
  chmod 644 roadmap-f.md
  if [ "$rc" -eq 3 ]; then
    ok "unreadable roadmap → RC=3 (IO failure is fail-closed, not a silent exit-1 fall-through)"
  else
    ko "SA-001 fail-closed" "expected exit 3 on unreadable roadmap, got rc=$rc"
  fi
else
  echo "  SKIP: SA-001 unreadable-roadmap test (running as root — chmod 000 is bypassed)"
fi

echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo -e "FAILURES:$FAIL_DETAIL"; exit 1; fi
echo "ALL GREEN"; exit 0
