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

### Local: render and replay the guard

Run the workflow's exact git-cliff invocation against a real repository — a
consumer's checkout, detached at a tag, mirroring what `actions/checkout`
produces:

```sh
git tag v0.0.1-testN <commit>
git checkout --detach v0.0.1-testN
npx --yes git-cliff@2.13.1 -c cliff.toml --current --use-branch-tags \
  --github-repo "<owner>/<repo>" --offline -o /tmp/notes.md
```

Then replay guard B against the rendered file with `GITHUB_REPOSITORY` exported,
copying the assertions out of the workflow. This catches render and guard
regressions before a tag is spent, and it is how every prediction in
`docs/design.md` was produced.

The `--github-repo … --offline` pair is mandatory, not decoration. On a detached
HEAD, git-cliff renders `remote.github.owner` and `remote.github.repo` empty and
every link becomes `https://github.com///commit/<sha>` at exit 0.

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
# 1. Tag locally, so the notes can be reviewed before the tag is public.
git tag -a vX.Y.Z <sha-that-ran>

# 2. Generate notes with this repository's own cliff.toml and the workflow's flags.
git checkout --detach vX.Y.Z
npx --yes git-cliff@2.13.1 -c cliff.toml --current --use-branch-tags \
  --github-repo rahgozar94725/release-workflows --offline -o /tmp/notes.md

# 3. Review /tmp/notes.md. Wrong? `git tag -d vX.Y.Z` and start over.

# 4. Publish.
git push origin vX.Y.Z
gh release create vX.Y.Z --notes-file /tmp/notes.md   # add --prerelease for rc tags
```

Two rules live in this procedure rather than in someone's memory:

1. **If the version requires a matching `cliff.toml` change, say so in the first
   line of its release notes.** Consumers hold their own copy of the config, and
   the release notes are the only channel that tells them to update it.
2. **Create a real GitHub release object, not just a tag.** Consumers pin this
   repository by SHA; the releases feed is the only thing they can watch to
   learn that a new version exists. `v1.0.0` predates this rule and has no
   release object.

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
