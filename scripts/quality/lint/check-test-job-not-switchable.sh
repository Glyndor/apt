#!/usr/bin/env bash
# Fail when a caller of a local reusable workflow can switch the check it
# defines off without failing it. The required checks are all of that shape:
# `shell / test` (reusable-shell-ci.yml), `dco` (reusable-dco.yml),
# `line limit` (reusable-line-limit.yml), `workflow-lint`
# (reusable-workflow-lint.yml) and `empty diff` (reusable-empty-diff.yml).
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
#   - a caller of any local reusable (`uses: ./.github/workflows/reusable-*`)
#     that carries a job-level `if:` of any value, `needs:` or
#     `continue-on-error:`. Any conditional on a caller of a required job is a
#     switch: a skipped required check reports Success, and a job allowed to
#     fail lets a red suite through. The one way out is a condition that is in
#     CONDITIONAL_CALLERS below, by workflow file, job, reusable and exact
#     value, and the comment above each says why that condition is not a
#     switch.
#     The condition is compared by presence and by value: an `if:` with no
#     value, which YAML reads as null, is still an `if:`.
#   - a caller of a local reusable that passes an input the reusable's entry in
#     ALLOWED_INPUTS below does not list. The inputs that weaken a check
#     (`tooling-isolation`, `severity`, `check-exec-bit`, `hard-limit`,
#     `soft-limit`, `exclude-pattern`) switch it off as surely as an `if:` does,
#     and no suite reads the values a caller hands over. The list is closed: a
#     local reusable with no entry fails the rule until someone declares what its
#     callers may pass. `extensions` of reusable-line-limit.yml may grow but may
#     not shrink: a caller keeps every extension the callers of the base commit
#     (BASE_SHA, the commit the pull request event names) pass, since dropping
#     `sh` from the list is a way not to measure the scripts. The list is
#     lowercase words of letters and digits with one space between two of them
#     and nothing else: the reusable turns it into a regular expression, so a
#     new line, a tab, a `|` or a bracket would mean to it something the rule
#     does not read.
#   - for a caller of reusable-shell-ci.yml, a test-command whose first
#     non-blank token is not a suite invocation.
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
# The test-command rules and the no-caller rule below are about the one
# reusable that carries a command, reusable-shell-ci.yml. The refusals of the
# switches are about every local reusable.
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
# BASE_SHA, when set, names the commit the extensions of a caller are held to.
set -euo pipefail
cd "${1:-$PWD}"
python3 -I - <<'PY'
import glob
import os
import re
import subprocess
import sys

import yaml

# The reusable that defines the required `shell / test` check, and carries the
# test-command the grammar below judges.
REUSABLE = "reusable-shell-ci.yml"

# A caller of a local reusable is a call of a file under this directory whose
# name starts with `reusable-`. A call of a workflow in another repository is
# not one: it names a revision, and the copy it runs is not this tree's.
LOCAL_REUSABLE_RE = re.compile(
    r"^\./\.github/workflows/(reusable-[A-Za-z0-9_.-]+\.ya?ml)$"
)

# The callers that carry a condition on purpose, as
# (workflow file, job, reusable) -> {key: exact value}. A caller is accepted
# with a switch key only when the key and its whole value are the ones listed
# here; `continue-on-error:` has no entry, so it is never accepted. None of the
# callers below is a required check: freshness.yml says its jobs may not become
# one, so a skipped one reports on nothing a merge depends on. Each condition
# only makes the watcher wait for the job that decides whether it applies.
_SCOPE_IF = "${{ !cancelled() && needs.scope.outputs.%s != 'false' }}"
_SCOPED = lambda key: {"if": _SCOPE_IF % key, "needs": "scope"}  # noqa: E731
CONDITIONAL_CALLERS = {
    # scoop-bucket: the published-bytes watcher waits for the job that says
    # whether the manifests are published yet.
    (
        ".github/workflows/freshness.yml",
        "freshness-published-bytes",
        "reusable-schedule-freshness.yml",
    ): {
        "if": "needs.published-bytes-ready.outputs.ready == 'true'",
        "needs": "published-bytes-ready",
    },
    # apt: each watcher waits for the `scope` job, which decides from the
    # changed paths whether the watcher applies to this run.
    (
        ".github/workflows/freshness.yml",
        "dependabot-freshness",
        "reusable-dependabot-freshness.yml",
    ): _SCOPED("dependabot"),
    **{
        (
            ".github/workflows/freshness.yml",
            job,
            "reusable-schedule-freshness.yml",
        ): _SCOPED("schedule")
        for job in (
            "freshness-publish",
            "freshness-distro-floor",
            "freshness-health-check",
            "freshness-itself",
            "freshness-drift",
            "freshness-mutation",
        )
    },
}

