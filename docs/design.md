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

Seven fixtures, six distinct behaviours, originally run by hand against real
generated files; the table records that original evidence. Since 2026-07-24,
`tools/fixtures/run.sh` re-runs six of the seven behaviours through the replay
module and asserts the exact count-bearing lines — a future edit to the guard
now has a regression net. Two honesty notes on substrate: the FAIL rows run
against synthetic repositories whose rigged configs (`tools/fixtures/*.toml`)
legitimately reproduce each observable, because the step as a whole cannot
render one artifact and assert against another; and the first-release row
replays this repository's own `v1.0.0` (2 bullets), not the original 11-bullet
consumer file. The `GITHUB_REPOSITORY`-unset row stays hand-verified only,
deliberately: `replay.sh` validates the slug before the step runs, and
machinery to bypass that would outweigh the one guard line it protects.

| Fixture | Result | Detail |
| --- | --- | --- |
| `v2.0.0`, normal release | PASS | 12 bullets, 12 ours, 1 compare |
| `v1.0.0`, first release | PASS | 11 bullets, 11 ours, 0 compare |
| unset owner/repo | FAIL | `0/12 commit link(s) point at …` |
| config copied, wrong repo | FAIL | same message |
| missing config, default fallback | FAIL | `12 bullet(s) but 0 commit link(s)` |
| empty file | FAIL | `no bullets rendered` |
| `GITHUB_REPOSITORY` unset | FAIL | `cannot verify link ownership` |

## The replay module

`tools/replay.sh` re-runs the `Generate changelog` step locally: it extracts
the step's `run:` block out of `release.yml` at run time (selected by the
step's `id: changelog`, via `npx js-yaml@4` and node — the same toolchain the
step itself already requires), creates a temporary worktree of a consumer's
clone detached at a tag, and executes the extracted script there under
`bash -e` with `TAG`, `GITHUB_REPOSITORY`, and `GITHUB_OUTPUT` set the way the
runner sets them. That three-key set is an invariant the script enforces, not
a description: extraction also reads the step's `env:` map and dies, naming
the key, if the step ever carries one the replay does not supply. The `${{ }}`
values cannot be evaluated locally, so the key set is the contract — without
the assertion a new env key would expand empty inside a step that has no
`set -u`, and the replay would go green while executing something the runner
would not.

It exists because the previous local procedure required copying guard B's
assertions out of the workflow by hand — roughly fifteen lines re-typed for
every verification session, with nothing to notice a stale transcription. The
replay executes the workflow's own text, so the two cannot drift; if the step
is renamed or restructured, extraction fails loudly instead of replaying
something stale.

Decisions that look arbitrary and are not:

- **The seam points from the script to the workflow, never the reverse.**
  GitHub fetches a called workflow as a single file; no sibling file in this
  repository exists on the runner. The workflow must never grow a reference to
  `tools/replay.sh` or anything else here — the script reads the workflow, and
  CI behaviour is unchanged by this module's existence.
- **`bash -e`, not plain bash and not pipefail.** The runner's default shell
  for an unspecified `shell:` is `bash -e {0}`; both failure cases documented
  in "Absence of `set -euo pipefail`" depend on it, and a replay under a
  different shell would prove nothing about the runner.
- **`GITHUB_REPOSITORY` is derived from the consumer clone's `origin`**, with
  an explicit third-argument override, because on a runner it is always the
  consuming repository. A wrong value fails guard B loudly rather than passing
  quietly.
- **The step runs from a temp file, not `bash -c`**, matching the runner's
  `{0}` file-argument invocation.
- **On failure the worktree is kept** and its path printed: guard B's message
  names the counts, but diagnosing them needs the rendered file. On success
  the notes are preserved to a temp path and the worktree removed.

Verified locally on 2026-07-24 against a synthetic consumer: a stable tag with
config rendered 2 bullets, 2 owned links, 0 compare links, `prerelease=false`
(guard B pass, `--tag-pattern` branch taken); a pre-release tag on a commit
without `cliff.toml` tripped guard A with the step's own `::error::` line,
exit 1, worktree preserved.

**A green replay is not runner proof.** It shares the runner's git-cliff
version, config, shell, and guards, but not its checkout action, environment,
or the release publication path. The runner procedure below remains the only
proof; the replay only decides whether a tag is worth spending on it.
`tools/fixtures/run.sh` re-runs the fixture behaviours on top of this module —
see "Fixture evidence" above for what it covers and what stays frozen.

## The doc-fact check

The same facts are deliberately restated across README.md, docs/design.md,
CLAUDE.md, and the workflow — the documentation split serves different
audiences and stays. What must not happen is the copies drifting apart with
nothing to notice. `tools/check-docs.sh` asserts the mechanically decidable
ones:

