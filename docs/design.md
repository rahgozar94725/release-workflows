# Design record

Why this workflow is shaped the way it is. Every finding below was established
by observing an actual run, not by reading documentation. Most of them describe
failures that **exit 0 and publish wrong release notes** rather than failing —
which is why the workflow is full of assertions that look redundant until you
have seen one of them fire.

## The git-cliff invocation

```sh
npx --yes git-cliff@2.13.1 -c "${CONFIG}" --current --use-branch-tags \
  --github-repo "${GITHUB_REPOSITORY}" --offline "$@" -o RELEASE_NOTES.md
```

**`--current`, not `--latest`.** `--latest` resolves to the newest tag in the
repository, not the tag being built. When two tags land close together it fills
the older tag's release with the newer tag's commits. `--current` scopes to the
tag that checkout put HEAD on.

**`--use-branch-tags`.** Without it, a repository's very first tag fails:
`--current` with no previous tag exits 1 with
`ChangelogError("No suitable tags found")` and writes no file, so the release
never happens. git-cliff's own suggestion of `--topo-order` does not fix that
case; `--use-branch-tags` does, by limiting the tag set to tags reachable from
HEAD.

**`--github-repo` and `--offline`, both mandatory.** `actions/checkout` leaves
a detached HEAD. On it, git-cliff renders `remote.github.owner` and
`remote.github.repo` as empty strings, so a config deriving its URL from them
produces `https://github.com///commit/<sha>` for every bullet — **exit 0, notes
published, links dead.** `--github-repo "${GITHUB_REPOSITORY}"` supplies the
values. It cannot be used alone: without `--offline` git-cliff panics on an
`api.github.com/repos/.../pulls` call.

Verified equivalent: on a detached checkout at `v2.0.0`, the derived-URL config
plus these two flags renders byte-identical to a config with the URL hardcoded
— 2147 bytes, md5 `06655476c601845e` for both. Deriving is therefore free, and
it means a fork or a rename cannot keep silently linking to the old repository.

**Version pinned at 2.13.1** so rebuilding an old tag can never pick up
rendering from a newer 2.x.

## Pre-release branching

One regex, `^v[0-9]+\.[0-9]+\.[0-9]+$`, does two jobs: it decides whether the
GitHub release is flagged as a pre-release, and it filters git-cliff's tag set.
Using one value for both is deliberate — two copies could disagree.

A stable tag gets `--tag-pattern` with that regex, so both the commit range and
the compare link skip the release candidates that led to it. Without it, a
stable release shows only the commits since its last rc.

A pre-release tag gets **no** `--tag-pattern`, so it measures against the
previous rc when one exists and the previous stable otherwise. The flag must
not be applied to an rc tag: it removes the tag being built from the set, and
git-cliff exits 1 with `No tag exists for the current commit` and writes no
file.

## Guard A — the config must ship with the tag

git-cliff does not fail when its configuration file is missing. It logs one
WARN, exits 0, and renders with its built-in default: no commit links,
different group names. An explicit `-c` pointing at a nonexistent file does not
change that. The fallback is silent enough to reach a published release
unnoticed.

So the step refuses to run when `config-path` is absent from the tag being
built. The consequence is deliberate: tags predating the config cannot be
rebuilt until they carry it. Failing beats publishing notes in an unreviewed
format.

## Guard B — assert the artifact, not the input

Guard A checks an input. Guard B checks what was actually rendered:

- at least one bullet;
- one commit link per bullet (`ALL_LINKS == BULLETS`);
- every commit link under `https://github.com/$GITHUB_REPOSITORY`
  (`OUR_LINKS == BULLETS`);
- the compare link, if present, under the same prefix
  (`CMP_ALL == CMP_OURS`).

Four details, each load-bearing:

**`ALL_LINKS` and `OUR_LINKS` stay separate** because they diagnose different
failures. Equal-but-zero means the built-in default rendered; unequal means
something linked elsewhere. Collapsing them into one count loses the
distinction exactly when you need it.

