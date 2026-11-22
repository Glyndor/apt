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
- **Sign every commit off** with `git commit -s`, using your GitHub noreply address
  (`git config user.email`). The `dco` check is required and it is the only thing
  standing behind that attestation; `commit-hygiene.yml` rejects any other address
  in the author, `Signed-off-by` or `Co-authored-by`, and a line that looks like a credential.
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
# The completeness check takes the other test files as arguments and runs them
# itself, so this command runs each suite exactly once. On its own it only
# prints its usage.
# shellcheck disable=SC2086
# A runner that is not executable must fail the command, not skip the suites.
if [ -x tests/ci/suites/check-suite-completeness.test.sh ]; then
  tests/ci/suites/check-suite-completeness.test.sh $(printf '%s\n' "$suite" | grep -v check-suite-completeness) || fail=1
else
  echo "FAILED: tests/ci/suites/check-suite-completeness.test.sh is not executable"; fail=1
fi
git ls-files -z | xargs -0 grep -lIE '^#!.*(ba)?sh' | xargs shellcheck || fail=1
[ "$fail" -eq 0 ] && echo "all green" || echo "SOMETHING FAILED"
[ "$fail" -eq 0 ]
```

`tests/verify/verify-debs-mldsa.test.sh` also needs `cryptography` 50.0.2 or later, for
ML-DSA-65, which no Ubuntu release packages yet. Without it that suite fails and says so,
and the command above goes red. Install the pinned wheel into a virtual environment that
still sees the system packages, and put it first on `PATH` before running the command:

```bash
python3 -m venv --system-site-packages ~/.cache/apt-mldsa
~/.cache/apt-mldsa/bin/python -m pip install --require-hashes --only-binary=:all: \
  -r scripts/verify/verify-debs-requirements.txt
export PATH="$HOME/.cache/apt-mldsa/bin:$PATH"
```

CI runs that suite in its own job, `ML-DSA-65 verifier` in `tests.yml`. The job
always starts and reports under that name, and decides in its first step whether
anything the suite reads changed: when nothing did, the wheel install and the
suite are skipped and the job says so in its summary. It asks the same question
on a pull request and on a push to main, and any doubt runs the suite.

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

**Every script in `scripts/` needs a test.** `scripts/quality/coverage/check-test-coverage.sh`
fails when one does not, itself included: it lives in `scripts/`, so deleting
its test makes it report itself.

**Where a script of `scripts/quality/` goes.** The folder is split by what the
script decides, and `tests/quality/` mirrors it with the test at the same depth
as its script, which the coverage check above enforces:

| Folder | What its scripts decide |
|---|---|
| `hygiene/` | that the tree and its commits agree with the rules the repository states: `.editorconfig`, commit identities, secrets |
| `lint/` | static rules over workflows and shell: action pins, the shell inside `run:` blocks, a required job that cannot be switched off or weakened by what its caller passes, tooling next to a secret |
| `scope/` | which jobs, suites and mutation entries a change can affect, with the maps they read |
| `coverage/` | that every script has a test, every suite is run by a workflow and every refusal has a mutation entry or an exemption, with the list of suites no workflow can run |

**A test you have not watched fail is not a test.** Before claiming a check
works, delete or invert the control it covers, run it, and confirm it goes red
for the reason it names. Three ways that goes wrong: a sabotage that changes
nothing, one that changes something the test does not look at, and one where the
red comes from somewhere else entirely.

Assert **which** failure fired, never that some failure did. Every script runs
under `set -e` (`set -euo pipefail` in bash, `set -eu` in the POSIX shell ones), so almost any mistake exits non-zero and a bare
non-zero assertion is satisfied by the failure you did not mean.

New test files must be added to `test-command` in `.github/workflows/tests.yml`.
`tests/ci/suites/ci-runs-every-test.test.sh` fails when one is not. An unregistered test
sits in `tests/`, passes by hand, and reads as coverage while CI never runs it.
So does the `workflow-lint` check, which runs `scripts/quality/coverage/check-suites-wired.sh`
outside the test job: a pull request that drops the watcher from the list along
with other suites leaves the test job green, and turns that check red.
A suite that cannot run on a pull request goes in `scripts/quality/coverage/suite-exemptions.txt`
with its reason. That list is read from the base commit too, so an entry takes
effect from the pull request after the one that adds it.

**A new suite needs an entry in `scripts/quality/scope/suite-scope.txt`.**
On a pull request the runner skips the suites whose paths the change does not touch;
`tests/quality/scope/suite-scope-map.test.sh` reports a suite with no entry, which would
run every time. List every path the suite reads: a missing path lets a change merge
without the suite that should have judged it, while an extra one only costs a run. A
change to the map, to `scripts/quality/scope/ci-job-scope.sh` or to the runner runs everything.
A suite that only a job of its own runs, such as the ML-DSA-65 one, has its entry here
too, and the same test checks it: that job asks `ci-job-scope.sh suite-needed` before it
installs anything.

Two traps a local run cannot see:

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
| `freshness.yml` | something scheduled stopped happening elsewhere, or a tool pinned in a reusable fell behind its upstream release |
| `dco.yml`, `line-limit.yml`, `workflow-lint.yml` | one rule each |
| `commit-hygiene.yml` | a commit carries a personal email address, or the change adds a line shaped like a credential; both scripts are read from the base commit, so a change to either takes effect once it is merged |
| `publish.yml` | the daily build and upload of the archive |
| `health-check.yml` | the published archive is stale, unreachable or unsigned |
| `distro-floor.yml` | a release the README lists as supported stops installing, or the unsupported one stops being refused |
| `drift.yml` | this repository's reusables or shared files differ from the sibling channels |
| `roster-releases.yml` | a product of the publish roster has no usable release (advisory, only on pull requests that change the roster) |
| `mutation.yml` | a guard the suite would no longer notice, broken on purpose: every catalogued guard once a week, and on a pull request the ones it can affect (its `gate` job tells a sweep that was not needed from one that did not run) |

Every reusable this repository calls lives in `.github/workflows/reusable-*.yml`
as a copy kept identical in logic to the
copies in the sibling channels (`scripts/monitoring/check-reusable-drift.sh` compares
them). The comparison does fetch the sibling copies, read-only and size-capped, from `raw.githubusercontent.com`; it runs in `drift.yml`, and the test job fetches nothing.

**Job ids are load-bearing.** A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check and
creates a phantom the ruleset still requires, which blocks every pull request
with no explanation. Move jobs between files freely; renaming one is a ruleset
change.

## Security

Never open a public issue for a vulnerability. Use the Security tab →
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and
is deliberately not duplicated in this repository.
