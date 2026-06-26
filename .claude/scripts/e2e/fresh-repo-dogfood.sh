#!/usr/bin/env bash
# fresh-repo-dogfood.sh — stand up a brand-new "simple website" repo, wire it into
# claude-infra, and seed it for an end-to-end substrate dogfood (ideas → /sweep →
# 2 plans → /roadmap → specs → /nimble).
#
# This is NOT a unit test and deliberately lives OUTSIDE core/scripts/test-*.sh so
# it never joins the 63-script battery the wave-end harness re-runs 11×.
#
# What it does (idempotent — safe to re-run against the same throwaway repo):
#   1. git init + scaffold a minimal static website (index.html/styles.css/app.js/...).
#   2. Onboard it: setup.sh (symlink core/* + register guard hooks) + register-consumer.sh.
#   3. Seed 10 simple-website ideas into docs/step-1-ideas/needs-shaping/ (well-formed
#      /idea schema), designed to cluster cleanly into 2 plans (content / ux-polish).
#   4. Write DOGFOOD-RUNBOOK.md — the live journey you drive from a session in the repo.
#   5. Run a fast preflight (--preflight-only to run just this) asserting the wiring is live.
#
# Usage:
#   bash core/scripts/e2e/fresh-repo-dogfood.sh <target-repo-dir>
#   bash core/scripts/e2e/fresh-repo-dogfood.sh <target-repo-dir> --preflight-only
#   bash core/scripts/e2e/fresh-repo-dogfood.sh <target-repo-dir> --no-register   # skip registry mutation
#
# Example:
#   bash core/scripts/e2e/fresh-repo-dogfood.sh ~/Desktop/testing-infra-v2

set -uo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"   # core/scripts/e2e -> repo root
SETUP="${INFRA_DIR}/setup.sh"
REGISTER="${INFRA_DIR}/core/scripts/register-consumer.sh"
TODAY="$(date +%F)"

TARGET=""
PREFLIGHT_ONLY=false
NO_REGISTER=false
for a in "$@"; do
  case "$a" in
    --preflight-only) PREFLIGHT_ONLY=true ;;
    --no-register)    NO_REGISTER=true ;;
    *)                TARGET="$a" ;;
  esac
done

[ -n "$TARGET" ] || { echo "Usage: fresh-repo-dogfood.sh <target-repo-dir> [--preflight-only] [--no-register]" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
[ -f "$SETUP" ] || { echo "ERROR: setup.sh not found at $SETUP" >&2; exit 1; }

# Expand a leading ~ (the arg often arrives literal from a non-interactive caller).
case "$TARGET" in "~/"*) TARGET="${HOME}/${TARGET#\~/}" ;; "~") TARGET="$HOME" ;; esac

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { echo "  PASS: $1"; PFP=$((PFP+1)); }
ko()   { echo "  FAIL: $1"; PFF=$((PFF+1)); }

# ---------------------------------------------------------------------------
# The 10 seed ideas. slug | area | spark | why/value | size
# Designed to cluster into exactly 2 plans:
#   area=content  -> "visitor-facing content pages"
#   area=ux       -> "site UX & polish"
# ---------------------------------------------------------------------------
IDEAS=(
  "about-page|content|Add an About page introducing the team and mission|Visitors want to know who is behind the site before they trust it|s"
  "contact-form|content|Add a contact form with name/email/message + email validation|Primary conversion path; right now there is no way to reach us|m"
  "blog-section|content|Add a simple blog / news section with a list + post pages|Fresh content for SEO and repeat visits|m"
  "testimonials|content|Add a customer testimonials section to the homepage|Social proof lifts conversion on the landing page|s"
  "faq-page|content|Add an FAQ page answering the top 8 questions|Cuts repetitive contact-form questions|s"
  "dark-mode|ux|Add a dark mode toggle that remembers the choice|Common expectation; reduces eye strain at night|s"
  "mobile-nav|ux|Make the nav responsive with a mobile hamburger menu|Most traffic is mobile and the nav overflows today|m"
  "cookie-banner|ux|Add a cookie consent banner with accept/decline|Basic compliance before we add any analytics|s"
  "custom-404|ux|Add a branded custom 404 page with a search box|Default 404 looks broken and loses visitors|xs"
  "seo-meta|ux|Add SEO meta tags + Open Graph / Twitter card tags|Shared links look bare and rank poorly|s"
)