**The compare check tolerates zero and rejects wrong.** A repository's first
release legitimately has nothing to compare against. Keying the guard on the
compare line's *presence* would fail that release; keying it on the line's
*correctness* passes it.

**`-F` throughout**, so a repository name containing `.` or `+` cannot be read
as a regular expression.

**The empty-`GITHUB_REPOSITORY` check is load-bearing.** It runs before
anything else. An empty value collapses the expected prefix to
`https://github.com/`, which matches `https://github.com///commit/<sha>` — the
very malformed URL the guard exists to catch. Without that check the guard
passes precisely when it should fail.

### Fixture evidence

Seven fixtures, six distinct behaviours, run by hand against real generated
files. **Hand-verified outside CI. Nothing in this repository re-runs them**, so
a future edit to the guard has no automated regression net.

| Fixture | Result | Detail |
| --- | --- | --- |
| `v2.0.0`, normal release | PASS | 12 bullets, 12 ours, 1 compare |
| `v1.0.0`, first release | PASS | 11 bullets, 11 ours, 0 compare |
| unset owner/repo | FAIL | `0/12 commit link(s) point at …` |
| config copied, wrong repo | FAIL | same message |
| missing config, default fallback | FAIL | `12 bullet(s) but 0 commit link(s)` |
| empty file | FAIL | `no bullets rendered` |
| `GITHUB_REPOSITORY` unset | FAIL | `cannot verify link ownership` |

## Absence of `set -euo pipefail`

The `Generate changelog` step runs under GitHub's default `bash -e {0}` and
**must not** gain `set -euo pipefail`. This is the decision most likely to be
undone by someone hardening the file, because an absent line does not announce
itself.

Guard B counts links with pipelines of this form:

```sh
ALL_LINKS=$(grep -oE 'https://[^)]*/commit/[0-9a-f]{40}' RELEASE_NOTES.md | wc -l | tr -d ' ')
```

`grep` exits 1 when it matches nothing. Under plain `-e` the pipeline's status
is `tr`'s, so the zero-match case assigns `0`, the assertions run, and the step
reports what was wrong. Under `pipefail` the step aborts at that line with no
annotation at all.

Verified both ways: without it the guard reaches `ALL_LINKS=0` and exits 0 with
its message; with `set -euo pipefail` it exits 1 before the assertion ever runs.
Two fixtures — missing config (12 bullets, 0 links) and empty file (0 bullets) —
depend on this. Hardening the shell would silently delete the guard's ability to
say what went wrong.

## Pinning by SHA

Consumers pin `uses: …/release.yml@<sha>` with the version in a trailing
comment. A moving ref like `@v1` lets whoever controls this repository repoint a
consumer at code that consumer never reviewed. The SHA says what runs; the
comment says what it is.

This also dissolves an apparent circularity — you cannot pin to a SHA before one
exists, and no version should be tagged before it is proven. A commit SHA exists
the moment the commit does, on any branch, tagged or not. So a consumer under
test pins the SHA directly, and tagging that same commit afterwards requires no
repin, because tagging does not move the SHA.

**Untested and load-bearing.** That a reusable workflow can be referenced by a
SHA which is neither on the default branch nor carries a tag has not been
confirmed on a runner. It is self-testing: if it is false, the first test call
fails immediately and cheaply, before anything is published.

## Rejected shapes: where cliff.toml lives

Three shapes were weighed. They differ only in where the git-cliff
configuration lives.

- **A — the config lives in each consuming repository.** The shared repository
  carries only the workflow. This is what was built.
- **B — the config lives in the shared repository**, and the reusable workflow
  checks out its own repository at runtime to fetch it.
- **C — the shared workflow writes the config itself**, from a quoted heredoc
  inside the workflow file, into `$RUNNER_TEMP`, and passes it with `-c`.

