#!/usr/bin/env bash
#
# Every workflow with a schedule is watched by a freshness job, and a daily or
# weekly one is watched with the limit freshness.yml states for its cadence.
#
# A cron that stops firing emits nothing, so a scheduled workflow nobody
# watches can go dark with every check green; mutation.yml ran without a
# watcher for its first week. And two crons of the same cadence used to be
# held to limits a day apart with no reason written down. The rule is in
# freshness.yml: two periods plus one day, so three days for a daily cron and
# fifteen for a weekly one. A cron that fires more than once a day keeps a
# limit of its own and is only required to be watched; a cron this cannot
# read a cadence from is reported, so a new shape is a decision and not a gap.
#
# The check is first run over planted workflows that break each rule, so a
# check that ignored its input would have to pass them to pass here.
#
# Requires: python3 with PyYAML.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -d "$HERE/.github/workflows" ] && [ "$HERE" != / ]; do HERE="$(dirname "$HERE")"; done
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

# One line per problem, or "ok".
audit() { # $1=workflows dir
	python3 -I - "$1" <<'PY'
import glob
import os
import re
import sys

import yaml

LIMIT = {"daily": 3, "weekly": 15}
NUMBER = re.compile(r"[0-9]+")


def load(path):
    with open(path) as fh:
        return yaml.safe_load(fh) or {}


def cadence(cron):
    fields = str(cron).split()
    if len(fields) != 5:
        return None
    minute, hour, dom, month, dow = fields
    # One run on one day of the year, to try a workflow on a runner once: it says nothing about how often
    # the workflow fires, so it does not count towards its cadence.
    if NUMBER.fullmatch(minute) and NUMBER.fullmatch(hour) and NUMBER.fullmatch(dom) and NUMBER.fullmatch(month) and dow == "*":
        return "once"
    if not NUMBER.fullmatch(minute) or dom != "*" or month != "*":
        return None
    if not NUMBER.fullmatch(hour):
        return "sub-daily" if dow == "*" else None
    if dow == "*":
        return "daily"
    return "weekly" if NUMBER.fullmatch(dow) else None


root = sys.argv[1]
watched = {}
fresh = os.path.join(root, "freshness.yml")
if os.path.exists(fresh):
    for job_id, job in (load(fresh).get("jobs") or {}).items():
        if isinstance(job, dict) and "reusable-schedule-freshness.yml" in str(job.get("uses", "")):
            w = job.get("with") or {}
            watched[str(w.get("workflow"))] = (job_id, w.get("max-age-days"), w.get("max-age-hours"))
bad = []
for path in sorted(glob.glob(os.path.join(root, "*.yml"))):
    name = os.path.basename(path)
    doc = load(path)
    on = doc.get("on", doc.get(True)) or {}
    crons = [e.get("cron") for e in (on.get("schedule") or []) if isinstance(e, dict)] if isinstance(on, dict) else []
    if not crons:
        continue
    if name not in watched:
        bad.append(f"{name} has a schedule and no freshness job watches it")
        continue
    kinds = {cadence(c) for c in crons}
    if kinds - {"once"}:
        kinds.discard("once")
    if None in kinds or len(kinds) != 1 or kinds == {"once"}:
        bad.append(f"{name}: cannot tell the cadence of {crons}")
        continue
    kind = kinds.pop()
    job_id, days, hours = watched[name]
    if kind in LIMIT and (days != LIMIT[kind] or hours):
        bad.append(f"{name} is {kind} and {job_id} allows {days} days, not {LIMIT[kind]}")
print("\n".join(bad) if bad else "ok")
PY
}

plant() { # $1=file $2=cron
	printf 'on:\n  schedule:\n    - cron: "%s"\njobs: {}\n' "$2" > "$WORK/w/$1"
}
watch() { # $1=workflow $2=days
	printf '  watch-%s:\n    uses: ./.github/workflows/reusable-schedule-freshness.yml\n    with:\n      workflow: %s\n      max-age-days: %s\n' \
		"${1%.yml}" "$1" "$2" >> "$WORK/w/freshness.yml"
}
fresh() { mkdir -p "$WORK/w"; rm -f "$WORK/w"/*.yml; printf 'on: push\njobs:\n' > "$WORK/w/freshness.yml"; }

fresh; plant daily.yml "41 9 * * *"; plant weekly.yml "23 5 * * 1"; watch daily.yml 3; watch weekly.yml 15
check "a daily and a weekly cron watched at the stated limits pass" "ok" "$(audit "$WORK/w")"

fresh; plant daily.yml "41 9 * * *"
check "a scheduled workflow nobody watches is reported" \
	"daily.yml has a schedule and no freshness job watches it" "$(audit "$WORK/w")"

fresh; plant daily.yml "41 9 * * *"; watch daily.yml 2
check "a daily cron watched at another limit is reported" \
	"daily.yml is daily and watch-daily allows 2 days, not 3" "$(audit "$WORK/w")"

fresh; plant weekly.yml "23 5 * * 1"; watch weekly.yml 10
check "a weekly cron watched at another limit is reported" \
	"weekly.yml is weekly and watch-weekly allows 10 days, not 15" "$(audit "$WORK/w")"

fresh; plant hourly.yml "30 * * * *"; watch hourly.yml 1
check "a cron that fires more than once a day keeps its own limit" "ok" "$(audit "$WORK/w")"

fresh; printf 'on:\n  schedule:\n    - cron: "23 5 * * 1"\n    - cron: "23 9 24 11 *"\njobs: {}\n' > "$WORK/w/weekly.yml"; watch weekly.yml 15
check "a weekly cron with one extra run on one day of the year is still weekly" "ok" "$(audit "$WORK/w")"

fresh; printf 'on:\n  schedule:\n    - cron: "23 5 * * 1"\n    - cron: "23 9 24 11 *"\njobs: {}\n' > "$WORK/w/weekly.yml"; watch weekly.yml 10
check "and it is still held to the limit of a weekly cron" \
	"weekly.yml is weekly and watch-weekly allows 10 days, not 15" "$(audit "$WORK/w")"

fresh; plant onlyonce.yml "23 9 24 11 *"; watch onlyonce.yml 15
check "a workflow whose only run is one day of the year has no cadence to watch and is reported" \
	"onlyonce.yml: cannot tell the cadence of ['23 9 24 11 *']" "$(audit "$WORK/w")"

fresh; plant odd.yml "0 6 1 * *"; watch odd.yml 40
check "a cron whose cadence cannot be read is reported" \
	"odd.yml: cannot tell the cadence of ['0 6 1 * *']" "$(audit "$WORK/w")"

check "every scheduled workflow of this repository is watched at its stated limit" "ok" \
	"$(audit "$HERE/.github/workflows")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
