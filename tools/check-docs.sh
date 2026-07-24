#!/usr/bin/env bash
# Assert that the drift-prone literals in the docs agree with their
# authorities. Facts only, never prose: the pipefail ban is already netted by
# tools/fixtures/run.sh, and the first-line release-notes rule has nothing
# mechanical to assert.
#
# Authorities are extracted at run time, never re-typed — the same seam
# direction as tools/replay.sh, for the same reason:
#   - the git-cliff version and STABLE_RE come from release.yml
#   - the js-yaml version comes from tools/replay.sh
#   - the current release comes from the highest stable tag in this clone
#
# Version tokens are swept across every tracked file, so a new duplication
# site is covered the day it is written. The current-release claims are
# parsed at their known shapes in README.md and docs/design.md.
#
# Expected failure window: between retagging and the docs update while
# cutting a release, this check fails by design — that is the tripwire
# working. See the runbook in CLAUDE.md.
#
# Assumes GNU coreutils — `sort -V` does the version ordering — i.e. Git Bash
# or Linux. BSD/macOS sort has no -V; a portable reimplementation waits for a
# demonstrated consumer.
#
# Usage: tools/check-docs.sh   (no arguments; offline; exit 0 only when
# every fact agrees)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
WORKFLOW=".github/workflows/release.yml"

FAILED=0
ok()    { echo "check-docs: $1 ... OK"; }
drift() { echo "check-docs: DRIFT: $1"; FAILED=1; }
die()   { echo "check-docs: $1" >&2; exit 1; }

single_line() { [ -n "$1" ] && [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" -eq 1 ]; }

# --- authorities ---

CLIFF_VER=$(sed -n 's/.*git-cliff@\([0-9][0-9.]*\).*/\1/p' "$WORKFLOW" | sort -u)
single_line "$CLIFF_VER" || die "cannot extract a single git-cliff version from ${WORKFLOW}"

JSYAML_VER=$(sed -n 's/.*js-yaml@\([0-9][0-9.]*\).*/\1/p' tools/replay.sh | sort -u)
single_line "$JSYAML_VER" || die "cannot extract a single js-yaml version from tools/replay.sh"

STABLE_RE=$(sed -n "s/^ *STABLE_RE='\(.*\)'\$/\1/p" "$WORKFLOW")
single_line "$STABLE_RE" || die "cannot extract STABLE_RE from ${WORKFLOW}"

# --- version-token sweeps over every tracked file ---

# sweep <token-ere> <ok-ere> <drift-label> <ok-label>: every token matching
# <token-ere> in any tracked file must match <ok-ere> in full. Tokens are
# judged one by one (git grep -o), never line-wise: a line naming both the
# correct and a wrong version fails on the wrong token instead of hiding
# behind the right one.
sweep() {
  BAD=$(git grep -noE "$1" -- . | grep -vE ":$2\$" || true)
  if [ -n "$BAD" ]; then
    drift "$3:"
    printf '%s\n' "$BAD" | sed 's/^/  /'
  else
    ok "$4"
  fi
}

esc() { printf '%s' "$1" | sed 's/\./\\./g'; }
CLIFF_ESC=$(esc "$CLIFF_VER")
JSYAML_ESC=$(esc "$JSYAML_VER")

sweep 'git-cliff@[0-9][0-9.]*' "git-cliff@${CLIFF_ESC}" \
  "git-cliff version other than ${CLIFF_VER}" \
  "every git-cliff@ token names ${CLIFF_VER}"

# Prose form of the same pin, with or without a v prefix — an editor adding a
# v must not exempt a claim from the sweep. "pinned at" refers to git-cliff
# in both docs; if a second tool ever gets described that way, split this
# sweep.
sweep 'pinned at v?[0-9][0-9.]*' "pinned at v?${CLIFF_ESC}" \
  "'pinned at' version other than ${CLIFF_VER}" \
  "every 'pinned at' claim names ${CLIFF_VER}"

sweep 'js-yaml@[0-9][0-9.]*' "js-yaml@${JSYAML_ESC}" \
  "js-yaml version other than ${JSYAML_VER}" \
  "every js-yaml@ token names ${JSYAML_VER}"

# --- STABLE_RE quoted in the design record ---

if grep -qF "$STABLE_RE" docs/design.md; then
  ok "design.md quotes STABLE_RE verbatim"
else
  drift "design.md does not contain the workflow's STABLE_RE (${STABLE_RE})"
fi

# --- current-release triplet: tags vs design.md claim vs README pins ---

CURRENT=$(git tag | grep -E "$STABLE_RE" | sort -V | tail -1)
[ -n "$CURRENT" ] || die "no stable tag in this clone"

CLAIM=$(sed -n 's/^\*\*`\(v[0-9][0-9.]*\)` is current\.\*\* It marks `\([0-9a-f][0-9a-f]*\)`.*/\1 \2/p' docs/design.md)
if single_line "$CLAIM"; then
  CLAIM_VER=${CLAIM% *}
  CLAIM_SHA=${CLAIM#* }
  if [ "$CLAIM_VER" = "$CURRENT" ]; then
    ok "design.md says ${CURRENT} is current"
  else
    drift "design.md says ${CLAIM_VER} is current; highest stable tag is ${CURRENT}"
  fi
  FULL=$(git rev-parse "${CURRENT}^{}")
  case "$FULL" in
    "${CLAIM_SHA}"*) ok "design.md's 'marks ${CLAIM_SHA}' matches ${CURRENT}" ;;
    *) drift "design.md says ${CLAIM_VER} marks ${CLAIM_SHA}; ${CURRENT} peels to ${FULL}" ;;
  esac
else
  drift "cannot find exactly one '**\`vX.Y.Z\` is current.** It marks \`<sha>\`' claim in docs/design.md"
fi

PINS=$(sed -n 's/.*release\.yml@[^ ]*  *# *\(v[0-9][0-9.]*\).*/\1/p' README.md)
if [ -n "$PINS" ]; then
  for PIN in $PINS; do
    if [ "$PIN" = "$CURRENT" ]; then
      ok "README pin comment names ${CURRENT}"
    else
      drift "README pin comment names ${PIN}; highest stable tag is ${CURRENT}"
    fi
  done
else
  drift "no 'release.yml@<sha>  # vX.Y.Z' pin comments found in README.md"
fi

[ "$FAILED" -eq 0 ]
