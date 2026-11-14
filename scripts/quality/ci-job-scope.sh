#!/usr/bin/env bash
# Print true (run) or false (skip) for one lint job, or the list of suites a
# pull request can affect. The packages mode derives an APT subset from that
# same suite decision, without changing the test command. Call from BASE on PRs; never trust a
# changed classifier to decide whether to lint itself, or which suites it may
# skip. No network or extra Python packages. Unknown inputs deliberately cost a
# run.
set -euo pipefail
python3 -I - "$@" <<'PY'
import fnmatch
import os
from pathlib import PurePosixPath
import re
import subprocess
import sys


# The map that says which paths can change each suite's verdict, and where the
# suite list the caller passes as arguments comes from.
#
# Both are read from the BASE commit, never from the checkout of the pull
# request: a pull request that narrows the map or rewrites this script to
# narrow its own scope gets the full set instead, because the base copy is
# what decides. This is the rule the CI standard states for a gate script.
MAP = "scripts/quality/suite-scope.txt"

# The map, this script and the runner are an input of every suite, by rule
# rather than by an entry per suite: a change to any of the three changes
# WHAT RUNS or WHO RUNS IT, so a change to any of the three runs everything.
# Keeping the rule here means a suite added to the map later cannot forget
# it.
GLOBAL_INPUTS = (
    "scripts/quality/ci-job-scope.sh",
    MAP,
    "tests/ci/suites/check-suite-completeness.test.sh",
)


