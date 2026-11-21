#!/usr/bin/env bash
#
# The sync policy of publish.yml: the five `aws s3 sync` passes, what each of
# them is allowed to write and what each of them is allowed to delete.
#
# Pass 1 uploads pool/ without deleting, pass 2 uploads the by-hash copies of
# the index files, pass 3 the signed index, pass 4 the rest of the metadata,
# fixed-name index files included, and pass 5 removes the pool entries the new
# metadata stopped referencing. The order is the invariant: deleting before the
# metadata is published leaves apt fetching a .deb that is already gone,
# publishing metadata before the packages leaves it referencing files that have
# not arrived, an InRelease that lands before the copies it declares sends a
# client that asks by hash to a 404, and fixed-name files that land before the
# InRelease that declares them send a client of the previous one, which asks by
# name, bytes it does not expect. tests/publish/sync-archive.test.sh runs the passes against a
# model of the bucket and checks each point a pass can fail at.
#
# The cases read the commands, never the prose. The comments in this workflow
# discuss `aws s3 sync` by name, and an unanchored grep counts those too -- it
# reported five passes where there are three.
#
# The order of the steps around the sync, and the purge that follows it, are in
# tests/publication/publish/publish-workflow.test.sh.
#
# Requires: coreutils, grep and python3.
set -u

cd "$(dirname "$0")/../../.." || exit 1
WF=".github/workflows/publish.yml"
# The workflow delegates the passes to this script.
SYNC="scripts/publish/sync-archive.sh"
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# --- the five-pass sync -----------------------------------------------------
#
check "the workflow invokes the sync script" "1" \
	"$(grep -c '^          ./scripts/publish/sync-archive.sh$' "$WF")"

# Anchored to the command's own indentation.
mapfile -t starts < <(grep -n '^aws s3 sync' "$SYNC" | cut -d: -f1)
check "the publish step syncs in five passes" "5" "${#starts[@]}"
starts+=("$(($(wc -l < "$SYNC") + 1))")

# Each pass's flags: from its own line up to the next pass, with comment lines
# dropped. A comment says "Deliberately NOT --delete", which is enough to make
# an unfiltered range report that a pass deletes. Every assertion in this file
# reads commands, never prose.
flags_of() { # <pass number, from 1>
	sed -n "${starts[$1 - 1]},$((starts[$1] - 1))p" "$SYNC" | grep -v '^[[:space:]]*#'
}
has() { flags_of "$1" | grep -qF -- "$2" && echo 1 || echo 0; }

check "pass 1 uploads pool/" "1" "$(has 1 '--exclude "*" --include "pool/*"')"
check "and deletes nothing" "0" "$(has 1 '--delete')"
check "pass 2 uploads the by-hash copies, and only them" "1" "$(has 2 '--exclude "*" --include "dists/*/by-hash/*"')"
check "and deletes nothing" "0" "$(has 2 '--delete')"
check "pass 3 publishes the signed index, and only it" "1" \
	"$(has 3 '--exclude "*" --include "dists/stable/InRelease" --include "dists/stable/Release" --include "dists/stable/Release.gpg"')"
check "and deletes nothing" "0" "$(has 3 '--delete')"
check "pass 4 publishes the metadata but the pool" "1" "$(has 4 '--exclude "pool/*"')"
check "and but the copies" "1" "$(has 4 '--exclude "dists/*/by-hash/*"')"
check "and but the signed index" "1" \
	"$(has 4 '--exclude "dists/stable/InRelease" --exclude "dists/stable/Release" --exclude "dists/stable/Release.gpg"')"
check "and deletes nothing" "0" "$(has 4 '--delete')"
check "pass 5 is the one that deletes, and only in pool/" "11" "$(has 5 '--delete')$(has 5 '--exclude "*" --include "pool/*"')"

# --- the endpoint reaches every step that talks to the bucket ---------------
#
# The scripts read the R2 endpoint from AWS_ENDPOINT_URL and refuse to run
# without it, so a step that calls one of them without the variable fails the
# publish, and only the publish: no suite runs the workflow. The steps are
# found by what they run, not by their names: every step whose shell, or a
# script it runs, or a script that one runs, calls `aws`. Each has to set the
# variable from the secret.
endpoint_steps="$(python3 -I - "$WF" <<'PY'
import os
import re
import sys

workflow = sys.argv[1]
lines = open(workflow, encoding="utf-8").read().splitlines()
SCRIPT = re.compile(r"(?:\./)?(scripts/[A-Za-z0-9_./-]+\.sh)\b")
SIBLING = re.compile(r'\$\(dirname "\$0"\)/([A-Za-z0-9_.-]+\.sh)')
AWS = re.compile(r"(?:^|[\s;&|(])aws\s")


def code(text):
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def calls_aws(text, seen):
    if AWS.search(code(text)):
        return True
    for path in SCRIPT.findall(code(text)):
        if path not in seen and os.path.isfile(path):
            seen.add(path)
            if calls_aws(open(path, encoding="utf-8").read(), seen):
                return True
    return False


def script_calls_aws(path, seen):
    body = open(path, encoding="utf-8").read()
    if calls_aws(body, seen):
        return True
    for name in SIBLING.findall(code(body)):
        sibling = os.path.join(os.path.dirname(path), name)
        if sibling not in seen and os.path.isfile(sibling):
            seen.add(sibling)
            if script_calls_aws(sibling, seen):
                return True
    return False


steps, current = [], None
for line in lines:
    if line.startswith("      - "):
        current = {"name": line, "env": [], "run": [], "in": None}
        steps.append(current)
        if "name:" in line:
            current["name"] = line.split("name:", 1)[1].strip()
    if current is None:
        continue
    key = line[8:] if line.startswith("        ") else line[8:] if line.startswith("      - ") else ""
    if key.startswith("env:"):
        current["in"] = "env"
    elif key.startswith("run:"):
        current["in"] = "run"
        inline = key[4:].strip()
        if inline and inline[0] not in "|>":
            current["run"].append(inline)
    elif line.startswith("        ") and not line.startswith("          ") and line.strip():
        current["in"] = None
    elif current["in"] and line.startswith("          "):
        current[current["in"]].append(line.strip())
for step in steps:
    run = "\n".join(step["run"])
    seen = set()
    reaches = AWS.search(code(run)) is not None or any(
        os.path.isfile(p) and script_calls_aws(p, seen) for p in SCRIPT.findall(code(run)))
    if reaches:
        has = "AWS_ENDPOINT_URL: ${{ secrets.GLYNDOR_APT_R2_ENDPOINT }}" in step["env"]
        print(f"{'set' if has else 'MISSING'}\t{step['name']}")
PY
)"
check "the walk finds the step that talks to the bucket" "1" \
	"$(printf '%s\n' "$endpoint_steps" | grep -c 'Publish to R2$')"
check "and every step it finds sets AWS_ENDPOINT_URL from the secret" "" \
	"$(printf '%s\n' "$endpoint_steps" | grep '^MISSING' || true)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
