#!/usr/bin/env bash
# The grace period of a new cron in .github/workflows/reusable-schedule-freshness.yml.
#
# A watcher added with the cron it watches has nothing on record until the
# first firing, and without a grace period it is born red. The grace applies
# only to a workflow with no scheduled run of any conclusion on record, whose
# file was added to the branch less than the limit ago, and it passes with a
# notice that says when it ends. Past the limit it fails; a date that cannot be
# read (a shallow history, a file never added) fails; and a workflow with old
# runs and no recent one fails as it always did, because that is a dead cron.
#
# The step is read out of the workflow as it ships and run in a throwaway git
# repository whose commit dates are set, with a stub `gh` that answers by URL.
#
# Requires: git, python3 with PyYAML, GNU date.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}
said() { printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0; }

python3 -I - "$HERE/.github/workflows/reusable-schedule-freshness.yml" > "$WORK/step.sh" <<'PY'
import sys
import yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["freshness"]["steps"]
print(next(s["run"] for s in steps if s.get("name") == "Check the newest successful scheduled run"))
PY
check "the step was read from the workflow" "1" "$(grep -c 'is-shallow-repository' "$WORK/step.sh")"

# The stub: the count of scheduled runs of any conclusion for the URL that asks
# for it, and the newest run for the others; every call is recorded.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$GH_LOG"
case "$2" in
*per_page=1) printf '%s' "$STUB_TOTAL" ;;
*created=*) printf '%s' "$STUB_WINDOWED" ;;
*) printf '%s' "$STUB_LATEST" ;;
esac
STUB
printf '#!/bin/sh\n:\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/gh" "$WORK/bin/sleep"

# A repository whose workflow file was added <days> ago, or never (-).
repo() { # $1=days ago or -
	rm -rf "$WORK/r" "$WORK/shallow"
	mkdir -p "$WORK/r/.github/workflows"
	git -C "$WORK/r" init -q -b main
	echo base > "$WORK/r/README.md"
	when="$(date -u -d "40 days ago" +%Y-%m-%dT%H:%M:%SZ)"
	git -C "$WORK/r" add -A
	GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
		git -C "$WORK/r" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm base
	if [ "$1" != - ]; then
		when="$(date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ)"
		echo 'on: {schedule: [{cron: "23 5 * * 1"}]}' > "$WORK/r/.github/workflows/new.yml"
		git -C "$WORK/r" add -A
		GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
			git -C "$WORK/r" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm add
	fi
}
run() { # $1=dir $2=total scheduled runs $3=newest run (unwindowed) -> out, rc
	: > "$WORK/gh.log"
	out="$(cd "$1" && PATH="$WORK/bin:$PATH" GH_LOG="$WORK/gh.log" STUB_TOTAL="$2" STUB_WINDOWED="" \
		STUB_LATEST="$3" GH_TOKEN=dummy REPO=owner/repo WORKFLOW=new.yml MAX_AGE_DAYS=15 \
		MAX_AGE_HOURS='' ANY_CONCLUSION=false bash -e -o pipefail "$WORK/step.sh" 2>&1)"
	rc=$?
}

repo 3; run "$WORK/r" 0 ""
check "a new workflow with no run on record, added three days ago, passes" "0" "$rc"
check "and says it is in its grace period" "1" "$(said "$out" '::notice::new.yml has no scheduled run on record yet')"
check "and when the grace ends, the limit after the commit that added it" "1" \
	"$(said "$out" "grace period until $(date -u -d "@$(( $(git -C "$WORK/r" log -1 --format=%ct) + 15 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)")"
check "and it asked whether any scheduled run exists at all" "1" "$(grep -c 'event=schedule&per_page=1$' "$WORK/gh.log")"

repo 16; run "$WORK/r" 0 ""
check "the same workflow added sixteen days ago, past the limit, fails" "1" "$rc"
check "and says there is no run on record" "1" "$(said "$out" 'No successful scheduled run on record for new.yml')"

repo 3; run "$WORK/r" 2 ""
check "a new workflow whose scheduled runs all failed gets no grace" "1" "$rc"

repo 3; run "$WORK/r" 4 "$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)"
check "a workflow with old runs and no recent one fails as always" "1" "$rc"
check "and is reported by the age of its newest run" "1" "$(said "$out" 'last succeeded on a schedule 30 days ago')"

repo 3; git clone -q --depth 1 "file://$WORK/r" "$WORK/shallow"; run "$WORK/shallow" 0 ""
check "a shallow history, which cannot date the file, fails" "1" "$rc"
check "and says the date could not be read" "1" "$(said "$out" 'could not be read, or lies in the future, so no grace period applies')"

repo -; run "$WORK/r" 0 ""
check "a workflow whose file was never added fails" "1" "$rc"
check "for the same reason" "1" "$(said "$out" 'could not be read, or lies in the future, so no grace period applies')"

# A commit dated in the future, which its committer can do, is no date.
repo -
when="$(date -u -d "400 days" +%Y-%m-%dT%H:%M:%SZ)"
echo 'on: {schedule: [{cron: "23 5 * * 1"}]}' > "$WORK/r/.github/workflows/new.yml"
gitt_future() { GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
	git -C "$WORK/r" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
gitt_future add -A; gitt_future commit -qm 'add, dated ahead'
run "$WORK/r" 0 ""
check "a workflow whose file was added at a date in the future gets no grace" "1" "$rc"
check "and is told the date is unreadable or ahead" "1" "$(said "$out" 'could not be read, or lies in the future, so no grace period applies')"

mkdir -p "$WORK/nogit"; run "$WORK/nogit" 0 ""
check "a checkout with no history at all fails" "1" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
