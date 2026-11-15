#!/usr/bin/env bash
#
# The suite-on-main poll answers for one commit, and the comment above it says every
# run on main or the schedule is kept. With a concurrency group shared by all pushes and
# `cancel-in-progress: false`, GitHub keeps the running job and still cancels an older
# PENDING one when a newer is queued, so two quick merges could lose the verdict of the
# middle commit. Outside a pull request the group has to be unique per run; in one it
# stays shared so a newer push replaces the superseded poll. This reads the live
# workflow and plants each way of getting it wrong.
#
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

verdict() { # $1 = workflow file
	python3 - "$1" "suite-on-main" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
job = doc["jobs"].get(sys.argv[2])
if job is None:
    print("the poll job is missing"); sys.exit(0)
c = job.get("concurrency") or {}
group = str(c.get("group", ""))
want = "freshness-suite-on-main-${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}"
problems = []
if group != want:
    problems.append(f"group is {group!r}")
if str(c.get("cancel-in-progress")) != "${{ github.event_name == 'pull_request' }}":
    problems.append("cancel-in-progress is not limited to a pull request")
print("ok" if not problems else "; ".join(problems))
PY
}

check "the live poll keeps one run per commit outside a pull request" "ok" "$(verdict "$HERE/.github/workflows/freshness.yml")"

mkdir -p "$WORK/c"
python3 - "$HERE/.github/workflows/freshness.yml" "$WORK/c" "suite-on-main" <<'PY'
import sys, yaml, copy
doc = yaml.safe_load(open(sys.argv[1]))
job = sys.argv[3]
def write(name, edit):
    d = copy.deepcopy(doc)
    edit(d["jobs"][job]["concurrency"])
    yaml.safe_dump(d, open(f"{sys.argv[2]}/{name}.yml", "w"), sort_keys=False, width=10**6)
write("shared", lambda c: c.update(group="freshness-suite-on-main-${{ github.workflow }}-${{ github.ref }}"))
write("always-cancel", lambda c: c.update({"cancel-in-progress": True}))
write("never-cancel", lambda c: c.update({"cancel-in-progress": False}))
PY
check "a group shared by every push is reported" "1" "$(verdict "$WORK/c/shared.yml" | grep -c '^group is')"
check "a poll that always cancels is reported" "cancel-in-progress is not limited to a pull request" "$(verdict "$WORK/c/always-cancel.yml")"
check "a poll that never cancels leaves superseded pull request polls running" "cancel-in-progress is not limited to a pull request" "$(verdict "$WORK/c/never-cancel.yml")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