# The inputs a caller may pass to each local reusable, by reusable. The list is
# closed. An input that is not here is refused, whatever its value, because the
# ones a caller could use to weaken the check are the ones nothing else reads:
# `tooling-isolation` (reusable-workflow-lint.yml) turns the secret rule off,
# `severity` and `check-exec-bit` (reusable-shell-ci.yml) make the shell lint
# report nothing and stop looking at file modes, `hard-limit`, `soft-limit` and
# `exclude-pattern` (reusable-line-limit.yml) raise the ceiling or skip every
# file, and `working-directory` moves what the shell job looks at. The pins of
# shellcheck are read by scripts/monitoring/check-tool-versions.sh. A reusable
# that has no entry fails the rule; add one, with the inputs its callers pass
# today, in the change that adds the reusable.
ALLOWED_INPUTS = {
    "reusable-dco.yml": frozenset(),
    "reusable-dependabot-freshness.yml": frozenset({"max-age-days"}),
    "reusable-empty-diff.yml": frozenset(),
    "reusable-line-limit.yml": frozenset({"extensions"}),
    "reusable-schedule-freshness.yml": frozenset({
        "workflow", "max-age-days", "max-age-hours", "count-any-conclusion",
    }),
    "reusable-shell-ci.yml": frozenset({
        "test-command", "apt-packages", "skip-suite-paths",
    }),
    "reusable-workflow-lint.yml": frozenset(),
}

# The inputs that are a list of words a caller may add to and may not take from,
# as (reusable, input). What it keeps is what the callers of the base commit
# pass: see base_words().
KEEP_BASE_WORDS = (("reusable-line-limit.yml", "extensions"),)

# The shape of such a list: lowercase words of letters and digits, one space
# between two of them. The reusable turns the list into a regular expression
# (`\.(a|b|c)$`), so a newline, a tab, two spaces in a row or a `|`, `.*`, `(`
# or `[` would mean something else to it than to the rule that compares words.
WORD_LIST_RE = re.compile(r"[a-z0-9]+( [a-z0-9]+)*")

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


def workflow_files():
    return sorted(set(
        glob.glob(".github/workflows/*.yml")
        + glob.glob(".github/workflows/*.yaml")
    ))


def base_words(reusable, name):
    """The words every caller of `reusable` in the base commit passes as
    `name`, or None when no base commit is named (a push, a schedule, a run by
    hand). A base that is named and cannot be read stops the rule: a floor
    that cannot be read is not one the pull request has met."""
    base = os.environ.get("BASE_SHA", "")
    if not base:
        return None

    def git(*args):
        done = subprocess.run(
            ["git", *args], capture_output=True, text=True, check=False
        )
        if done.returncode != 0:
            print(f"::error::BASE_SHA {base} cannot be read: {' '.join(args)} failed")
            sys.exit(1)
        return done.stdout

    if not re.fullmatch(r"[0-9a-f]{40}", base):
        print(f"::error::BASE_SHA {base!r} is not a commit id")
        sys.exit(1)
    words = set()
    for path in git("ls-tree", "-r", "--name-only", base, "--", ".github/workflows").split("\n"):
        if not path.endswith((".yml", ".yaml")) or os.path.basename(path).startswith("reusable-"):
            continue
        try:
            spec = yaml.safe_load(git("show", f"{base}:{path}"))
        except yaml.YAMLError:
            continue
        for job in ((spec or {}).get("jobs") or {}).values() if isinstance(spec, dict) else ():
            if not isinstance(job, dict) or not isinstance(job.get("uses"), str):
                continue
            local = LOCAL_REUSABLE_RE.match(job["uses"])
            given = job.get("with")
            if local and local.group(1) == reusable and isinstance(given, dict):
                words |= set(str(given.get(name, "")).split())
    return words


