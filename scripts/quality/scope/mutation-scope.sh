#!/usr/bin/env bash
# Print the entries of the mutation catalogue a pull request can affect, one id
# per line, `all` when every entry has to run, or nothing when none can.
#
# The whole sweep takes about half an hour, so it does not run on every pull
# request: a change that touches neither a mutated script, nor a suite an entry
# names, nor anything those suites read, nor the catalogue, cannot change
# whether a catalogued guard is still noticed, and a run would learn nothing.
# An entry is selected when its file changed, when its catalogue line is new or
# changed, or when a suite it names can be affected by the change. The last
# question is the one scripts/quality/scope/ci-job-scope.sh answers for the suite job
# from scripts/quality/scope/suite-scope.txt, so it is asked of that resolver here
# rather than answered a second time.
#
# Run the copy of this script taken from the BASE commit, like the resolver it
# calls: a pull request that narrows the decision to hide its own guards gets
# the decision as the base commit makes it. The resolver and its map are read
# from the base commit as well.
#
# Everything fails open. Any event but a pull request, a checkout that is not
# the merge commit, an unreadable diff, a rename, a catalogue that cannot be
# read in either commit, a change to the runner, to this script or to the
# workflow that runs them, and a resolver that cannot decide: all of them print
# `all`. A wrong skip lets a dead guard merge; a wrong run costs minutes.
set -euo pipefail
python3 -I - <<'PY'
import os
import re
import subprocess
import sys

CATALOG = "tests/mutation/catalog.txt"
CATALOG_D = "tests/mutation/catalog.d"
RESOLVER = "scripts/quality/scope/ci-job-scope.sh"
# A change to any of these changes what the sweep does or who decides it.
GLOBAL_INPUTS = {
    "tests/mutation/run-mutations.sh",
    "scripts/quality/scope/mutation-scope.sh",
    ".github/workflows/mutation.yml",
}
ID = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class Undecided(Exception):
    pass


def git(*args):
    return subprocess.run(["git", *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout


def changed_paths():
    body = git("cat-file", "-p", "HEAD")
    if sum(1 for line in body.splitlines() if line.startswith(b"parent ")) != 2:
        raise Undecided("the checkout is not the merge commit of a pull request")
    raw = git("diff", "--name-status", "-z", "--find-renames", "HEAD^1", "HEAD", "--")
    if not raw or not raw.endswith(b"\0"):
        raise Undecided("the diff is empty or cannot be read")
    fields = raw[:-1].split(b"\0")
    if len(fields) % 2:
        raise Undecided("the diff cannot be read")
    paths = set()
    for status, path in zip(fields[::2], fields[1::2]):
        if status not in {b"A", b"M", b"D"} or not path:
            raise Undecided("a rename, copy or type change")
        paths.add(os.fsdecode(path))
    return paths


def catalogue_files(ref):
    """catalog.txt, then every catalog.d/*.txt of the commit, in the order LC_ALL=C sorts them."""
    listing = git("ls-tree", "-z", ref, "--", CATALOG_D + "/").split(b"\0")
    parts = []
    for record in listing:
        meta, _, path = record.partition(b"\t")
        if meta.split()[1:2] == [b"blob"] and path.endswith(b".txt"):
            parts.append(path)
    return [CATALOG] + [os.fsdecode(path) for path in sorted(parts)]


def catalogue(ref):
    entries = {}
    for name in catalogue_files(ref):
        for raw in git("show", f"{ref}:{name}").decode("utf-8").splitlines():
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            fields = raw.split("\t")
            if len(fields) != 5 or not ID.match(fields[0]) or fields[0] in entries:
                raise Undecided(f"a catalogue line cannot be read in {ref}")
            entries[fields[0]] = (raw, fields[1], [t for t in fields[4].split(",") if t])
    if not entries:
        raise Undecided(f"the catalogue of {ref} has no entries")
    return entries


def affected_suites(suites):
    decision = subprocess.run(["bash", "/dev/stdin", "suites", *sorted(suites)],
                              input=git("show", f"HEAD^1:{RESOLVER}"),
                              check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if decision.stderr:
        raise Undecided("the suite resolver could not decide")
    named = {line for line in decision.stdout.decode("utf-8").splitlines() if line}
    if not named <= set(suites):
        raise Undecided("the suite resolver named a suite it was not given")
    return named


def select():
    if os.environ.get("EVENT") != "pull_request":
        raise Undecided("not a pull request")
    paths = changed_paths()
    if paths & GLOBAL_INPUTS:
        raise Undecided("the sweep itself changed")
    head, base = catalogue("HEAD"), catalogue("HEAD^1")
    suites = set().union(*(tests for _, _, tests in head.values()))
    affected = affected_suites(suites)
    chosen = [ident for ident, (raw, path, tests) in head.items()
              if path in paths or base.get(ident, (None,))[0] != raw or affected & set(tests)]
    return chosen, len(head)


try:
    os.chdir(os.fsdecode(git("rev-parse", "--show-toplevel")).strip())
    chosen, total = select()
except (Undecided, OSError, ValueError, UnicodeDecodeError, subprocess.CalledProcessError) as exc:
    print(f"Cannot narrow the mutation sweep; running every entry: {exc}", file=sys.stderr)
    print("all")
    sys.exit(0)
if len(chosen) == total:
    print("all")
else:
    for ident in chosen:
        print(ident)
PY