**B was rejected outright rather than weighed.** It carries C's cost — the
config is not visible or editable in the consuming project — without C's
advantage, because it still needs a second checkout of this repository at
runtime. See "A script in this repository" below for why that checkout is worse
than untested.

**C was rejected on five counts, in order of weight.**

1. **Three quoting layers**: TOML inside YAML inside shell. The template
   contains `{{ }}` and `{% %}`, which survive only because Actions interpolates
   `${{` alone. A future template needing `${{` breaks silently or explodes.
2. **Tooling loss.** No TOML highlighting, no formatter, no meaningful diff. A
   one-line group rename reads as a change to a YAML string blob.
3. **Guard A inverts into a collision check** — "does the caller already ship a
   `cliff.toml` this workflow is about to ignore?" — the same class of silent
   format-switch failure, pointed the other way.
4. **Un-adopted old tags stop failing loudly.** Under C they run and render with
   the shared config, because there is no missing config to detect.
5. **No per-project customization** without adding `workflow_call` inputs — at
   which point some configuration lives in the caller anyway and A has been
   re-adopted.

**C's genuine advantage, recorded honestly:** the config version and the
workflow version become the same object. No third pin, no second checkout, and a
private shared repository would need no token.

**The decisive argument for A over C:** with an immutable pin, C does not save
you from touching every repository. Pushing a config change to a project still
means bumping that project's pin, which is a commit in that repository either
way. C only makes the edit smaller — one line instead of one file. Taking a
moving pin to avoid that is accepting exactly the silent re-rendering the guards
exist to prevent.

One thing that is *not* a discriminator: the repository-URL problem. Once the
config derives its URL from `remote.github.owner` / `remote.github.repo` with
`--github-repo` and `--offline`, that cost falls equally on all three shapes.
It stopped distinguishing them at that point.

## Other rejected structures

**A script in this repository, called by the workflow.** A reusable workflow
runs in the caller's context and GitHub makes only the workflow file available —
no sibling file in this repository exists on the runner. Reaching
`scripts/check-release-notes.sh` needs a second `actions/checkout` with
`repository:`, `ref:` and `path:`. The ref derivation is worse than untested:
`github.job_workflow_sha` is documented as the reusable workflow file's commit
SHA but is reported to return the workflow repository's *latest* commit,
changing whenever an unrelated file such as `README.md` is pushed
([community discussion #146280](https://github.com/orgs/community/discussions/146280)).
Anyone revisiting this will reach for that variable first. It is not a reliable
pin.

**A composite action.** The mechanism works: `uses: owner/repo/path@ref` makes
the whole action repository available at runtime and `$GITHUB_ACTION_PATH`
locates files shipped beside `action.yml`, with no manual checkout. Its cost is
that a reusable workflow cannot write `uses: ./actions/<name>` — relative action
refs resolve against the *caller's* workspace
([#107558](https://github.com/orgs/community/discussions/107558),
[#167025](https://github.com/orgs/community/discussions/167025)) — so this
workflow would carry a self-referential full-path pin, bumped on every guard
edit and unresolvable until after the commit exists. Recorded as viable, not
built. Revisit only once the guard stops changing.

**A wider input surface.** `git-cliff-version` as an input defeats the pin: a
consumer could set 2.14 and get different rendering from a workflow whose SHA
claims it was proven. `stable-tag-pattern` breaks the one-regex-two-uses
invariant unless it also drives the pre-release flag. The rule instead:

> Every hardcoded value is one that was verified; every input is a knob a
> consumer can turn to an unverified value. Widening later is backward
> compatible, narrowing is not.

An optional `artifact-glob`, for a notes-only repository with no binaries, is a
known future input rather than a hypothetical one. It is not added yet because
nothing currently exercises the empty-glob path, and it would ship unproven.

## Open question

`permissions: contents: write` is declared at workflow level in this workflow.
How that interacts with a caller's own `permissions` block and the caller's
default token scope is **not assumed**. The first real call answers it, and the
observed result belongs here — including whether the caller needs its own block.
