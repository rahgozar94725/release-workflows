#!/usr/bin/env bash
# Replay the release workflow's "Generate changelog" step against a consumer
# checkout, locally.
#
# The step's script is extracted from .github/workflows/release.yml at run
# time and executed verbatim — never re-typed — so this file cannot drift
# from what the runner executes. The direction matters: GitHub fetches a
# called workflow as a single file, so the workflow can never call this
# script; this script reads the workflow. See docs/design.md.
#
# Usage: tools/replay.sh <consumer-repo-path> <tag> [owner/repo]
#
#   <consumer-repo-path>  a consumer's local clone
#   <tag>                 an existing tag in that clone
#   [owner/repo]          overrides the slug derived from `origin`
#
# The step runs in a temporary worktree detached at <tag>, mirroring what
# actions/checkout produces, under `bash -e` exactly as the runner's default
# shell — no pipefail, deliberately (docs/design.md, "Absence of set -euo
# pipefail"). On success the rendered notes are preserved to a temp path and
# the worktree is removed; on failure the worktree is kept for inspection.
#
# A green replay is not runner proof. It catches render and guard regressions
# before a tag is spent; the runner remains the only real proof.
set -eu

die() { echo "replay: $1" >&2; exit 1; }

[ $# -ge 2 ] && [ $# -le 3 ] || die "usage: tools/replay.sh <consumer-repo-path> <tag> [owner/repo]"

REPO=$1
TAG=$2

WORKFLOW="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows/release.yml"
[ -f "$WORKFLOW" ] || die "workflow file not found: $WORKFLOW"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $REPO"
git -C "$REPO" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || die "no tag ${TAG} in ${REPO}"

# GITHUB_REPOSITORY: explicit override, else derived from origin — the same
# value the runner would see, since the runner is always the consumer.
if [ $# -eq 3 ]; then
  SLUG=$3
else
  URL=$(git -C "$REPO" remote get-url origin 2>/dev/null) \
    || die "no origin remote in ${REPO}; pass owner/repo as the third argument"
  SLUG=$(printf '%s\n' "$URL" | sed -E 's#^(git@[^:]+:|ssh://git@[^/]+/|https?://[^/]+/)##; s#\.git$##; s#/$##')
fi
printf '%s' "$SLUG" | grep -Eq '^[^/]+/[^/]+$' \
  || die "cannot derive owner/repo from '${SLUG}'; pass it as the third argument"

# Extract the step by its id. A rename or restructure fails here, loudly —
# this is the sync alarm that used to be human memory. The step's env: keys
# are asserted against the set the invocation below supplies: the `${{ }}`
# values cannot be evaluated locally, so the key set is the contract, and a
# new env key must fail here — not expand empty inside a step that has no
# `set -u` while the replay goes green.
STEP=$(npx --yes js-yaml@4 "$WORKFLOW" | node -e '
  const doc = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const step = doc.jobs.release.steps.find(s => s.id === "changelog");
  if (!step || !step.run) { console.error("no run block on a step with id \"changelog\""); process.exit(1); }
  const supplied = new Set(["TAG", "GITHUB_REPOSITORY", "GITHUB_OUTPUT"]);
  const unhandled = Object.keys(step.env || {}).filter(k => !supplied.has(k));
  if (unhandled.length) {
    console.error("step env key(s) the replay does not supply: " + unhandled.join(", "));
    process.exit(1);
  }
  process.stdout.write(step.run);
') || die "could not extract the changelog step from ${WORKFLOW}"

git -C "$REPO" worktree prune

BASE=$(mktemp -d "${TMPDIR:-/tmp}/replay.XXXXXX")
WT="${BASE}/worktree"
OUT="${BASE}/github_output"
printf '%s\n' "$STEP" > "${BASE}/step.sh"
: > "$OUT"

git -C "$REPO" worktree add --detach "$WT" "$TAG" >/dev/null

echo "replay: ${SLUG} @ ${TAG}"
echo "---"

set +e
( cd "$WT" && TAG="$TAG" GITHUB_REPOSITORY="$SLUG" GITHUB_OUTPUT="$OUT" bash -e "${BASE}/step.sh" )
STATUS=$?
set -e

echo "---"
if [ "$STATUS" -ne 0 ]; then
  echo "replay: step FAILED with exit ${STATUS}" >&2
  echo "replay: worktree kept for inspection: ${WT}" >&2
  echo "replay: remove it with: git -C '${REPO}' worktree remove --force '${WT}'" >&2
  exit "$STATUS"
fi

cp "${WT}/RELEASE_NOTES.md" "${BASE}/RELEASE_NOTES.md"
git -C "$REPO" worktree remove --force "$WT"

echo "replay: step outputs:"
sed 's/^/  /' "$OUT"
echo "replay: notes preserved at ${BASE}/RELEASE_NOTES.md"