def git(*args):
    return subprocess.run(["git", *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout


def merge_commit():
    """True when HEAD is a merge commit with two parents.

    The scope is decided by comparing HEAD^1 (the base) with HEAD. That is
    the whole pull request only when the checkout is the merge commit GitHub
    builds for refs/pull/N/merge, whose first parent is the base branch tip.
    On a checkout of the branch head instead, HEAD^1 is the previous commit
    of the branch, the comparison covers only the last commit, and suites a
    pull request can affect are skipped. Reading the parent count from the
    commit object answers the same in a shallow clone, where resolving a
    parent NAME does not.
    """
    try:
        body = git("cat-file", "-p", "HEAD")
    except (OSError, subprocess.CalledProcessError):
        return False
    parents = sum(1 for line in body.splitlines() if line.startswith(b"parent "))
    return parents == 2


def changed_paths():
    """The paths this pull request changes.

    None when that cannot be established: an unreadable diff, a rename, a
    copy, a type change or an unknown record. A rename in particular is two
    paths, and both count, so moving a script cannot hide it."""
    if not merge_commit():
        # The checkout is not the merge commit, so HEAD^1..HEAD is not the
        # pull request and the scope cannot be established from it.
        return None
    raw = git("diff", "--name-status", "-z", "--find-renames", "HEAD^1", "HEAD", "--")
    if not raw or not raw.endswith(b"\0"):
        return None
    fields = raw[:-1].split(b"\0")
    if len(fields) % 2:
        return None
    paths = []
    for status, path_bytes in zip(fields[::2], fields[1::2]):
        # Renames/copies, type changes and unknown records are not a safe skip.
        if status not in {b"A", b"M", b"D"} or not path_bytes:
            return None
        paths.append(os.fsdecode(path_bytes))
    return paths


def parse_map(text):
    """Suite path -> the patterns that can change its verdict.

    None when the map cannot be read: a suite listed twice, a pattern before
    any suite, an entry with no pattern at all. An entry with no pattern would
    never run, and a mistake that hides a suite is the one that must not
    survive, so the whole set runs instead."""
    scope = {}
    current = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        if not line[:1].isspace():
            current = line.strip()
            if current in scope:
                return None
            scope[current] = []
            continue
        if current is None:
            return None
        scope[current].append(line.strip())
    if not scope:
        return None
    for patterns in scope.values():
        if not patterns:
            return None
    return scope


def _match(pattern_parts, path_parts):
    if not pattern_parts:
        return not path_parts
    head = pattern_parts[0]
    if head == "**":
        # `**` covers any number of segments, including none.
        for cut in range(len(path_parts) + 1):
            if _match(pattern_parts[1:], path_parts[cut:]):
                return True
        return False
    if not path_parts:
        return False
    if not fnmatch.fnmatchcase(path_parts[0], head):
        return False
    return _match(pattern_parts[1:], path_parts[1:])


def matches(pattern, path):
    """True when the pattern covers the path."""
    return _match(pattern.split("/"), path.split("/"))


def affects(patterns, paths):
    """True when any pattern covers any of the paths."""
    return any(matches(pattern, path) for pattern in patterns for path in paths)


def suites(candidates):
    """The suites this pull request can affect.

    Every failure returns the whole candidate list, because a wrong skip lets
    a change merge untested and a wrong run costs seconds."""
    paths = changed_paths()
    if paths is None:
        return list(candidates)
    try:
        body = git("show", "HEAD^1:" + MAP)
    except (OSError, subprocess.CalledProcessError):
        # No map in the base commit: the scope cannot be established.
        return list(candidates)
    scope = parse_map(body.decode("utf-8", "replace"))
    if scope is None:
        return list(candidates)
    keep = []
    for candidate in candidates:
        patterns = scope.get(candidate)
        if patterns is None:
            # The map does not know this suite, so it always runs.
            keep.append(candidate)
            continue
        # A suite that changes is a suite whose verdict can change, whether or
        # not its entry lists its own file (issue #370).
        if candidate in paths or affects(patterns, paths) or affects(GLOBAL_INPUTS, paths):
            keep.append(candidate)
    return keep


def needed(job):
    if os.environ.get("EVENT") != "pull_request":
        return True
    if job not in {"shellcheck", "workflow-lint", "line-limit"}:
        return True
    raw = git("diff", "--name-status", "-z", "--find-renames", "HEAD^1", "HEAD", "--")
    if not raw or not raw.endswith(b"\0"):
        return True
    fields = raw[:-1].split(b"\0")
    if len(fields) % 2:
        return True
    extensions = os.environ.get("EXTS", "").split()
    if job == "line-limit" and not extensions:
        return True
    for status, path_bytes in zip(fields[::2], fields[1::2]):
        # Renames/copies, type changes and unknown records are not a safe skip.
        if status not in {b"A", b"M", b"D"} or not path_bytes:
            return True
        path = os.fsdecode(path_bytes)
        if path == "scripts/quality/ci-job-scope.sh":
            return True
        name = PurePosixPath(path).name
        workflow = path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml"))
        shell_config = name in {".shellcheckrc", "shellcheckrc"}
        if job == "line-limit":
            if path in {".github/workflows/line-limit.yml", ".github/workflows/reusable-line-limit.yml"}:
                return True
            if any(path.endswith("." + ext) for ext in extensions):
                return True
        elif job == "workflow-lint":
            if workflow or shell_config or path in {".github/actionlint.yml", ".github/actionlint.yaml"}:
                return True
        else:
            if shell_config or path.endswith((".sh", ".bash")) or path in {
                ".github/workflows/tests.yml", ".github/workflows/reusable-shell-ci.yml",
            }:
                return True
            # Inspect BOTH versions: deleting a script or its shebang/run block
            # still changes an input. git show also avoids following symlinks.
            refs = (["HEAD^1"] if status != b"A" else []) + (["HEAD"] if status != b"D" else [])
            for ref in refs:
                body = git("show", f"{ref}:{path}")
                first = body.split(b"\n", 1)[0]
                if re.search(rb"^#!.*(/| )(sh|bash|dash)(\s|$)", first):
                    return True
                if workflow and (re.search(rb"\brun[\"']?\s*:", body) or b"\\" in body):
                    return True
    return False


def normalise(path):
    """The map names a suite without the leading `./` the workflow uses."""
    return path[2:] if path.startswith("./") else path


def packages():
    """APT subset for the existing runner; uncertainty leaves the caller's list.

    Only a plain runner invocation is understood. Never evaluate shell here:
    compound commands, wrappers and substitutions retain the full install.
    The runner still makes its own suite decision and checks every sentinel.
    """
    runner = "tests/ci/suites/check-suite-completeness.test.sh"
    depmap = "scripts/quality/suite-dependencies.txt"
    raw_command = os.environ.get("TEST_COMMAND", "")
    command = raw_command.split()
    if (os.environ.get("EVENT") != "pull_request"
            or "\n" in raw_command or "\r" in raw_command
            or os.environ.get("CHECK_SUITE_COMPLETENESS_SKIP_FIXTURE_TEST", "0") == "1"
            or len(command) < 2 or command[0] != "./" + runner
            or any(not re.fullmatch(r"\./tests/[A-Za-z0-9_./-]+\.test\.sh", s)
                   for s in command[1:])):
        raise ValueError("not a supported PR suite invocation")
    candidates = [normalise(s) for s in command[1:]]
    paths = changed_paths()
    if paths is None:
        raise ValueError("no usable PR diff")
    # Match the runner's base-copy guard. Changes to dependency policy itself
    # cost a full install without changing which suites the runner executes.
    if (open(runner, "rb").read() != git("show", "HEAD^1:" + runner)
            or depmap in paths):
        raise ValueError("runner or dependency policy changed")
    scope = parse_map(git("show", "HEAD^1:" + MAP).decode("utf-8"))
    if scope is None:
        raise ValueError("unusable suite map")
    # Exercise the same BASE resolver in its suites mode as the runner does.
    decision = subprocess.run(
        ["bash", "/dev/stdin", "suites", *command[1:]],
        input=git("show", "HEAD^1:scripts/quality/ci-job-scope.sh"),
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selected = [normalise(s) for s in decision.stdout.decode("utf-8").splitlines() if s]
    if (decision.stderr or not selected or not set(selected) <= set(candidates)
            or set(selected) == set(candidates)):
        raise ValueError("no usable reduced suite decision")
    allowed = os.environ.get("APT_PACKAGES", "").split()
    dependencies = {}
    for raw in git("show", "HEAD^1:" + depmap).decode("utf-8").splitlines():
        fields = raw.split()
        if not fields or fields[0].startswith("#"):
            continue
        suite, *deps = fields
        if (suite in dependencies or suite not in scope or not deps
                or (deps != ["-"] and any(d not in allowed for d in deps))):
            raise ValueError("invalid dependency entry: " + raw)
        dependencies[suite] = set() if deps == ["-"] else set(deps)
    if any(s not in dependencies for s in selected):
        raise ValueError("suite dependencies not established")
    required = set().union(*(dependencies[s] for s in selected))
    print("packages=" + " ".join(p for p in allowed if p in required))


def main():
    argv = sys.argv[1:]
    # Always operate at the root, including for a shell working-directory.
    os.chdir(os.fsdecode(git("rev-parse", "--show-toplevel")).strip())
    if argv == ["packages"]:
        packages()
        return
    if argv and argv[0] == "suites":
        # The list of suites to run, one per line. The caller is
        # tests/ci/suites/check-suite-completeness.test.sh, which passes the
        # suites the workflow names.
        for name in suites([normalise(a) for a in argv[1:]]):
            print(name)
        return
    run = needed(argv[0] if len(argv) == 1 else "")
    print(str(run).lower())


try:
    main()
except (OSError, ValueError, subprocess.CalledProcessError) as exc:
    if sys.argv[1:] == ["packages"]:
        print(f"Cannot establish dependencies; install all: {exc}", file=sys.stderr)
        sys.exit(1)
    if len(sys.argv) > 1 and sys.argv[1] == "suites":
        # Fail open: the whole list of suites the caller named.
        print(f"Cannot establish the suite scope; running every suite: {exc}", file=sys.stderr)
        for name in sys.argv[2:]:
            print(name)
    else:
        print(f"Cannot establish lint scope; running: {exc}", file=sys.stderr)
        print("true")
PY
