#!/usr/bin/env bash
#
# freshness.yml reaches a pull request only through five paths, and each one can
# change the answer of one group of watchers, not of all of them. The scope job
# decides which groups run. This runs its script, as written in the workflow,
# over small repositories whose last commit changes one file, and requires the
# right outputs: only the group a file belongs to, everything for the workflow
# itself or for a path it does not know, and everything again when the diff
# cannot be read. It also requires every watcher to be gated on its own output
# with an expression that skips only on an exact "false".
#
# Requires: git, python3 with PyYAML (tests.yml installs python3-yaml).
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

python3 - "$HERE/.github/workflows/freshness.yml" "$WORK/scope.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["scope"]["steps"]
run = [s["run"] for s in steps if s.get("id") == "scope"][0]
open(sys.argv[2], "w").write(run)
PY

# <path changed by the pull request> -> "dependabot schedule suite tools". The runner
# checks out the merge commit of the pull request, so the repository gets one:
# a base commit, a branch that changes the path, and a --no-ff merge of it.
outputs() {
	local repo="$WORK/r" out="$WORK/out" id=(-c user.name=t -c user.email=t@users.noreply.github.com)
	rm -rf "$repo" "$out" && mkdir -p "$repo" && : > "$out"
	git -C "$repo" init -q -b main
	git -C "$repo" "${id[@]}" commit -q --allow-empty -m base
	git -C "$repo" checkout -q -b pr
	if [ "$1" != "-" ]; then
		mkdir -p "$repo/$(dirname "$1")"
		echo x > "$repo/$1"
		git -C "$repo" add -A
		git -C "$repo" "${id[@]}" commit -q -m change
	else
		git -C "$repo" "${id[@]}" commit -q --allow-empty -m change
	fi
	git -C "$repo" checkout -q main
	git -C "$repo" "${id[@]}" merge -q --no-ff -m merge pr
	(cd "$repo" && GITHUB_OUTPUT="$out" bash "$WORK/scope.sh" >/dev/null 2>&1) || true
	tr '\n' ' ' < "$out" | sed 's/dependabot=//;s/schedule=//;s/suite=//;s/tools=//;s/ $//'
}

check "the dependabot reusable runs only the dependabot watcher" "true false false false" "$(outputs .github/workflows/reusable-dependabot-freshness.yml)"
check "the schedule reusable runs only the schedule watchers" "false true false false" "$(outputs .github/workflows/reusable-schedule-freshness.yml)"
check "the suite script runs only the suite watcher" "false false true false" "$(outputs scripts/monitoring/check-suite-on-main.sh)"
check "the tool-versions script runs only the tool-versions watcher" "false false false true" "$(outputs scripts/monitoring/check-tool-versions.sh)"
check "the workflow itself runs every watcher" "true true true true" "$(outputs .github/workflows/freshness.yml)"
check "a path it does not know runs every watcher" "true true true true" "$(outputs README.md)"
check "a commit with no changed file runs every watcher" "true true true true" "$(outputs -)"

# A checkout that is not a merge commit has one parent: HEAD^1..HEAD would be the
# previous commit of the branch, not the pull request, so nothing may be skipped.
rm -rf "$WORK/linear" "$WORK/out" && mkdir -p "$WORK/linear" && : > "$WORK/out"
git -C "$WORK/linear" init -q
git -C "$WORK/linear" -c user.name=t -c user.email=t@users.noreply.github.com commit -q --allow-empty -m base
mkdir -p "$WORK/linear/.github/workflows"
echo x > "$WORK/linear/.github/workflows/reusable-schedule-freshness.yml"
git -C "$WORK/linear" add -A
git -C "$WORK/linear" -c user.name=t -c user.email=t@users.noreply.github.com commit -q -m change
(cd "$WORK/linear" && GITHUB_OUTPUT="$WORK/out" bash "$WORK/scope.sh" >/dev/null 2>&1) || true
check "a checkout that is not a merge commit runs every watcher" "true true true true" "$(tr '\n' ' ' < "$WORK/out" | sed 's/dependabot=//;s/schedule=//;s/suite=//;s/tools=//;s/ $//')"

# A repository with a single commit has no HEAD^1: the diff cannot be read.
rm -rf "$WORK/single" "$WORK/out" && mkdir -p "$WORK/single" && : > "$WORK/out"
git -C "$WORK/single" init -q
echo x > "$WORK/single/a"
git -C "$WORK/single" add -A
git -C "$WORK/single" -c user.name=t -c user.email=t@users.noreply.github.com commit -q -m only
(cd "$WORK/single" && GITHUB_OUTPUT="$WORK/out" bash "$WORK/scope.sh" >/dev/null 2>&1) || true
check "an unreadable diff runs every watcher" "true true true true" "$(tr '\n' ' ' < "$WORK/out" | sed 's/dependabot=//;s/schedule=//;s/suite=//;s/tools=//;s/ $//')"

# Every watcher is gated on its own output, skipping only on an exact false.
gates="$(python3 - "$HERE/.github/workflows/freshness.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
want = {"dependabot-freshness": "dependabot", "freshness-publish": "schedule",
        "freshness-distro-floor": "schedule", "freshness-health-check": "schedule",
        "freshness-itself": "schedule", "freshness-drift": "schedule",
        "freshness-mutation": "schedule",
        "suite-on-main": "suite", "tool-versions": "tools"}
jobs = doc["jobs"]
bad = []
for name, out in want.items():
    j = jobs.get(name)
    if j is None:
        bad.append(f"{name} missing")
        continue
    need = j.get("needs")
    cond = str(j.get("if", ""))
    if need != "scope" and need != ["scope"]:
        bad.append(f"{name} does not need scope")
    expect = "${{ !cancelled() && needs.scope.outputs.%s != 'false' }}" % out
    if cond != expect:
        bad.append(f"{name} gate is {cond!r}")
if jobs.get("scope", {}).get("if") != "github.event_name == 'pull_request'":
    bad.append("scope does not run only on a pull request")
extra = sorted(set(jobs) - set(want) - {"scope"})
if extra:
    bad.append("ungated jobs: " + ", ".join(extra))
print("ok" if not bad else "; ".join(bad))
PY
)"
check "every watcher is gated on the output of its own group" "ok" "$gates"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
