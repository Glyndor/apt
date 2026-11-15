#!/usr/bin/env bash
#
# freshness.yml reaches a pull request only through four paths, and each one can
# change the answer of one group of watchers, not of all seven. The scope job
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

# <path changed by the last commit> -> "dependabot schedule suite"
outputs() {
	local repo="$WORK/r" out="$WORK/out"
	rm -rf "$repo" "$out" && mkdir -p "$repo" && : > "$out"
	git -C "$repo" init -q
	git -C "$repo" -c user.name=t -c user.email=t@users.noreply.github.com commit -q --allow-empty -m base
	if [ "$1" != "-" ]; then
		mkdir -p "$repo/$(dirname "$1")"
		echo x > "$repo/$1"
		git -C "$repo" add -A
		git -C "$repo" -c user.name=t -c user.email=t@users.noreply.github.com commit -q -m change
	fi
	(cd "$repo" && GITHUB_OUTPUT="$out" bash "$WORK/scope.sh" >/dev/null 2>&1) || true
	tr '\n' ' ' < "$out" | sed 's/dependabot=//;s/schedule=//;s/suite=//;s/ $//'
}

check "the dependabot reusable runs only the dependabot watcher" "true false false" "$(outputs .github/workflows/reusable-dependabot-freshness.yml)"
check "the schedule reusable runs only the schedule watchers" "false true false" "$(outputs .github/workflows/reusable-schedule-freshness.yml)"
check "the suite script runs only the suite watcher" "false false true" "$(outputs scripts/monitoring/check-suite-on-main.sh)"
check "the workflow itself runs every watcher" "true true true" "$(outputs .github/workflows/freshness.yml)"
check "a path it does not know runs every watcher" "true true true" "$(outputs README.md)"
check "a commit with no changed file runs every watcher" "true true true" "$(outputs -)"

# A repository with a single commit has no HEAD^1: the diff cannot be read.
rm -rf "$WORK/single" "$WORK/out" && mkdir -p "$WORK/single" && : > "$WORK/out"
git -C "$WORK/single" init -q
echo x > "$WORK/single/a"
git -C "$WORK/single" add -A
git -C "$WORK/single" -c user.name=t -c user.email=t@users.noreply.github.com commit -q -m only
(cd "$WORK/single" && GITHUB_OUTPUT="$WORK/out" bash "$WORK/scope.sh" >/dev/null 2>&1) || true
check "an unreadable diff runs every watcher" "true true true" "$(tr '\n' ' ' < "$WORK/out" | sed 's/dependabot=//;s/schedule=//;s/suite=//;s/ $//')"

# Every watcher is gated on its own output, skipping only on an exact false.
gates="$(python3 - "$HERE/.github/workflows/freshness.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
want = {"dependabot-freshness": "dependabot", "freshness-publish": "schedule",
        "freshness-distro-floor": "schedule", "freshness-health-check": "schedule",
        "freshness-itself": "schedule", "freshness-drift": "schedule",
        "suite-on-main": "suite"}
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
    expect = "${{ always() && needs.scope.outputs.%s != 'false' }}" % out
    if cond != expect:
        bad.append(f"{name} gate is {cond!r}")
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
