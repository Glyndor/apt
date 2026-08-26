# Contributing to Glyndor/apt

This repository has its own guide because the organisation's shared one
describes a `topic → develop → main` flow that does not exist here. Following it
would tell you to target a branch this repository does not have.

Contributions are invitation-only. Bug reports and ideas through issues are
welcome; unsolicited pull requests are not accepted.

## What this repository is

It builds and publishes the signed Debian archive at **apt.glyndor.net**. It
carries no product source. Everything it serves is generated from the current
signed release of each Glyndor product, verified before it is admitted, and
rebuilt from scratch on every run.

Nothing automated writes to this repository's git. `publish.yml` uploads to R2;
it never commits. That is why this repository can require pull requests and
status checks, and why `homebrew-tap` and `scoop-bucket` cannot — their
`update.yml` commits straight to `main`.

## Branch flow

```
topic branch ──PR──▶ main
```

There is no `develop`. Branch from `main`, open a pull request against `main`,
squash-merge back. Releases are tagged directly off `main`.

`Closes #N` auto-closes, because the fix lands on the default branch.

## Before you open a pull request

- **An issue first.** Labels are the tracking system here; there is no board.
  Apply `type:`, `prio:`, `effort:`, `status:` and `area:` where they fit.
- **Sign every commit off** — `git commit -s`. The `dco` check is required and
  it is the only thing standing behind that attestation.
- **Commits are signed**, GPG or SSH. `required_signatures` is enforced on
  `main`, and rebase-merge is disabled because GitHub re-creates rebased commits
  without signatures.
- **Conventional Commit title** on the pull request. It becomes the squashed
  commit message.

## Tests

Run the suite before pushing:

```sh
for t in tests/*.test.sh; do "./$t" || echo "FAILED: $t"; done
shellcheck scripts/*.sh tests/*.sh
```

Two rules matter more than coverage:

**Every script in `scripts/` needs a test.** `scripts/check-test-coverage.sh`
fails when one does not, itself included — it lives in `scripts/`, so deleting
its test makes it report itself.

**A test you have not watched fail is not a test.** Before claiming a check
works, delete or invert the control it covers, run it, and confirm it goes red
for the reason it names. Three ways that goes wrong are written up in
`standards/testing` — a sabotage that changes nothing, one that changes
something the test does not look at, and one where the red comes from
somewhere else entirely. All three were hit here in a single day.

Assert **which** failure fired, never that some failure did. Every script runs
under `set -euo pipefail`, so almost any mistake exits non-zero and a bare
non-zero assertion is satisfied by the failure you did not mean.

New test files must be added to `test-command` in `.github/workflows/tests.yml`.
`tests/ci-runs-every-test.test.sh` fails when one is not — an unregistered test
sits in `tests/`, passes by hand, and reads as coverage while CI never runs it.
That happened here.

## Workflows

CI is split by responsibility rather than gathered in one file:

| file | what fails there |
|---|---|
| `tests.yml` | the suite and shellcheck |
| `pr-hygiene.yml` | the pull request itself is malformed |
| `freshness.yml` | something scheduled stopped happening elsewhere |
| `dco.yml`, `line-limit.yml`, `workflow-lint.yml` | one rule each |
| `publish.yml` | the daily build and upload of the archive |
| `health-check.yml` | the published archive is stale, unreachable or unsigned |

Every reusable this repository calls lives in `.github/workflows/reusable-*.yml`
as a copy taken from a named `Glyndor/.github` tag. Nothing is pulled remotely.

**Job ids are load-bearing.** A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check and
creates a phantom the ruleset still requires — which blocks every pull request
with no explanation. Move jobs between files freely; renaming one is a ruleset
change.

## Security

Never open a public issue for a vulnerability. Use the Security tab →
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and
is deliberately not duplicated in this repository.