- every `git-cliff@<version>` token and every "pinned at `<version>`" claim in
  any tracked file names the version in `release.yml`;
- every `js-yaml@<version>` token names the version in `tools/replay.sh`;
- design.md quotes the workflow's `STABLE_RE` verbatim;
- the current-release triplet agrees: README's `# vX.Y.Z` pin comments and
  design.md's "`vX.Y.Z` is current. It marks `<sha>`" claim both match the
  highest stable tag in the clone and the commit it peels to.

Each authority is extracted from its file at run time, never re-typed — the
same seam direction as the replay, for the same reason; even `STABLE_RE` is
read out of the workflow rather than becoming a third copy of the regex.
Version tokens are swept across all tracked files, so a new duplication site
is covered the day it is written. The check is offline: release-object
existence stays a runbook rule, because a network dependency in a drift check
is how a drift check stops being run.

Deliberately out of scope: prose. The pipefail ban is already netted
mechanically by the fixture harness — adding `set -euo pipefail` to the step
makes the no-links and empty fixtures mismatch — and the first-line
release-notes rule has nothing local to assert against.

While cutting a release, the check fails by design between updating the docs
to the new version and the tag existing (or vice versa) — the runbook orders
it after tagging so a green run means the docs and the tag agree.

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

**Proven, both halves.** A reusable workflow resolves by SHA when that commit
carries **no tag** — MTProto-Checker run 29806734545 called `1e1e8af…` before
any tag existed on it. And it resolves when that commit is reachable **only
from a non-default branch, and is not even that branch's tip** — run
29811478962 called `ba7baa2…`, a commit that lived on `feat/notes-only`, had
**never been on `main`**, carried no tag, and had already been overtaken as
that branch's tip by a later docs commit. Both jobs ran.

Nothing about the pin depends on tags, on the default branch, or on the commit
being current. Any reachable commit SHA works, which is what makes "commit,
test the SHA, tag that same commit afterwards" a valid order.

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

**`config-path`, removed after v1.0.0.** It shipped in v1.0.0 with a default of
`cliff.toml`, and no consumer ever set it — MTProto-Checker's caller does not
reference it, and no run has exercised a non-default value. By the rule above it
should never have shipped: it was a knob a consumer could turn to an unverified
value, added for a need nobody had. Removed while the cost of removing is zero;
widening is backward compatible, so it comes back the day someone needs it. The
config path is once again the literal `cliff.toml`, in guard A and in the
`-c cliff.toml` flag, both of which runs 29806734545 and 29811478962 exercised.

An optional `artifact-glob`, for a notes-only repository with no binaries, was
held back at v1.0.0 for exactly that reason — nothing exercised the empty-glob
path, so it would have shipped unproven. It was added in v1.1.0 once a run
exercised it. See "Notes-only mode" below.

## Notes-only mode

`artifact-glob` is optional. Omitted, it is the empty string, and the two
artifact steps carry `if: inputs.artifact-glob != ''`.

**Skipped, not run empty.** `actions/download-artifact@v4` with nothing to
download and `ls -l` with an empty pattern would each fail for the wrong reason
— a failure that reads as a broken workflow rather than a repository with no
binaries.

**`Create Release` needs no condition.** `softprops/action-gh-release` parses
`files` with

```typescript
files.split(/\r?\n/).flatMap(smartSplit).filter((pat) => pat.trim() !== '')
```

so `''` yields `[]`, and the upload block is guarded by
`if (config.input_files && config.input_files.length > 0)` — it is skipped
entirely. No warning, no error, no assets. Leaving the step unconditional is
what keeps the with-glob path byte-identical to v1.0.0.

The `inputs` context is readable from `jobs.<job_id>.steps.*`, which is what
makes a step-level `if` on an input legal at all.

## Proven on a runner