# ===========================================================================
# PREFLIGHT — fast assertions that the substrate is live in the target repo.
# ===========================================================================
preflight() {
  PFP=0; PFF=0
  say "PREFLIGHT — substrate wiring in $TARGET"

  [ -d "$TARGET/.git" ] && ok "git repo initialized" || ko "no .git in target"

  # Symlinked substrate dirs resolve back into claude-infra.
  for d in rules skills hooks; do
    if [ -e "$TARGET/.claude/$d" ]; then
      tgt="$(readlink "$TARGET/.claude/$d" 2>/dev/null || true)"
      ok ".claude/$d present${tgt:+ -> $tgt}"
    else
      ko ".claude/$d missing (setup.sh did not wire it)"
    fi
  done

  # Guard hooks registered in the project settings.
  if [ -f "$TARGET/.claude/settings.json" ] || [ -f "$TARGET/.claude/settings.local.json" ]; then
    if grep -rqsE "require-track-selection|require-protocol|block-source-edits" "$TARGET/.claude/"settings*.json; then
      ok "guard hooks registered in settings"
    else
      ko "guard hooks NOT found in settings json"
    fi
  else
    ko "no .claude/settings*.json (hooks unregistered)"
  fi

  # The 10 ideas are present and well-formed.
  ideadir="$TARGET/docs/step-1-ideas/needs-shaping"
  n="$(ls -1 "$ideadir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" = "10" ] && ok "10 ideas seeded in needs-shaping/" || ko "expected 10 ideas, found $n"
  # Schema sniff on one file.
  one="$(ls -1 "$ideadir"/*.md 2>/dev/null | head -1)"
  if [ -n "$one" ] && grep -q "captured:" "$one" && head -1 "$one" | grep -q "^# "; then
    ok "idea schema well-formed (# spark + captured: line)"
  else
    ko "idea schema malformed"
  fi

  # idea-map.py runs from the consumer repo and renders an INDEX listing the ideas.
  if [ -e "$TARGET/.claude/scripts/idea-map.py" ]; then
    if ( cd "$TARGET" && python3 .claude/scripts/idea-map.py >/dev/null 2>&1 ); then
      idx="$TARGET/docs/step-1-ideas/INDEX.md"
      if [ -f "$idx" ] && grep -qiE "needs-shaping|10|idea" "$idx"; then
        ok "idea-map.py regenerated docs/step-1-ideas/INDEX.md"
      else
        ko "idea-map.py ran but INDEX.md missing/empty"
      fi
    else
      ko "idea-map.py failed to run from consumer repo"
    fi
  else
    ko ".claude/scripts/idea-map.py not wired"
  fi

  # Engine scripts are reachable and parse (node --check) — proves nimble/orchestrated are runnable.
  if command -v node >/dev/null 2>&1; then
    eng="$TARGET/.claude/scripts/workflows/nimble.js"
    if [ -e "$eng" ] && node --check "$eng" >/dev/null 2>&1; then
      ok "nimble engine script reachable + parses"
    else
      ko "nimble.js missing or fails node --check"
    fi
  else
    echo "  SKIP: node not installed — engine parse check skipped"
  fi

  # The doc-lifecycle move primitives are reachable (sweep routes to these).
  for s in idea-map.py retire-spec.py closeout-jam.py; do
    [ -e "$TARGET/.claude/scripts/$s" ] && ok "move primitive wired: $s" || ko "move primitive missing: $s"
  done

  say "PREFLIGHT RESULT: $PFP passed, $PFF failed"
  return $PFF
}

if $PREFLIGHT_ONLY; then
  preflight; exit $?
fi

# ===========================================================================
# 1. SCAFFOLD — a minimal static "simple website".
# ===========================================================================
say "1/5 SCAFFOLD — simple website at $TARGET"
mkdir -p "$TARGET"
( cd "$TARGET" && { [ -d .git ] || git init -q; } )

cat > "$TARGET/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Acme — Simple Site</title>
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <header><nav><a href="/">Acme</a> <a href="#features">Features</a></nav></header>
  <main>
    <section class="hero"><h1>Acme</h1><p>A deliberately tiny website for substrate dogfooding.</p></section>
    <section id="features"><h2>Features</h2><ul><li>Fast</li><li>Simple</li><li>Boring (on purpose)</li></ul></section>
  </main>
  <footer><small>&copy; Acme</small></footer>
  <script src="app.js"></script>
</body>
</html>
HTML

