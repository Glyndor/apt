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
status checks, and why `homebrew-tap` and `scoop-bucket` cannot. Their
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
- **Sign every commit off** with `git commit -s`. The `dco` check is required and
  it is the only thing standing behind that attestation.
- **Commits are signed**, GPG or SSH. `required_signatures` is enforced on
  `main`, and rebase-merge is disabled because GitHub re-creates rebased commits
  without signatures.
- **Conventional Commit title** on the pull request. It becomes the squashed
  commit message.

## Tests

Run the suite before pushing. It needs `reprepro`, `gnupg`, `jq`, `python3-cryptography`,
`python3-yaml` and `shellcheck` installed:

```sh
fail=0
suite=$(find tests -name '*.test.sh' -type f | sort)
# The completeness check takes the other test files as arguments; on its own it only prints its usage.
while IFS= read -r t; do
  [ "$t" = tests/ci/suites/check-suite-completeness.test.sh ] && continue
  "$t" || { echo "FAILED: $t"; fail=1; }
done <<< "$suite"
# shellcheck disable=SC2086
[ -x tests/ci/suites/check-suite-completeness.test.sh ] &&
  { tests/ci/suites/check-suite-completeness.test.sh $(grep -v check-suite-completeness <<< "$suite") || fail=1; }
git ls-files -z | xargs -0 grep -lIE '^#!.*(ba)?sh' | xargs shellcheck || fail=1
[ "$fail" -eq 0 ] && echo "all green" || echo "SOMETHING FAILED"
[ "$fail" -eq 0 ]
```

The tests live in folders that mirror `scripts/` (`tests/verify/`, `tests/build/`
and so on), so the loop finds them recursively, and the shellcheck line picks up
every tracked file that starts with a shell shebang, including the scripts under
`keyring/upgrade/` that have no extension.

The `fail` flag is not decoration. The loop runs every test instead of stopping
at the first red one, which is what you want locally, but it means the loop ends
on `echo` and reports success no matter how many scripts failed. Without the
flag the status you glance at disagrees with the output you scrolled past. CI
lists the suites one per line in `.github/workflows/tests.yml` and runs them
through one runner that runs every suite and fails at the end if any failed, so
the job goes red.
`tests/ci/suites/ci-runs-every-test.test.sh` fails when a test exists that the
list does not run.

Two rules matter more than coverage:

**Every script in `scripts/` needs a test.** `scripts/quality/check-test-coverage.sh`
fails when one does not, itself included: it lives in `scripts/`, so deleting
its test makes it report itself.

**A test you have not watched fail is not a test.** Before claiming a check
works, delete or invert the control it covers, run it, and confirm it goes red
for the reason it names. Three ways that goes wrong are written up in
`standards/testing`: a sabotage that changes nothing, one that changes
something the test does not look at, and one where the red comes from
somewhere else entirely. All three were hit here in a single day.

Assert **which** failure fired, never that some failure did. Every script runs
under `set -e` (`set -euo pipefail` in bash, `set -eu` in the POSIX shell ones), so almost any mistake exits non-zero and a bare
non-zero assertion is satisfied by the failure you did not mean.

New test files must be added to `test-command` in `.github/workflows/tests.yml`.
`tests/ci/suites/ci-runs-every-test.test.sh` fails when one is not. An unregistered test
sits in `tests/`, passes by hand, and reads as coverage while CI never runs it.
That happened here.

Two traps a local run cannot see, and both cost a day here:

**The exec bit that counts is git's.** `core.fileMode=false` is common on Linux
setups, and with it `chmod +x` never reaches the index. A test file committed
`100644` runs fine from your shell and is exit 126 on a runner, which aborts the
whole `&&` chain. Read the bit with `git ls-files -s tests/`, never with
`ls -l`, and set it with `git update-index --chmod=+x tests/<name>.test.sh`
before you commit.

**`check-editorconfig.sh` reads tracked files only**, and a test asserts it
ignores an untracked one, so a new file missing its final newline passes locally
and fails the moment it is committed. Run the checker after `git add`, not
before.

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
| `distro-floor.yml` | a release the README lists as supported stops installing, or the unsupported one stops being refused |
| `drift.yml` | this repository's reusables or shared files differ from the sibling channels |

Every reusable this repository calls lives in `.github/workflows/reusable-*.yml`
as a copy kept identical in logic to the
copies in the sibling channels (`scripts/monitoring/check-reusable-drift.sh` compares
them). Nothing is pulled remotely.

**Job ids are load-bearing.** A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check and
creates a phantom the ruleset still requires, which blocks every pull request
with no explanation. Move jobs between files freely; renaming one is a ruleset
change.

## Security

Never open a public issue for a vulnerability. Use the Security tab →
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and
is deliberately not duplicated in this repository.