MTProto-Checker run
[29806734545](https://github.com/rahgozar94725/MTProto-Checker/actions/runs/29806734545),
from a throwaway branch at tag `v0.0.1-test.2`, calling commit `1e1e8af…` —
the commit this repository's `v1.0.0` tags.

```
changelog OK: 7 bullet(s), 7 link(s) to rahgozar94725/MTProto-Checker, 1 compare link(s)
```

Four groups rendered in prefix order — 📚 Documentation, 🏗️ Build, ⚙️ CI,
🧹 Misc — with the emoji surviving to the rendered release page, including the
variation selector in ⚙️. The `⚙️ CI` group was new to that render, which is
what tested the `<!-- N -->` sort prefix on a group no earlier run had produced.
`prerelease` was `true`, five assets matched `binary-*/*`, and `latest` still
resolved to `v2.0.1`. The branch, tag and release were removed afterwards; the
run log remains.

**What the byte-comparison actually compared.** The published body was diffed
against a *local render of the same seven commits*, not against the earlier
proof run `29800347803`, whose release was deleted and whose body is not
recoverable. Only that run's log line — `6 bullet(s), 6 commit link(s)` —
survives, and it is consistent. The comparison is therefore evidence that the
workflow renders what git-cliff renders locally, not that it reproduces a prior
release byte-for-byte. Regenerating the earlier proof was judged not worth a
third tag.

The published body differed from the local render by exactly one byte: a
trailing newline GitHub appends on storage.

### Notes-only mode

MTProto-Checker run
[29811478962](https://github.com/rahgozar94725/MTProto-Checker/actions/runs/29811478962),
tag `v0.0.1-test.3`, from a throwaway branch whose `release.yml` had **no build
job and no `with:` block at all** — the input was omitted entirely, not passed
empty.

```
Download all artifacts   completed/skipped
List artifacts           completed/skipped
Create Release           completed/success
```

Both artifact steps **skipped**, not run-and-found-nothing. The release carried
0 assets, `prerelease: true`, and notes identical to the local render but for
the same one trailing newline — 7 bullets across 📚 Documentation, 🏗️ Build,
⚙️ CI and 🧹 Misc, with
`changelog OK: 7 bullet(s), 7 link(s) to rahgozar94725/MTProto-Checker, 1 compare link(s)`.

`softprops/action-gh-release` emitted **no** `does not include a valid file`
warning, confirming the empty `files` value is filtered to an empty list rather
than treated as a pattern that matched nothing.

The with-glob path was not re-observed in *that* run — one tag exercises one
caller — and for a while it was argued only from the diff. It has since been
observed: see below.

### With-glob, after config-path was removed

MTProto-Checker run
[29814878431](https://github.com/rahgozar94725/MTProto-Checker/actions/runs/29814878431),
tag `v0.0.1-test.4`, calling `e17e401` — the commit `v2.0.0` marks. The caller
was the converted `main` with a single line changed, the pin; `cliff.toml` was
untouched.

```
Download all artifacts   success   ← skipped in the notes-only run
List artifacts           success   ← skipped in the notes-only run
Create Release           success
```

`artifact-glob: binary-*/*` listed five files and the release carried all five
assets, with the same body-vs-local-render one-byte trailing-newline delta.

This run does double duty. It is the first execution of the with-glob path since
`artifact-glob` became optional, so the two `if:` conditions are now **observed
in both directions** — skipped in run 29811478962, executed here, same workflow
lineage. And it is the first execution of the workflow with `config-path`
removed, confirming that guard A against the literal `cliff.toml` and the
`-c cliff.toml` invocation behave exactly as the `${CONFIG}` form did.

## Known limitation: breaking changes render as ordinary bullets

`cliff.toml` defines no breaking-change group and sets
`protect_breaking_commits = false`, so **`feat!` and `fix!` are
indistinguishable from `feat` and `fix` in the output.** A commit that removes
an input renders as a plain bullet under 🚀 Features, and a reader of the
release page sees nothing marking it as breaking.

Not fixed in v2.0.0. Changing `cliff.toml` means re-proving the rendering, and
shipping what is already proven beats shipping what is tidier. v2.0.0 works
around it by hand: the first line of its release notes states the removal and
says no action is needed unless the reader set `config-path`.

A candidate for the next version. When it is taken up, note that changing group
names is exactly the kind of change the first-line rule exists for — every
consumer holds its own copy of `cliff.toml`, and nothing here updates it.

## A known wart on v1.0.0

**`v1.0.0`'s tree contains `release-workflows.zip`, 90,723 bytes.** It was swept
in by `git add -A` during the amend chain that produced `1e1e8af`. A second,
larger copy — 189,186 bytes — sits in `ad7cc13`, which is an ancestor of `main`.
Both are permanent.

What is inside, audited rather than assumed:

- The 7 files public at that commit, **plus
  `docs/superpowers/specs/2026-07-21-…-design.md`** (14,170 bytes), which is
  gitignored and published nowhere else. This is the only content in the archive
  that is not otherwise public.
- A complete embedded `.git`. Among its commits, **`6b37600` exists nowhere in
  the public history** — it is the pre-amend draft of what became `1e1e8af`, so
  the tag ships a snapshot of a commit nobody can otherwise see.
  `93ed0a9` and `b1ebf39` are likewise orphaned amend drafts. The larger copy
  additionally carries two stash objects (`2a0358a`, `49b7727`).
- **No credentials.** The remote is the plain public URL, there is no embedded
  token, and the only "token" matches anywhere are the word appearing in prose.

Reachability: a consumer calling the workflow **never fetches it** — GitHub
sends only the workflow file. But it is fully public —
`raw.githubusercontent.com/…/v1.0.0/release-workflows.zip` returns 200, and the
tag's auto-generated source archive includes it.

**Not corrected, deliberately.** Deleting or moving the `v1.0.0` tag would
remove nothing: consumers pin the *commit* `1e1e8af`, the blob is reachable
through that SHA directly, and a second copy lives in `ad7cc13`. Only a history
rewrite removes it — which changes every SHA after `ee6c17f`, breaks
MTProto-Checker's pin, forces `v1.0.0` onto a commit that never ran, and leaves
runs 29806734545 and 29811478962 referencing commits that no longer exist. That
destroys the property this whole project is built on — the tag marks the commit
that ran — to remove 90 KB of junk. GitHub also retains unreachable objects
until asked to GC, so the rewrite would not even guarantee removal.

Hygiene, not privacy. Trading a real guarantee for a cosmetic one is the wrong
direction. Prevention instead: `*.zip` is gitignored, `git add -A` is banned in
`CLAUDE.md`, and archives are built outside the repository.

## Notes for whoever edits this next

### Where things stand

**`v2.0.0` is current.** It marks `e17e401`, has a GitHub release object, and is
what a new consumer should pin. Both of its changes were executed by a runner
before it was tagged: notes-only by run 29811478962, with-glob and the
`config-path` removal by run 29814878431.

**`v1.0.0` is superseded** and carries the zip wart described above. Do not
recommend it, and do not try to clean it — that decision is recorded and
deliberate.

**MTProto-Checker is a live consumer, still pinned to `v1.0.0`, deliberately.**
Bumping it to `v2.0.0` is **optional and buys it nothing**: it sets
`artifact-glob`, so the optional-input change does not affect it, and it never
set `config-path`, so the removal does not either. Its current pin is proven and
working. Leave it unless there is a reason.

### Still open

- **CDN-Config-Generator has not been adopted.** It is the notes-only case this
  feature was built for — a static site with no build artifacts. It needs its
  own task with its own brief; its preconditions (conventional commits, a `v*`
  tag, a `cliff.toml`) have never been checked.
- **Breaking changes render as ordinary bullets.** `cliff.toml` has no
  breaking-change group, so `feat!` is indistinguishable from `feat` in the
  output. The first-line rule in the release notes is the only mitigation and it
  is entirely manual — nothing enforces it.
- **Whether the caller's `permissions` block is strictly required is untested.**
  Every run so far had it present at both caller and callee. See "Permissions"
  below.

### History that still matters

**`v1.0.0` is a bare tag, and the README's instruction is still correct.**
No GitHub release object was created for it. GitHub serves
`/releases/tag/<tag>` with a 200 for any tag regardless, verified for
`v1.0.0`, so "pick a tag from the releases page and copy the commit SHA it
points at" works as written. Do not rewrite it to point at `/tags`, and do not
cut a release object just to make it true — it already is.

**`v1.0.0`'s own copy of this file predates the post-run caveats above.** The
tag marks `1e1e8af…`, the commit that actually ran; the caveats landed in the
commit after it. The tag was deliberately not re-pointed at the newer commit:
doing so would pin consumers to code no run has exercised in order to ship a
newer copy of a document, trading the one property the SHA pin exists to protect
for the least important one. **`main` is the living record**; a tag's copy is a
snapshot.

**MTProto-Checker is converted. That work is complete, not pending.** Its `main`
is `e2a068a` — "build(release): call the shared reusable release workflow" —
parented directly on `5b8aeb9`, pinned to `1e1e8af…` (`v1.0.0`) with
`artifact-glob: 'binary-*/*'`, and carrying the derived-URL `cliff.toml`. It is
a **live consumer**: a mistake on that repository's `main` breaks a real release
pipeline, so anything done there needs its pre-state recorded and its post-state
proven, not merely its scratch branches deleted.

`edb43e0`, the earlier local-only commit carrying the *literal* URL form of
`cliff.toml`, was replaced rather than pushed, exactly as intended — the
conversion commit carries the derived-URL config and the `uses:` call together.
`edb43e0` is now a dangling object contained by no branch, of historical
interest only. Earlier revisions of this file described that replacement as
future work; it has happened.

## Permissions

`permissions: contents: write` is declared at workflow level here, and the
README tells consumers to keep the same declaration in their caller. Only one
configuration has ever run: **both present**. Runs 29806734545 and 29811478962
each had the caller declaring it, and each published.

**Minimality was never established.** Whether this workflow's own declaration
suffices without the caller's is untested, and no tag will be spent proving it.

The likely reason it belongs at the caller: GitHub's documentation states that
for reusable workflows, "permissions can only be maintained or reduced—not
elevated—throughout the chain." A called workflow can therefore narrow the
caller's token but never widen it, so a caller whose token lacks
`contents: write` cannot be rescued by anything declared here. That makes the
caller's block the load-bearing one and this one a floor, which is why the
README states it as an instruction rather than a suggestion.
