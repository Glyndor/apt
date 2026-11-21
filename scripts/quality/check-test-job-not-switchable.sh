#!/usr/bin/env bash
# Fail when a caller of reusable-shell-ci.yml can switch the required
# `shell / test` check off without failing it.
#
# The first form of this check was a text match over the test-command block.
# Two edits walked straight past it. Job-level `if: false` on the caller leaves
# the test-command string untouched, so the grep saw nothing wrong; GitHub
# reports a skipped required check as Success and does not block a merge, so
# the suite went dark while CI stayed green. And
# `true || ./tests/first.test.sh && ./tests/second.test.sh` still contains the
# pattern the grep looked for; bash short-circuits the prefix, so the suite
# never runs.
#
# This parses the workflows instead. It refuses, each with its own message
# naming the file, the job and the reason:
#
#   - a caller of reusable-shell-ci.yml that carries a job-level `if:` of any
#     value, or `needs:`. Any conditional on a caller of a required job is a
#     switch; a skipped required check reports Success.
#   - a test-command whose first non-blank token is not a suite invocation.
#     The accepted grammar is a list of `./tests/<name>.test.sh` or
#     `bash ./tests/<name>.test.sh` invocations joined by `&&`, or the suite
#     runner followed by such invocations, optionally spread over lines with a
#     folded YAML block scalar.
#   - a literal block scalar (`|`), which turns each line into its own shell
#     statement whose failure the job would not see.
#   - the suppression forms: `|| true` anywhere in the command, a `true ||`
#     prefix, and a leading `exit 0`. All three make the suite go dark without
#     failing the required check.
#   - no caller at all. Iterating callers and finding none passes: "no
#     violations found" and "nothing to look at" produce the same green, which
#     is the exact failure this check was written against. Deleting tests.yml
#     outright would have walked straight past it.
#
# The grammar is repeated in every refusal except the no-caller one, so an
# author who trips the check learns the shape rather than guessing from "your
# command is wrong".
#
# This assertion cannot live in the shell job: that is the job the `if:`
# skips, so a check inside it shares the fate of the thing it would be
# checking. reusable-workflow-lint.yml runs it, and workflow-lint is a
# separate required check that survives.
#
# python3 runs isolated (-I): the pull request controls the working
# directory, and a module planted there must not be what gets imported.
#
# On a pull request reusable-workflow-lint.yml runs the copy of this script in
# the base commit the event names, from a temporary file outside the checkout,
# so the rule that judges a pull request is the base's. The workflow that runs
# it comes from the pull request, and a change there is for the owner's review
# of .github/workflows/ to catch. That is why the default root is the working
# directory and not this file's location.
#
# Usage: check-test-job-not-switchable.sh [repo-root]   (default: the current directory)
set -euo pipefail
cd "${1:-$PWD}"
python3 -I - <<'PY'
import glob
import os
import re
import sys

import yaml

# The reusable that defines the required `shell / test` check.
REUSABLE = "reusable-shell-ci.yml"

# A single suite invocation, as the grammar accepts it: the path
# alone, or `bash` in front of it. Names are constrained to what
# the shell treats as ordinary characters, so `./tests/a-b_c.test.sh`
# and `./tests/a-b_c/inner.test.sh` are accepted but `./tests/*`
# is not; the grammar is strict by design.
INVOCATION_RE = re.compile(
    r"^(?:bash )?\./tests/[A-Za-z0-9_./-]+\.test\.sh$"
)

# The three suppression forms. Each is matched against the command
# with whitespace normalised: newlines folded to single spaces,
# runs of whitespace collapsed.
OR_TRUE_RE = re.compile(r"\|\|\s*true")
TRUE_OR_PREFIX_RE = re.compile(r"^\s*true\s*\|\|")
EXIT_0_PREFIX_RE = re.compile(r"^\s*exit\s+0\b")

# Repeated in every grammar refusal, so an author
# who trips the check learns the shape rather than guessing.
# The runner form: one script that takes the suites as arguments,
# runs each and requires the sentinel every suite prints as its last
# line. It exists because a `&&` chain cannot tell a suite that ran
# every assertion from one that exited early having run a few, and
# both look like success. A caller using it names the runner first
# and the suites after it, whitespace separated.
RUNNER_RE = re.compile(r"^(?:bash )?\./tests/ci/suites/check-suite-completeness\.test\.sh$")

GRAMMAR = (
    "The accepted grammar is either a list of `./tests/<name>.test.sh` "
    "or `bash ./tests/<name>.test.sh` invocations joined by `&&`, or "
    "`./tests/ci/suites/check-suite-completeness.test.sh` followed by one or "
    "more such invocations as its arguments; either form may be "
    "spread over lines with YAML block scalars"
)


def normalize(value):
    # Block scalars fold newlines to spaces; collapse whitespace
    # so `&&` is the only separator left to look for.
    return " ".join(value.split())


