#!/usr/bin/env bash
# Re-run the guard's fixture behaviours through tools/replay.sh.
#
# Six of the seven behaviours in docs/design.md's fixture table run here. The
# GITHUB_REPOSITORY-unset behaviour is deliberately not covered: replay.sh
# validates the slug before the step runs, and machinery to bypass that would
# outweigh the one guard line it protects. See "Fixture evidence" in
# docs/design.md.
#
# PASS fixtures replay this repository's own immutable tags. FAIL fixtures
# replay synthetic repositories whose rigged cliff.toml legitimately produces
# the bad artifact — the whole step runs every time; nothing is extracted
# beyond what replay.sh already extracts.
#
# Every expectation is an exact line, counts included. A changed count is a
# regression, not a variation.
#
# Usage: tools/fixtures/run.sh   (no arguments; exit 0 only when all match)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPLAY="$ROOT/tools/replay.sh"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fixtures.XXXXXX")
trap 'rm -rf "$BASE"' EXIT

TOTAL=0
MATCHED=0

# build_repo <dir> [config]: two conventional commits and a stable tag under a
# fake origin. Without a config the repo has no cliff.toml — the guard A case.
build_repo() {
  git init -q "$1"
  git -C "$1" config user.email fixture@example.invalid
  git -C "$1" config user.name fixture
  git -C "$1" config core.autocrlf false
  git -C "$1" remote add origin https://github.com/acme/demo.git
  if [ $# -eq 2 ]; then
    cp "$2" "$1/cliff.toml"
    git -C "$1" add -- cliff.toml
  else
    printf 'seed\n' > "$1/seed.txt"
    git -C "$1" add -- seed.txt
  fi
  git -C "$1" commit -qm "feat: first thing"
  printf 'more\n' > "$1/more.txt"
  git -C "$1" add -- more.txt
  git -C "$1" commit -qm "fix: second thing"
  git -C "$1" tag v0.0.1
}

# check <name> <pass|fail> <exact-line> <repo> <tag>: replay, assert the exit
# status and the presence of the exact predicted line, then clean up whatever
# the replay preserved (kept worktrees on failure, preserved notes on success).
check() {
  NAME=$1; WANT=$2; LINE=$3; REPO=$4; TAG=$5
  TOTAL=$((TOTAL + 1))

  set +e
  OUT=$(bash "$REPLAY" "$REPO" "$TAG" 2>&1)
  STATUS=$?
  set -e

  KEPT=$(printf '%s\n' "$OUT" | sed -n 's/^replay: worktree kept for inspection: //p')
  if [ -n "$KEPT" ]; then
    git -C "$REPO" worktree remove --force "$KEPT" >/dev/null 2>&1 || true
  fi
  NOTES=$(printf '%s\n' "$OUT" | sed -n 's/^replay: notes preserved at //p')
  if [ -n "$NOTES" ]; then
    rm -rf "$(dirname "$NOTES")"
  fi

  OK=no
  case "$WANT" in
    pass) [ "$STATUS" -eq 0 ] && printf '%s\n' "$OUT" | grep -Fqx -- "$LINE" && OK=yes ;;
    fail) [ "$STATUS" -ne 0 ] && printf '%s\n' "$OUT" | grep -Fqx -- "$LINE" && OK=yes ;;
  esac

  if [ "$OK" = yes ]; then
    MATCHED=$((MATCHED + 1))
    echo "fixture: ${NAME} ... OK"
  else
    echo "fixture: ${NAME} ... MISMATCH (exit ${STATUS})"
    echo "  expected line: ${LINE}"
    printf '%s\n' "$OUT" | sed 's/^/  | /'
  fi
}

echo "fixtures: replaying the guard's behaviours (docs/design.md, Fixture evidence)"

check "normal release (this repo @ v2.0.0)" pass \
  "changelog OK: 12 bullet(s), 12 link(s) to rahgozar94725/release-workflows, 1 compare link(s)" \
  "$ROOT" v2.0.0

check "first release (this repo @ v1.0.0)" pass \
  "changelog OK: 2 bullet(s), 2 link(s) to rahgozar94725/release-workflows, 0 compare link(s)" \
  "$ROOT" v1.0.0

build_repo "$BASE/no-config"
check "missing config (guard A)" fail \
  "::error::cliff.toml not found in v0.0.1. git-cliff would fall back to its built-in default and publish notes in a different format. Tag a commit that contains cliff.toml." \
  "$BASE/no-config" v0.0.1

build_repo "$BASE/no-links" "$HERE/no-links.toml"
check "default-fallback shape: bullets without links" fail \
  "::error::Generated release notes failed the shape assertion: 2 bullet(s) but 0 commit link(s); expected one per bullet" \
  "$BASE/no-links" v0.0.1

build_repo "$BASE/wrong-owner" "$HERE/wrong-owner.toml"
check "links under another owner" fail \
  "::error::Generated release notes failed the shape assertion: 0/2 commit link(s) point at https://github.com/acme/demo; the rest point elsewhere" \
  "$BASE/wrong-owner" v0.0.1

build_repo "$BASE/empty" "$HERE/empty.toml"
check "empty render" fail \
  "::error::Generated release notes failed the shape assertion: no bullets rendered" \
  "$BASE/empty" v0.0.1

echo "not covered: GITHUB_REPOSITORY unset — deliberate; see docs/design.md"
echo "result: ${MATCHED}/${TOTAL} fixtures matched"
[ "$MATCHED" -eq "$TOTAL" ]