def refused_inputs(job, reusable, path, job_id):
    """The refusals of what the job passes to the reusable: one per input."""
    given = job.get("with")
    if given is None:
        given = {}
    if not isinstance(given, dict):
        return [f"job `{job_id}` in {path} calls `{reusable}` with a `with:` "
                "that is not a mapping, so what it passes cannot be read."]
    found = []
    allowed = ALLOWED_INPUTS[reusable]
    for name in sorted(given, key=str):
        if name in allowed:
            continue
        listed = ", ".join(f"`{n}`" for n in sorted(allowed)) or "none"
        found.append(
            f"job `{job_id}` in {path} passes the input `{name}` to "
            f"`{reusable}`, which its callers may not pass (they may pass: "
            f"{listed}). An input a caller sets can weaken the check the "
            "reusable defines, and nothing else reads its value. Delete it; "
            "to admit one, list it in ALLOWED_INPUTS of this script."
        )
    for kept_reusable, name in KEEP_BASE_WORDS:
        if kept_reusable != reusable:
            continue
        value = given.get(name, "")
        if name in given and not (
            isinstance(value, str) and WORD_LIST_RE.fullmatch(value)
        ):
            found.append(
                f"job `{job_id}` in {path} passes the input `{name}` to "
                f"`{reusable}` as something other than lowercase words of "
                "letters and digits with one space between them. The reusable "
                "turns the list into a regular expression, and any other "
                "shape (a new line, a tab, a `|`, a `.*`, a bracket) can mean "
                "something else to it than to the rule that reads the words."
            )
            continue
        floor = base_words(reusable, name)
        if not floor:
            continue
        missing = sorted(floor - set(str(value).split(" ")))
        if missing:
            found.append(
                f"job `{job_id}` in {path} passes the input `{name}` to "
                f"`{reusable}` without {', '.join(f'`{w}`' for w in missing)}, "
                "which the callers of the base commit pass. A caller may add "
                f"to the list and may not take from it: a file type left out "
                "of it is a file the check does not measure."
            )
    return found


def main():
    files = workflow_files()

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
            if not isinstance(uses, str):
                continue
            local = LOCAL_REUSABLE_RE.match(uses)
            if local is None:
                continue
            reusable = local.group(1)
            if reusable == REUSABLE:
                callers += 1
            allowed = CONDITIONAL_CALLERS.get((path, job_id, reusable), {})
            # Rule: a job-level `if:` on a caller of a required job
            # is a switch. Any value: `false`, `inputs.foo`, even
            # `true` would skip the call when the expression is
            # false, and a skipped required check reports Success.
            if "if" in job and ("if" not in allowed or job["if"] != allowed["if"]):
                violations.append((
                    path, job_id,
                    f"job `{job_id}` in {path} calls `{reusable}` "
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
            if "needs" in job and ("needs" not in allowed or job["needs"] != allowed["needs"]):
                violations.append((
                    path, job_id,
                    f"job `{job_id}` in {path} calls `{reusable}` "
                    "and carries `needs:`. A job whose dependency is "
                    "skipped is skipped too, and a skipped required "
                    "check reports Success. Delete it."
                ))
                continue
            # Rule: `continue-on-error:` is a switch of another kind: the
            # job may fail and the run still succeeds, so a red suite does
            # not hold the merge back. GitHub does not accept the key on a
            # job that calls a reusable today; the rule refuses it anyway,
            # because the day it does, nothing else here would.
            if "continue-on-error" in job:
                violations.append((
                    path, job_id,
                    f"job `{job_id}` in {path} calls `{reusable}` "
                    "and carries `continue-on-error:`. A job that may fail "
                    "without failing the run lets a red suite through. "
                    "Delete it."
                ))
                continue
            # Rule: a caller passes only the inputs the reusable's entry of
            # ALLOWED_INPUTS lists. A reusable with no entry is refused, so a
            # new one cannot be called with anything until it is declared.
            if reusable not in ALLOWED_INPUTS:
                violations.append((
                    path, job_id,
                    f"job `{job_id}` in {path} calls `{reusable}`, which has "
                    "no entry in ALLOWED_INPUTS of this script, so what a "
                    "caller may pass to it is not declared. Add the entry, "
                    "listing the inputs its callers pass today."
                ))
                continue
            refused = refused_inputs(job, reusable, path, job_id)
            if refused:
                violations.extend((path, job_id, msg) for msg in refused)
                continue
            if reusable != REUSABLE:
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
        "runs a suite, and no caller of a local reusable carries a switch"
    )


if __name__ == "__main__":
    main()
PY
