#!/usr/bin/env bash
# Fail when a job of any workflow can be switched off without failing the check
# it defines. GitHub reports a skipped required check as Success and does not
# block a merge, so every way to skip a job, or to let it fail without failing
# the run, is a way to turn a required check off. The required checks are of
# three shapes: the jobs inside the local reusables (`shell / test`,
# `shell / shellcheck`, `dco`, `line limit`, `workflow-lint`, `empty diff`),
# the jobs a workflow defines itself, and the callers that name them.
#
# The first form of this check was a text match over the test-command block.
# Two edits walked straight past it. Job-level `if: false` on the caller leaves
# the test-command string untouched, so the grep saw nothing wrong; GitHub
# reports a skipped required check as Success and does not block a merge, so
# the suite went dark while CI stayed green. And
# `true || ./tests/first.test.sh && ./tests/second.test.sh` still contains the
# pattern the grep looked for; bash short-circuits the prefix, so the suite
# never runs. The second form read only the callers of the reusables, and the
# same `if: false` on the job inside a reusable, on a job a workflow defines
# itself, or on the job that raises the alarm of the health check still left
# every suite green.
#
# This parses the workflows instead. It reads every job of every workflow file,
# the reusables and the jobs that call nothing among them, and refuses, each
# with its own message naming the file, the job and the reason:
#
#   - a job-level `if:` of any value, `needs:` or `continue-on-error:`. A
#     skipped required check reports Success, a job whose dependency is skipped
#     is skipped too, and a job allowed to fail lets a red suite through. The
#     one way out is a condition that is in CONDITIONAL_JOBS below, by workflow
#     file, job, reusable the job calls (none for a job that runs steps) and
#     exact value, and the comment above each says why that condition is not a
#     switch. `continue-on-error:` has no entry, so it is never accepted.
#     The condition is compared by presence and by value: an `if:` with no
#     value, which YAML reads as null, is still an `if:`.
#   - a step-level `if:` that STEP_CONDITIONS below does not list for its job,
#     and a step-level `continue-on-error:`. The step is the one that runs the
#     suite, the comparison or the script of the check, so a condition on it
#     skips the check as surely as one on the job does while the job and its
#     name still report Success.
#   - a caller of a local reusable (`uses: ./.github/workflows/reusable-*`)
#     that passes an input the reusable's entry in
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
#   - a condition that reads `steps.<id>.outputs` or `needs.<job>.outputs`
#     when what writes them is not what the base commit has. A condition on an
#     output is only as sound as its producer: a scope step that always writes
#     `needed=false` skips the check through a form the lists accept, and so
#     does a step before it that writes `needed=false` into $GITHUB_ENV, or an
#     `env:` of the job that changes what its `run:` sees. For a producer that
#     is a step, the context is every step of the job up to it, whole, the
#     `env`, `defaults`, `runs-on`, `container`, `services` and `permissions` of
#     the job and the `env` and `defaults` of the workflow; for a job, the whole
#     job, the `env` and `defaults` of the workflow and, when it calls a local
#     reusable, that file. A step's `name` and the pin of the action it uses are
#     left out: neither changes what runs. A producer that is new, missing or
#     different is refused, and so is one that runs a script of the repository
#     from the checkout of a pull request, which the pull request writes, in a
#     workflow a pull request can run (read it with `git show HEAD^1:<path>`,
#     as the scope steps do, into a temporary file, and run that). Without a
#     base commit (a push, a schedule) nothing is compared; a base that is
#     named and cannot be read stops the rule. A producer is
#     changed on purpose in two pull requests: the first lists it in
#     PRODUCERS_MAY_CHANGE, the second changes it and removes the entry, since
#     the base copy judges each.
#   - `skip-suite-paths` of reusable-shell-ci.yml, which decides what counts as
#     documentation only and so when `shell / test` is skipped, with the same
#     care as `extensions`: words of paths or globs that name a file, not
#     `*`, `**` or any pattern that holds no letter or digit (it would match
#     every file), and no word the callers of the base commit do not pass.
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
# inputs are about every caller of a local reusable, and the refusals of the
# switches are about every job and every step of every workflow. Both closed
# lists live in this file and not in a file of the checkout, because the copy
# of the script that judges a pull request is the base commit's: a list the
# pull request could edit would be one it could add its own switch to.
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

