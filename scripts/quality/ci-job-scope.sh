#!/usr/bin/env bash
# Print true (run) or false (skip) for one lint job. Call from the BASE commit
# on PRs; never trust a changed classifier to decide whether to lint itself.
# No network or extra Python packages. Unknown inputs deliberately cost a run.
set -euo pipefail
python3 - "$@" <<'PY'
import os
from pathlib import PurePosixPath
import re
import subprocess
import sys


def git(*args):
    return subprocess.run(["git", *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout


def needed(job):
    if os.environ.get("EVENT") != "pull_request":
        return True
    if job not in {"shellcheck", "workflow-lint", "line-limit"}:
        return True
    # Always operate at the root, including for a shell working-directory.
    os.chdir(os.fsdecode(git("rev-parse", "--show-toplevel")).strip())
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


try:
    run = needed(sys.argv[1] if len(sys.argv) == 2 else "")
except (OSError, ValueError, subprocess.CalledProcessError) as exc:
    print(f"Cannot establish lint scope; running: {exc}", file=sys.stderr)
    run = True
print(str(run).lower())
PY
