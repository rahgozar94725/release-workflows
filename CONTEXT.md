# Release Workflows

A single reusable GitHub Actions workflow that renders release notes with
git-cliff and publishes a GitHub release for consuming repositories.

## Language

**Consumer**:
A repository that calls the reusable workflow via `workflow_call`, pinned by
commit SHA, holding its own copy of `cliff.toml`.
_Avoid_: caller (in docs — fine in YAML comments), client, downstream repo

**Guard A**:
The assertion that `cliff.toml` exists in the tag's tree before rendering, so
git-cliff cannot silently fall back to its built-in default format.
_Avoid_: config check, precondition

**Guard B**:
The shape assertion run against the rendered notes: bullets exist, every bullet
carries exactly one commit link, every link points at the consumer, and any
compare link points at the consumer.
_Avoid_: shape check, output validation, lint

**Fixture**:
A recorded guard behaviour against a known artifact: a repository state plus
the exact outcome line it must produce. Originally hand-verified evidence; six
of the seven behaviours are now re-run through the replay.
_Avoid_: test case, sample, golden file

**Replay**:
Local re-execution of the workflow's `Generate changelog` step — extracted
verbatim from the workflow file, never re-typed — against a consumer checkout
detached at a tag. Catches render and guard regressions before a tag is spent;
it is not runner proof.
_Avoid_: local test, dry run, simulation

**Runner proof**:
Evidence from an actual GitHub Actions run in a consumer, compared against a
prediction written down beforehand. The only evidence this project treats as
real.
_Avoid_: verification (unqualified), e2e test