# The parser written in C when this PyYAML has it: the rule reads every workflow of the
# repository on every pull request, and the pure Python one takes fifteen times longer.
LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)

# The reusable that defines the required `shell / test` check, and carries the
# test-command the grammar below judges.
REUSABLE = "reusable-shell-ci.yml"

# A caller of a local reusable is a call of a file under this directory whose
# name starts with `reusable-`. A call of a workflow in another repository is
# not one: it names a revision, and the copy it runs is not this tree's.
LOCAL_REUSABLE_RE = re.compile(
    r"^\./\.github/workflows/(reusable-[A-Za-z0-9_.-]+\.ya?ml)$"
)

# The jobs that carry a condition on purpose, as
# (workflow file, job, reusable the job calls or None) -> the forms it may
# carry, each {key: exact value}, one dict or a list of them. A job is accepted
# with a switch key only when the key and its whole value are the ones listed
# here; `continue-on-error:` has no entry, so it is never accepted. The
# comment above each says why the condition does not turn a check off: it
# either follows the event the check exists for, or it belongs to a job no merge
# waits for, or it makes a watcher wait for the job that decides whether it
# applies.
_W = ".github/workflows/"
_SCOPE_IF = "${{ !cancelled() && needs.scope.outputs.%s != 'false' }}"
_SCOPED = lambda key: {"if": _SCOPE_IF % key, "needs": "scope"}  # noqa: E731
_ON_PULL_REQUEST = {"if": "github.event_name == 'pull_request'"}
CONDITIONAL_JOBS = {
    # The two jobs of the reusables that a required check names and that carry
    # a condition. `empty diff` exists for a pull request, which is the only
    # event its caller runs on; `shell / test` has nothing to run without a
    # test-command, and the rule below refuses a caller of the reusable that
    # passes none.
    (_W + "reusable-empty-diff.yml", "empty-diff", None): _ON_PULL_REQUEST,
    (_W + "reusable-shell-ci.yml", "test", None): {"if": "inputs.test-command != ''"},
    # scoop-bucket: the published-bytes watcher waits for the job that says
    # whether the manifests are published yet.
    (_W + "freshness.yml", "freshness-published-bytes", "reusable-schedule-freshness.yml"): {
        "if": "needs.published-bytes-ready.outputs.ready == 'true'", "needs": "published-bytes-ready"},
    # apt: each watcher waits for the `scope` job, which decides from the
    # changed paths whether the watcher applies to this run, and `scope` itself
    # has nothing to decide outside a pull request. None of them is a required
    # check: freshness.yml says its jobs may not become one.
    (_W + "freshness.yml", "scope", None): _ON_PULL_REQUEST,
    (_W + "freshness.yml", "suite-on-main", None): _SCOPED("suite"),
    (_W + "freshness.yml", "tool-versions", None): _SCOPED("tools"),
    (_W + "freshness.yml", "dependabot-freshness",
     "reusable-dependabot-freshness.yml"): _SCOPED("dependabot"),
    **{
        (_W + "freshness.yml", job, "reusable-schedule-freshness.yml"):
            _SCOPED("schedule")
        for job in (
            "freshness-publish",
            "freshness-distro-floor",
            "freshness-health-check",
            "freshness-itself",
            "freshness-drift",
            "freshness-mutation",
        )
    },
    # apt: the sweep runs for the entries the change can affect, and the gate
    # tells a sweep skipped by that decision from one that did not run. The
    # gate carries `always()` so that a skipped sweep does not skip it.
    (_W + "mutation.yml", "mutations", None): {"if": "${{ !cancelled() && needs.decide.outputs.run != 'false' }}", "needs": "decide"},
    (_W + "mutation.yml", "gate", None): {"if": "always()", "needs": ["decide", "mutations"]},
    # homebrew-tap: `brew audit` waits for the job that says whether the change
    # can affect it, and runs unless that job answered `false`. The gate carries
    # `always()` so that a skipped audit does not skip it, and it is the check
    # a ruleset requires: it fails unless the audit passed or was not needed.
    (_W + "audit.yml", "audit", None): _SCOPED("run_audit"),
    (_W + "audit.yml", "gate", None): {"if": "always()", "needs": ["scope", "audit"]},
    # The scheduled update: what is rendered is validated, and then committed.
    # These jobs run on a schedule and are no check a merge waits for.
    (_W + "update.yml", "validate", None): {"needs": "render"},
    (_W + "update.yml", "commit", None): [{"needs": "render"}, {"needs": ["render", "validate"]}],
}