def check_test_command(cmd, path, job_id):
    """Return None on success, else a refusal message that already
    names the file and the job."""
    if OR_TRUE_RE.search(cmd):
        return (
            f"job `{job_id}` in {path} has `|| true` in its "
            "test-command. That masks a suite failure: bash "
            "short-circuits the suite, and the required check "
            "reports Success regardless. " + GRAMMAR + "."
        )
    if TRUE_OR_PREFIX_RE.match(cmd):
        return (
            f"job `{job_id}` in {path} has a test-command that "
            "starts with `true ||`. Bash short-circuits the prefix "
            "and skips every suite. " + GRAMMAR + "."
        )
    if EXIT_0_PREFIX_RE.match(cmd):
        return (
            f"job `{job_id}` in {path} has a test-command that "
            "starts with `exit 0`. The shell exits before any "
            "suite runs. " + GRAMMAR + "."
        )
    # Two shapes, and which one this is decided by the first token.
    # The runner takes its suites as arguments, so the command is
    # whitespace separated and every argument after the runner has to
    # be a suite. Anything else is the `&&` chain: split on `&&`,
    # strip, and every part must be a suite invocation. An empty part
    # (a stray `&&`) is also a violation and falls into the
    # empty-part branch below.
    tokens = cmd.split()
    if tokens and RUNNER_RE.match(tokens[0]):
        if len(tokens) == 1:
            return (
                f"job `{job_id}` in {path} runs the suite runner with "
                "no suites to run, so the required check would report "
                "Success having tested nothing. " + GRAMMAR + "."
            )
        for arg in tokens[1:]:
            if not INVOCATION_RE.match(arg):
                return (
                    f"job `{job_id}` in {path} passes `{arg}` to the "
                    "suite runner, which is not a suite invocation. "
                    + GRAMMAR + "."
                )
        return None
    parts = [p.strip() for p in cmd.split("&&")]
    if not parts or not parts[0]:
        return (
            f"job `{job_id}` in {path} has a test-command that "
            "names no suite. " + GRAMMAR + "."
        )
    if not INVOCATION_RE.match(parts[0]):
        return (
            f"job `{job_id}` in {path} has a test-command whose "
            "first non-blank token is not a suite invocation. "
            + GRAMMAR + "."
        )
    for part in parts[1:]:
        if not INVOCATION_RE.match(part):
            return (
                f"job `{job_id}` in {path} has a test-command whose "
                "later invocations do not match the grammar. "
                + GRAMMAR + "."
            )
    return None


def main():
    files = sorted(set(
        glob.glob(".github/workflows/*.yml")
        + glob.glob(".github/workflows/*.yaml")
    ))

    callers = 0
    violations = []

    for path in files:
        name = os.path.basename(path)
        if name.startswith("reusable-"):
            continue
        try:
            with open(path) as fh:
                spec = yaml.safe_load(fh)
        except yaml.YAMLError as e:
            # Silent skip would hide a misconfigured workflow that
            # the caller is going to learn about elsewhere in CI
            # for the wrong reason. Warning annotation instead.
            print(f"::warning file={path}::skipped: YAML parse error: {e}")
            continue
        if not isinstance(spec, dict):
            continue
        jobs = spec.get("jobs") or {}
        if not isinstance(jobs, dict):
            continue
        for job_id, job in jobs.items():
            if not isinstance(job, dict):
                continue
            uses = job.get("uses")
            if not isinstance(uses, str) or REUSABLE not in uses:
                continue
            callers += 1
            # Rule: a job-level `if:` on a caller of a required job
            # is a switch. Any value: `false`, `inputs.foo`, even
            # `true` would skip the call when the expression is
            # false, and a skipped required check reports Success.
            if "if" in job:
                violations.append((
                    path, job_id,
                    f"job `{job_id}` in {path} calls `{REUSABLE}` "
                    "and carries a job-level `if:` of any value. "
                    "Any conditional on a caller of a required job "
                    "is a switch: a skipped required check reports "
                    "Success and does not block a merge. Move the "
                    "condition into the called workflow's steps, or "
                    "delete it."
                ))
                continue
            # Rule: `needs:` is the same switch one job away. A
            # caller that needs a skipped job is skipped too.
            if "needs" in job:
                violations.append((
                    path, job_id,
                    f"job `{job_id}` in {path} calls `{REUSABLE}` "
                    "and carries `needs:`. A job whose dependency is "
                    "skipped is skipped too, and a skipped required "
                    "check reports Success. Delete it."
                ))
                continue
            # Rule: the test-command must invoke at least one suite.
            with_block = job.get("with")
            tc = (
                with_block.get("test-command")
                if isinstance(with_block, dict) else None
            )
            if not isinstance(tc, str) or not tc.strip():
                violations.append((
                    path, job_id,
                    f"job `{job_id}` in {path} calls `{REUSABLE}` "
                    "without a test-command that runs any suite. "
                    + GRAMMAR + "."
                ))
                continue
            # A literal block scalar (`|`) keeps newlines, so each
            # line of the YAML value becomes its own shell
            # statement. `bash -c "$TEST_COMMAND"` then returns the
            # LAST statement's exit code, and an early failing
            # suite would not fail the required check. This is
            # checked against the RAW value, before `normalize()`
            # folds newlines to spaces.
            if "\n" in tc:
                violations.append((
                    path, job_id,
                    f"job `{job_id}` in {path} has a literal "
                    "block scalar (`|`) in its test-command, "
                    "which splits the command into separate "
                    "shell statements whose failures the job "
                    "would not see. The folded form (`>-`) or "
                    "`&&` is the accepted shape. " + GRAMMAR + "."
                ))
                continue
            err = check_test_command(normalize(tc), path, job_id)
            if err is not None:
                violations.append((path, job_id, err))

    if callers == 0:
        print(
            "::error::no workflow calls reusable-shell-ci, so the "
            "required `shell / test` check would never report"
        )
        print(
            "A required check that is never reported blocks a pull "
            "request, but nothing here would have said why."
        )
        sys.exit(1)
    if violations:
        for path, job_id, msg in violations:
            print(f"::error file={path}::{msg}")
        sys.exit(1)
    print(
        "every reusable-shell-ci caller passes a test-command that "
        "runs a suite"
    )


if __name__ == "__main__":
    main()
PY