cat > "$TARGET/styles.css" <<'CSS'
:root { --fg:#111; --bg:#fff; }
* { box-sizing: border-box; }
body { margin:0; font:16px/1.5 system-ui, sans-serif; color:var(--fg); background:var(--bg); }
header, main, footer { max-width: 720px; margin: 0 auto; padding: 1rem; }
nav a { margin-right: 1rem; }
.hero { padding: 3rem 0; }
CSS

cat > "$TARGET/app.js" <<'JS'
// Intentionally tiny — a placeholder for the dark-mode / nav ideas to build on.
console.log("Acme site loaded");
JS

cat > "$TARGET/package.json" <<'JSON'
{
  "name": "testing-infra-v2",
  "version": "0.0.0",
  "private": true,
  "description": "Throwaway simple website for claude-infra substrate dogfooding",
  "scripts": {
    "serve": "python3 -m http.server 8080"
  }
}
JSON

cat > "$TARGET/.gitignore" <<'GI'
node_modules/
.DS_Store
GI

cat > "$TARGET/README.md" <<'MD'
# testing-infra-v2 — throwaway dogfood site

A deliberately minimal static website used to validate the claude-infra substrate
end-to-end in a brand-new repo. See `DOGFOOD-RUNBOOK.md` for the journey.

Run locally: `npm run serve` then open http://localhost:8080
MD

echo "  scaffolded: index.html styles.css app.js package.json README.md .gitignore"

# ===========================================================================
# 2. ONBOARD — wire + register.
# ===========================================================================
say "2/5 ONBOARD — setup.sh + register-consumer.sh"
bash "$SETUP" "$TARGET" || { echo "ERROR: setup.sh failed" >&2; exit 1; }
if $NO_REGISTER; then
  echo "  (skipped registry mutation per --no-register)"
else
  bash "$REGISTER" "$TARGET" "testing-infra-v2" | tail -1
fi

# ===========================================================================
# 3. SEED 10 IDEAS — into the inbox needs-shaping bucket.
# ===========================================================================
say "3/5 SEED — 10 simple-website ideas (2 clusters: content / ux)"
ideadir="$TARGET/docs/step-1-ideas/needs-shaping"
mkdir -p "$ideadir"
for row in "${IDEAS[@]}"; do
  IFS='|' read -r slug area spark value size <<< "$row"
  f="$ideadir/${TODAY}-${slug}.md"
  cat > "$f" <<MD
# ${spark}
- **captured:** ${TODAY} · **source:** dogfood-seed
- **area:** ${area}
- **why / value:** ${value}
- **rough size:** ${size}
- **notes:** seeded by fresh-repo-dogfood.sh; expected cluster = "${area}"
MD
  echo "  + ${TODAY}-${slug}.md  [${area}]"
done

# ===========================================================================
# 4. RUNBOOK — the live journey.
# ===========================================================================
say "4/5 RUNBOOK — DOGFOOD-RUNBOOK.md"
cat > "$TARGET/DOGFOOD-RUNBOOK.md" <<MD
# Substrate dogfood runbook — testing-infra-v2

A brand-new repo, wired to claude-infra, seeded with 10 ideas. This runbook drives the
**live** journey (the LLM-driven skills must run from a session rooted in THIS repo).

> Re-run the scaffold any time: \`bash <infra>/core/scripts/e2e/fresh-repo-dogfood.sh ~/Desktop/testing-infra-v2\`
> Fast wiring check only: append \`--preflight-only\`.

## 0. Open a session here
\`\`\`
cd ~/Desktop/testing-infra-v2 && claude
\`\`\`

## 1. See the inbox
- \`/sweep\` — should table all 10 ideas (needs-shaping), age, gist, a recommended verdict each.
- Expect them to fall into two themes: **content** (about, contact, blog, testimonials, faq)
  and **ux** (dark-mode, mobile-nav, cookie-banner, 404, seo).

## 2. Converge into 2 plans (via /sweep)
- Answer the sweep verdicts to cluster the 5 **content** ideas into one jam and the 5 **ux**
  ideas into another (new-cluster). \`/sweep\` does the file moves + in-skill convergence.
- Verify: \`docs/step-2-planning/jam-*/\` now holds two jams; the moved ideas left needs-shaping.

## 3. Plan each jam into specs (via /roadmap)
- \`/roadmap\` (Phase E) seeded from the content jam → \`docs/step-3-specs/<slug>/roadmap.md\` + waves.
- Repeat for the ux jam.
- Verify: two spec folders exist with a roadmap.md + waves/.

## 4. Build one wave (test nimble)
- Pick the smallest wave (e.g. the **custom-404** ux ticket).
- \`/nimble\` it: explore → implement (worktree) → integrate → batch-gate.
- Verify: a new \`404.html\` (or equivalent) committed on a worktree branch; gate verdict APPROVE.

## 5. Lifecycle check
- \`/doctor\` — health of the wired repo.
- Confirm location-is-status moves: a built run folder moved to \`docs/step-6-done/\`.

## Cleanup (it's a throwaway)
- Unregister: remove the testing-infra-v2 entry from \`<infra>/core/config/infra-consumers.json\`.
- Delete the repo dir. No other state to clean (everything was local).
MD
echo "  wrote DOGFOOD-RUNBOOK.md"

# ===========================================================================
# 5. PREFLIGHT
# ===========================================================================
preflight
rc=$?

say "DONE — testing-infra-v2 scaffolded, onboarded, seeded."
echo "Next: cd $TARGET && claude   (then follow DOGFOOD-RUNBOOK.md)"
exit $rc