# The step-level conditions a job may carry, as (workflow file, job) -> the
# exact values of `if:` a step of that job may have. A step that is not listed
# for its job, or whose value is not one of these, is refused: the step is the
# one that runs the suite, the comparison or the script of the check. Each
# value either reads a decision taken by a scope step from the base commit, or
# follows the event the step exists for, or keeps a report running after an
# earlier step failed. `continue-on-error:` on a step is never accepted.
_NEEDED = "steps.scope.outputs.needed != 'false'"
_CHANGED = "needs.render.outputs.changed == '1'"
STEP_CONDITIONS = {
    (_W + "reusable-line-limit.yml", "line-limit"): (_NEEDED,),
    (_W + "reusable-shell-ci.yml", "shellcheck"): (_NEEDED, "${{ inputs.check-exec-bit && " + _NEEDED + " }}"),
    (_W + "reusable-shell-ci.yml", "test"): ("steps.scope.outputs.docs_only != 'true'",),
    (_W + "reusable-workflow-lint.yml", "workflow-lint"): (_NEEDED, "${{ inputs.tooling-isolation && " + _NEEDED + " }}"),
    (_W + "tests.yml", "mldsa"): (_NEEDED,),
    (_W + "tests.yml", "formulae"): ("steps.scope.outputs.run_style != 'false'",),
    (_W + "tests.yml", "products"): ("github.event_name == 'pull_request'",),
    (_W + "tests.yml", "manifests"): ("github.event_name == 'pull_request'",),
    (_W + "freshness.yml", "suite-on-main"): ("${{ !cancelled() }}",),
    (_W + "drift.yml", "drift"): ("${{ !cancelled() }}",),
    (_W + "update.yml", "render"): ("steps.render.outputs.changed == '1'",),
    (_W + "update.yml", "validate"): (_CHANGED,),
    (_W + "update.yml", "commit"): (_CHANGED, "needs.render.outputs.partial == '1'"),
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

# The inputs that are a list of paths or globs a caller may take from and may
# not add to, as (reusable, input): the words of the base commit are the most it
# may pass. The reusable splits the value on whitespace with globbing off and
# matches every changed file against each word with `[[ == ]]`, so a word is
# made of the characters of a path and `*`, and one with no letter or digit
# (`*`, `**`, `*.*`) matches every file.
CAP_BASE_WORDS = (("reusable-shell-ci.yml", "skip-suite-paths"),)
PATH_WORD_RE = re.compile(r"[A-Za-z0-9_./*-]*[A-Za-z0-9_][A-Za-z0-9_./*-]*")

# What a condition may read: the output of a step of its job or of a job of its
# file. The producers a pull request may change on purpose, as
# (workflow file, step id or job id) pairs; see the header.
PRODUCER_REF = re.compile(r"\b(steps|needs)\.([A-Za-z0-9_-]+)\.outputs\b")
PRODUCERS_MAY_CHANGE = ()

# A script run from the checkout, at the start of a command: a path under one of
# these folders, alone or after an interpreter. `git show <rev>:<path>` is not one.
RUN_FROM_CHECKOUT = re.compile(
    r"(?:^|[;&|(`]|\$\(|\b(?:if|then|do|else|while|until)\b)\s*(?:(?:bash|sh|python3?|source|\.)\s+(?:-\S+\s+)*)?"
    r"[\"']?(?:\./)?((?:scripts|tests|keyring|\.github)/[^\s\"';)|&]+)", re.M)
JOB_CONTEXT = ("env", "defaults", "runs-on", "container", "services", "permissions")
PULL_REQUEST_EVENTS = {"pull_request", "pull_request_target", "workflow_call"}

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


# Return None on success, else a refusal message that already
# names the file and the job.
def check_test_command(cmd, path, job_id):
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


# The commit the event names, "" when none (a push, a schedule, a run by
# hand).
def base_sha():
    base = os.environ.get("BASE_SHA", "")
    if base and not re.fullmatch(r"[0-9a-f]{40}", base):
        print(f"::error::BASE_SHA {base!r} is not a commit id")
        sys.exit(1)
    return base


# What git prints for the base commit. A base that is named and cannot be
# read stops the rule: a floor that cannot be read is not one the pull
# request has met.
def base_git(base, *args):
    done = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    if done.returncode != 0:
        print(f"::error::BASE_SHA {base} cannot be read: {' '.join(args)} failed")
        sys.exit(1)
    return done.stdout


# The words every caller of `reusable` in the base commit passes as
# `name`, or None when no base commit is named.
def base_words(reusable, name):
    base = base_sha()
    if not base:
        return None
    words = set()
    for path in base_git(base, "ls-tree", "-r", "--name-only", base, "--", ".github/workflows").split("\n"):
        if not path.endswith((".yml", ".yaml")) or os.path.basename(path).startswith("reusable-"):
            continue
        try:
            spec = yaml.load(base_git(base, "show", f"{base}:{path}"), Loader=LOADER)
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


def steps_of(job):
    steps = job.get("steps") if isinstance(job, dict) else None
    return [s for s in steps if isinstance(s, dict)] if isinstance(steps, list) else []


# What a step runs, as the pin sees it: its `name` changes nothing and the pin of
# the action is a version bump.
def norm_step(step):
    out = {k: v for k, v in step.items() if k != "name"}
    if isinstance(out.get("uses"), str):
        out["uses"] = out["uses"].split("@")[0]
    return out


def norm_spec(spec):
    jobs = (spec.get("jobs") or {}).items()
    return {**spec, "jobs": {j: {**v, "steps": [norm_step(s) for s in steps_of(v)]} for j, v in jobs if isinstance(v, dict)}}


# The workflow `path` as the working tree has it (current) or the base commit has
# it, {} when it is not there or does not parse.
def spec_at(base, path, current):
    try:
        if current:
            spec = yaml.load(open(path), Loader=LOADER)
        elif base_git(base, "ls-tree", "--name-only", base, "--", path).strip():
            spec = yaml.load(base_git(base, "show", f"{base}:{path}"), Loader=LOADER)
        else:
            spec = None
    except (OSError, yaml.YAMLError):
        spec = None
    return spec if isinstance(spec, dict) else {}


# Everything the producer of an output can see, by name, or None when it is not
# there: for a step the steps up to it and the job and workflow settings around
# them, for a job the whole job, the workflow settings and the reusable it calls.
def producer_parts(spec, kind, job_id, ident, base, current):
    jobs = spec.get("jobs") if isinstance(spec.get("jobs"), dict) else {}
    job = jobs.get(job_id if kind == "steps" else ident)
    if not isinstance(job, dict):
        return None
    steps = steps_of(job)
    parts = {f"{k} of the workflow": spec.get(k) for k in ("env", "defaults")}
    if kind == "steps":
        mine = [n for n, s in enumerate(steps) if s.get("id") == ident]
        if not mine:
            return None
        steps = steps[:mine[0] + 1]
        parts.update({f"{k} of the job": job.get(k) for k in JOB_CONTEXT})
    else:
        parts.update({f"{k} of the job": v for k, v in job.items() if k != "steps"})
        local = LOCAL_REUSABLE_RE.match(str(job.get("uses")))
        if local:
            parts["the reusable file"] = norm_spec(spec_at(base, ".github/workflows/" + local.group(1), current))
    parts.update({f"step {n}": norm_step(s) for n, s in enumerate(steps, 1)})
    return parts


# The refusals of the producers that a condition of the file reads.
def producer_refusals(base, path, spec):
    old = spec_at(base, path, False) if base else None
    events = spec.get("on", spec.get(True))
    runs_pr = bool(PULL_REQUEST_EVENTS & set(events if isinstance(events, (dict, list)) else [events]))
    found = []
    for job_id, job in spec["jobs"].items():
        if not isinstance(job, dict):
            continue
        conds = [job.get("if")] + [s.get("if") for s in steps_of(job)]
        for kind, ident in sorted({ref for cond in conds for ref in PRODUCER_REF.findall(str(cond))}):
            what = f"step `{ident}` of job `{job_id}`" if kind == "steps" else f"job `{ident}`"
            now = producer_parts(spec, kind, job_id, ident, base, True)
            if now is None:
                found.append(f"job `{job_id}` in {path} reads `{kind}.{ident}.outputs`, which nothing in the file writes.")
                continue
            runs = [re.sub(r"(?m)^\s*[^\s()]+\)", "", str(v.get("run") or "")) for n, v in now.items() if n.startswith("step ")]
            if runs_pr and any(RUN_FROM_CHECKOUT.search(r) for r in runs):
                found.append(f"{what} in {path} writes outputs a condition reads and runs a script of the repository from the "
                             "checkout of the pull request, which the pull request writes. Read it from the base commit "
                             "with `git show HEAD^1:<path>`, as the scope steps do.")
            if base == "":
                continue
            before = producer_parts(old, kind, job_id, ident, base, False)
            if before is None:
                found.append(f"{what} in {path} writes outputs a condition reads and is new in this pull request, "
                             "so the base commit cannot vouch for it.")
                continue
            diff = list(dict.fromkeys(n for n in [*now, *before] if now.get(n) != before.get(n)))
            if diff and (path, ident) not in PRODUCERS_MAY_CHANGE:
                found.append(f"{what} in {path} writes outputs a condition reads, and what it can see differs from the base "
                             f"commit's in: {', '.join(diff)}. A condition on an output is only as sound as what writes it, "
                             f"so a pull request cannot change both. To change it on purpose, list (`{path}`, `{ident}`) in "
                             "PRODUCERS_MAY_CHANGE of this script in a pull request of its own, then change it in the next.")
    return found


def refused_inputs(job, reusable, path, job_id):
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
    for capped, name in CAP_BASE_WORDS:
        if capped != reusable or name not in given:
            continue
        value = given[name]
        words = value.split() if isinstance(value, str) else None
        odd = [repr(value)] if words is None else [w for w in words if not PATH_WORD_RE.fullmatch(w)]
        if odd:
            found.append(f"job `{job_id}` in {path} passes the input `{name}` to `{reusable}` with "
                         f"{', '.join(f'`{w}`' for w in odd)}, which is not a path or a glob that names a file: it is words "
                         "of letters, digits and `_./-*`, and a word holds a letter or a digit, since `*`, `**` and `*.*` "
                         "match every file and the suite would be skipped for all of them.")
            continue
        ceiling = base_words(reusable, name)
        extra = [] if ceiling is None else sorted(set(words) - ceiling)
        if extra:
            found.append(f"job `{job_id}` in {path} passes the input `{name}` to `{reusable}` with "
                         f"{', '.join(f'`{w}`' for w in extra)}, which the callers of the base commit do not pass. A caller "
                         "may take from the list and may not add to it: a path listed is a path whose change skips the "
                         "suite. To widen it on purpose, take the check apart in a pull request of its own first.")
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


# The refusal of the first switch the job carries, or None. `reusable` is
# the local reusable the job calls, None for a job that runs steps.
def job_switch(path, job_id, job, reusable):
    forms = CONDITIONAL_JOBS.get((path, job_id, reusable), [])
    if isinstance(forms, dict):
        forms = [forms]

    # The whole form is compared, not each key by itself: a listed job that
    # keeps its `needs:` and loses its `if: always()` would be skipped, and so
    # reported as passed, whenever a requirement of it fails.
    shape = {k: job[k] for k in ("if", "needs") if k in job}
    unlisted = [k for k in shape if not any(k in form and form[k] == shape[k] for form in forms)]
    who = f"job `{job_id}` in {path}" + (f" calls `{reusable}` and" if reusable else "")
    declare = (
        " To keep one on purpose, list its exact form in CONDITIONAL_JOBS of "
        "this script, with the reason it is not a switch."
    )
    # Rule: a job-level `if:` is a switch. Any value: `false`, `inputs.foo`,
    # even `true` would skip the job when the expression is false, and a
    # skipped required check reports Success.
    if "if" in unlisted:
        return (
            f"{who} carries a job-level `if:` of any value. Any conditional on "
            "a job that defines a check is a switch: a skipped required check "
            "reports Success and does not block a merge. Delete it, or move "
            "the condition into the steps." + declare
        )
    # Rule: `needs:` is the same switch one job away. A job that needs a
    # skipped job is skipped too.
    if "needs" in unlisted:
        return (
            f"{who} carries `needs:`. A job whose dependency is skipped is "
            "skipped too, and a skipped required check reports Success. "
            "Delete it." + declare
        )
    if shape and shape not in forms:
        return (f"{who} lacks the whole form CONDITIONAL_JOBS lists for it and carries only {shape}: "
                "without `if: always()` a gate is skipped when a requirement fails, and a skipped required check reports Success.")
    # Rule: `continue-on-error:` is a switch of another kind: the job may fail
    # and the run still succeed, so a red suite does not hold the merge back.
    # GitHub does not accept the key on a job that calls a reusable, and the
    # rule refuses it there anyway, because the day it does, nothing else here
    # would.
    if "continue-on-error" in job:
        return (
            f"{who} carries `continue-on-error:`. A job that may fail without "
            "failing the run lets a red suite through. Delete it."
        )
    return None


# The refusals of the steps of a job: a condition its entry of
# STEP_CONDITIONS does not list, and any `continue-on-error:`.
def step_switches(path, job_id, job):
    forms = STEP_CONDITIONS.get((path, job_id), ())
    steps = job.get("steps")
    found = []
    for number, step in enumerate(steps if isinstance(steps, list) else [], 1):
        if not isinstance(step, dict):
            continue
        label = (
            step.get("name") or step.get("id")
            or str(step.get("uses") or "").split("@")[0] or f"number {number}"
        )
        where = f"step `{label}` of job `{job_id}` in {path}"
        if "if" in step and step["if"] not in forms:
            found.append(
                f"{where} carries an `if:` that STEP_CONDITIONS of this "
                "script does not list for the job. A step that runs the "
                "suite, the comparison or the script of a check, skipped, "
                "leaves the job reporting Success. Delete it, or list the "
                "exact form there with the reason it is not a switch."
            )
        if "continue-on-error" in step:
            found.append(
                f"{where} carries `continue-on-error:`. A step that may fail "
                "without failing the job lets a red check through. Delete it."
            )
    return found


def main():
    files = workflow_files()

    callers = 0
    violations = []
    base = base_sha()

    for path in files:
        try:
            with open(path) as fh:
                spec = yaml.load(fh, Loader=LOADER)
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
        violations.extend((path, "", msg) for msg in producer_refusals(base, path, spec))
        for job_id, job in jobs.items():
            if not isinstance(job, dict):
                continue
            uses = job.get("uses")
            local = LOCAL_REUSABLE_RE.match(uses) if isinstance(uses, str) else None
            reusable = local.group(1) if local else None
            if reusable == REUSABLE:
                callers += 1
            violations.extend(
                (path, job_id, msg) for msg in step_switches(path, job_id, job)
            )
            switch = job_switch(path, job_id, job, reusable)
            if switch is not None:
                violations.append((path, job_id, switch))
                continue
            if reusable is None:
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
        "runs a suite, and no job or step of any workflow carries a switch"
    )


if __name__ == "__main__":
    main()
PY
