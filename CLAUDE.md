# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

One reusable GitHub Actions workflow, `.github/workflows/release.yml`, called by
other repositories via `workflow_call`. It generates release notes with git-cliff
and publishes a GitHub release.

There is no source code, no build, no dependency manifest, and no test suite.
The product is shell inside YAML. Treat that file as the deliverable and
everything else as documentation.

`cliff.toml` here is a **reference copy** and is never read at runtime. GitHub
fetches a called workflow as a single file and runs it against the *caller's*
checkout, so no sibling file in this repository exists on the runner.

## There is no build, lint, or test command

Nothing to install, nothing to run. Verification happens two ways, and only the
second one counts as proof.

### Local: replay the changelog step

`tools/replay.sh` re-runs the workflow's entire `Generate changelog` step —
guard A, tag classification, the git-cliff render, and guard B — against a
consumer's clone, in a temporary worktree detached at the tag, mirroring what
`actions/checkout` produces:

```sh
git -C <consumer-repo-path> tag v0.0.1-testN <commit>
tools/replay.sh <consumer-repo-path> v0.0.1-testN    # third arg overrides owner/repo from origin
```

The script extracts the step's `run:` block out of `release.yml` at run time
and executes it verbatim under `bash -e` (the runner's default shell — no
pipefail). **Never copy the guard's assertions out of the workflow by hand**;
that procedure is what this script replaced. On success the rendered notes are
preserved to a printed temp path; on failure the worktree is kept for
inspection. This catches render and guard regressions before a tag is spent.
See "The replay module" in `docs/design.md` for why the seam points this way.

`tools/fixtures/run.sh` re-runs the guard's fixture behaviours through the
replay (six of seven — see "Fixture evidence" in `docs/design.md`). Run it
before and after any edit to the changelog step; it is the regression net the
fixture table used to only describe.

`tools/check-docs.sh` asserts the drift-prone literals — the git-cliff and
js-yaml version pins, `STABLE_RE`, and the current-release claims — against
their authorities, which it extracts rather than re-types. It is wired into
the release runbook below; see "The doc-fact check" in `docs/design.md`.

### On a runner: the only real proof

Nothing here is believed until a runner has run it. The established procedure:

1. Push the change to a branch. Do not tag it.
2. In a consuming repository, create a throwaway branch whose caller pins the
   **commit SHA** — untagged, non-default-branch SHAs resolve fine.
3. Predict the full expected output first: bullet counts per group, group order,
   the compare link, the exact `changelog OK:` line, asset count.
4. Tag a pre-release like `v0.0.1-test.N`, run, and compare against the
   prediction. Any divergence stops the work.
5. Report the run and release URL and **stop**. Teardown is gated on explicit
   human confirmation, never automatic.
6. Tag the release here on **the commit that ran**, not on a newer one.

When the consuming repository is live, record its `origin/main` SHA and the md5
and byte count of the files you touch *before* starting, and prove them
unchanged after teardown — not merely that the branch and tag are gone.

## Cutting a release of this repository

Deliberately manual.

- There is no push-tag trigger here. This repository's workflow is
  `workflow_call` only, so pushing a tag runs nothing.
- It deliberately does not call its own workflow. That would need a
  self-referential pin to a SHA that does not exist until after the commit, and
  a bug in the guards could block publishing the fix for that bug.
- So release notes here are generated locally and pasted into the release.

Prove the change on a runner first — see above. Tag the commit that ran.

```sh
# 0. Gate: a release must carry a consumer-visible change. Diff the two
#    consumer-visible files against the last stable tag; an empty diff means
#    there is nothing to release — stop here.
git diff <last-stable-tag> -- .github/workflows/release.yml cliff.toml

# 1. Tag locally, so the notes can be reviewed before the tag is public.
git tag -a vX.Y.Z <sha-that-ran>

# 2. The docs must already name vX.Y.Z — README pin comments, design.md's
#    "is current" claim, version literals. Drift here means the docs lag the
#    release being cut; fix them before publishing.
tools/check-docs.sh

# 3. Replay the changelog step against this repository itself. It renders with
#    this repo's own cliff.toml at the tag and runs both guards; the notes land
#    at the temp path it prints.
tools/replay.sh . vX.Y.Z

# 4. Review the preserved notes. Wrong? `git tag -d vX.Y.Z` and start over.

# 5. Publish.
git push origin vX.Y.Z
gh release create vX.Y.Z --notes-file <preserved-notes-path>   # add --prerelease for rc tags
```

Two rules live in this procedure rather than in someone's memory:

1. **If the version requires a matching `cliff.toml` change, say so in the first
   line of its release notes.** Consumers hold their own copy of the config, and
   the release notes are the only channel that tells them to update it.
2. **Create a real GitHub release object, not just a tag.** Consumers pin this
   repository by SHA; the releases feed is the only thing they can watch to
   learn that a new version exists. `v1.0.0` predates this rule and has no
   release object.

Publishing the release is what moves the consumer side: Dependabot opens a
pin-bump PR in each subscribed consumer (every consumer except MTProto-Checker,
whose pin is frozen by decision — see "Keeping consumer pins current" in
`docs/design.md`). A human reviews and merges each one; auto-merge stays off,
because the PR body carries the release notes and the first-line `cliff.toml`
warning only works if someone reads it. Open, unmerged bump PRs are the signal
that a consumer lags — there is no other fleet check.

## Load-bearing rules

These are decisions that look like oversights and will be "fixed" by anyone who
does not know why they exist. `docs/design.md` carries the reasoning; this is
the short list.

- **Never add `set -euo pipefail`** to the changelog step. `pipefail` aborts on
  `grep`'s empty-match exit inside the guard's pipelines, before the guard can
  report what was wrong. Two failure cases depend on the default shell.
- **Every hardcoded value is one that was verified; every input is a knob a
  consumer can turn to an unverified value.** Widening the input surface later
  is backward compatible, narrowing is not. Do not add an input for a need
  nobody has demonstrated.
- **git-cliff stays pinned at 2.13.1**, so rebuilding an old tag can never pick
  up rendering from a newer version.
- **A version whose adoption requires a `cliff.toml` change must say so in the
  first line of its release notes.** The config lives in each consuming
  repository and nothing here updates it; that rule is the only thing keeping
  the two in step.
- **Never use `git add -A` here.** A `release-workflows.zip` has twice been
  swept into commits that way, and one copy is inside the published `v1.0.0`
  tag. Stage explicit paths.
- **`.gitattributes` pins line endings repository-wide (`* text=auto eol=lf`),
  not just the two runner-critical extensions.** A CRLF inside a `run` block
  reaches a Linux runner as a literal carriage return and breaks the script —
  that is why `*.yml` and `*.toml` are also called out explicitly. But the
  baseline is broader on review grounds: a CRLF-only diff on a file nobody
  touched buries the real changes and puts noise into a tagged history. Scoping
  this to the runner hazard alone was the original mistake; a docs commit once
  showed 865 changed lines where 57 were real.

## Documentation split

- `README.md` — for someone adopting the workflow in their own repository. No
  rationale, no maintainer detail, no fixture evidence.
- `docs/design.md` — the durable record: why each flag and guard exists, what
  was proven on a runner and what was only argued, rejected alternatives, and
  the notes a future session needs. **This is the authority.** Read it before
  changing the workflow.
- `docs/superpowers/` and `.agent-docs/` are gitignored agent process artifacts.
  Nothing there is published; durable findings belong in `docs/design.md`.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on rahgozar94725/release-workflows (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
