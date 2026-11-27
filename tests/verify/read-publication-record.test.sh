#!/usr/bin/env bash
#
# read-publication-record.sh: the record of the last publication, and only of a publication. gh is a stand-in that
# answers from files of a folder: the list of runs, the artifacts of each run and what each artifact holds. It applies the
# jq filter the script gives to JSON shaped as GitHub answers, so the filter is part of what is tested. The list of runs
# is answered page by page, the way gh answers it with --paginate: the filter is applied to every page and the answers
# are concatenated.
#
# Requires: bash, python3, jq.
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/verify/read-publication-record.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"; fail=$((fail + 1))
		sed 's/^/        | /' "$WORK/out" 2> /dev/null
	fi
}
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
# The stand-in for gh: it reads the path, the filter and the flag --paginate out of the arguments, the way gh does.
printf '%s\n' "$*" >> "$STUB/calls"
verb="$1"; shift
case "$verb" in
api)
	path=""; filter=""; paginate=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--paginate) paginate=1 ;;
			--jq) filter="${2:-}"; shift ;;
			-*) ;;
			*) [ -n "$path" ] || path="$1" ;;
		esac
		shift
	done
	case "$path" in
	*/actions/workflows/publish.yml/runs*)
		[ -z "${FAIL_RUNS:-}" ] || exit 1
		# gh with --paginate asks for every page and prints the filter of each one; without it, only the first.
		page=1
		while [ -f "$STUB/page-$page.json" ]; do
			if [ "$paginate" -ne 1 ] && [ "$page" -ne 1 ]; then break; fi
			[ "$page" != "${FAIL_PAGE:-}" ] || exit 1
			jq -r "$filter" "$STUB/page-$page.json"
			page=$((page + 1))
		done
		;;
	*/actions/runs/*/artifacts*)
		[ -z "${FAIL_ARTIFACTS:-}" ] || exit 1
		id="${path#repos/Glyndor/apt/actions/runs/}"; id="${id%%/*}"
		jq -r "$filter" "$STUB/artifacts-$id.json" 2> /dev/null || jq -rn '{artifacts: []} | '"$filter"
		;;
	*) echo "unexpected gh $*" >&2; exit 64 ;;
	esac
	;;
run)
	[ -z "${FAIL_DOWNLOAD:-}" ] || exit 1
	id="$2"; dir="${*: -1}"
	mkdir -p "$dir"; cp "$STUB/content-$id" "$dir/published-index" 2> /dev/null || true
	;;
*) echo "unexpected gh $*" >&2; exit 64 ;;
esac
SH
chmod 755 "$WORK/bin/gh"
fresh() { STUB="$WORK/stub"; rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls"; export STUB; page=0; }
# a_page: one more page of the list of runs, as GitHub answers one
a_page() { page=$((page + 1)); : > "$STUB/page-$page.jsonl"; build_page; }
build_page() { jq -s '{workflow_runs: .}' "$STUB/page-$page.jsonl" > "$STUB/page-$page.json"; }
# a_run <id> [created_at] [path] [branch] [event] [repository]: one more run in the current page
a_run() {
	jq -cn --argjson id "$1" --arg created "${2:-2026-11-26T16:00:00Z}" --arg path "${3:-.github/workflows/publish.yml}" \
		--arg branch "${4:-main}" --arg event "${5:-schedule}" --arg repo "${6:-Glyndor/apt}" \
		'{id: $id, created_at: $created, path: $path, head_branch: $branch, event: $event, head_repository: {full_name: $repo}}' \
		>> "$STUB/page-$page.jsonl"
	build_page
}
# keeps <id> <time> <digit> [name] [expired]: that run holds an artifact with that record
keeps() {
	jq -n --arg name "${4:-apt-published-index}" --argjson expired "${5:-false}" '{artifacts: [{name: $name, expired: $expired}]}' > "$STUB/artifacts-$1.json"
	printf '%s %064d\n' "$2" "$3" > "$STUB/content-$1"
}
read_record() {
	local rc=0
	rm -f "$WORK/record"
	PATH="$WORK/bin:$PATH" REPO=Glyndor/apt bash "$SCRIPT" "$WORK/record" > "$WORK/out" 2>&1 || rc=$?
	echo "$rc"
}
got() { cat "$WORK/record" 2> /dev/null || echo absent; }
says() { grep -c -F -- "$1" "$WORK/out" || true; }
asked() { grep -c -- "$1" "$STUB/calls" || true; }
REC_A="2026-11-26T16:00:00Z $(printf '%064d' 1)"

fresh; a_page; a_run 30 2026-11-26T16:00:00Z; keeps 30 2026-11-26T16:00:00Z 1
a_run 20 2026-11-25T06:00:00Z; keeps 20 2026-11-25T06:00:00Z 2
check "the record of the newest publication that kept one" "0 $REC_A" "$(read_record) $(got)"
fresh; a_page; a_run 40 2026-11-27T10:00:00Z; a_run 30 2026-11-26T16:00:00Z; keeps 30 2026-11-26T16:00:00Z 1
check "a newer run that recorded nothing is passed over" "0 $REC_A" "$(read_record) $(got)"
fresh; a_page; a_run 30 2026-11-26T16:00:00Z .github/workflows/publish.yml main workflow_dispatch
keeps 30 2026-11-26T16:00:00Z 1
check "a run started by hand counts" "0 $REC_A" "$(read_record) $(got)"

echo "-- an artifact of the same name from anything but a publication is ignored"
for case in "another branch|.github/workflows/publish.yml|attack|schedule|Glyndor/apt" \
	"a fork whose branch is main|.github/workflows/publish.yml|main|workflow_dispatch|someone/apt" \
	"another workflow|.github/workflows/tests.yml|main|schedule|Glyndor/apt" \
	"a pull request|.github/workflows/publish.yml|main|pull_request|Glyndor/apt" \
	"a push|.github/workflows/publish.yml|main|push|Glyndor/apt" \
	"a run with no repository|.github/workflows/publish.yml|main|schedule|"; do
	IFS='|' read -r what path branch event repo <<< "$case"
	fresh
	# The run that must be ignored is the newest of the page, so it is the first one the script reads.
	a_page; a_run 99 2026-11-27T10:00:00Z "$path" "$branch" "$event" "${repo:-none}"; keeps 99 2020-01-01T00:00:00Z 9
	a_run 30 2026-11-26T16:00:00Z; keeps 30 2026-11-26T16:00:00Z 1
	check "$what: its record is not read" "0 $REC_A 0" "$(read_record) $(got) $(grep -c 'runs/99/\|download 99' "$STUB/calls" || true)"
done
fresh; a_page; a_run 30 2026-11-26T16:00:00Z; keeps 30 2026-11-26T16:00:00Z 1 apt-published-index-2
a_run 20 2026-11-25T06:00:00Z; keeps 20 2026-11-25T06:00:00Z 2
check "an artifact of another name is not the record" "0 2026-11-25T06:00:00Z $(printf '%064d' 2)" "$(read_record) $(got)"
fresh; a_page; a_run 30 2026-11-26T16:00:00Z; keeps 30 2026-11-26T16:00:00Z 1 apt-published-index true
check "an expired artifact is not a record" "0 none" "$(read_record) $(got)"
fresh; a_page
check "no run at all is no record" "0 none" "$(read_record) $(got)"
check "and says that the served index has to be recent" "1" "$(says 'the served one has to be recent')"

echo "-- the runs of the last 91 days are listed page by page"
fresh; a_page; a_run 40 2026-11-25T10:00:00Z
a_page; a_run 30 2026-11-26T16:00:00Z; keeps 30 2026-11-26T16:00:00Z 1
check "the record of a publication on the second page is read" "0 $REC_A" "$(read_record) $(got)"
check "and the runs are asked for page by page" "1" "$(asked '--paginate')"
check "with a hundred runs on a page" "1" "$(asked 'workflows/publish.yml/runs?.*per_page=100')"
check "and only the runs of the last 91 days" "1" "$(asked "workflows/publish.yml/runs?.*created=>=$(date -u -d '91 days ago' +%Y-%m-%d)")"
check "and the branch and the workflow are still named" "1" "$(asked 'workflows/publish.yml/runs?branch=main')"

echo "-- a page that cannot be read is a failure"
fresh; a_page; a_run 40 2026-11-25T10:00:00Z
a_page; a_run 30 2026-11-26T16:00:00Z; keeps 30 2026-11-26T16:00:00Z 1
check "the second page of the runs cannot be read" "1 absent" "$(FAIL_PAGE=2 read_record) $(got)"
check "and it says the runs cannot be listed" "1 1" "$(FAIL_PAGE=2 read_record) $(says '::error::cannot list the runs of the publish')"
check "and it does not take the record of the first page for the whole" "0" "$(says 'no run of the publish that was read')"

echo "-- the runs are walked from the newest to the oldest"
fresh; a_page; a_run 30 2026-11-25T06:00:00Z; keeps 30 2026-11-25T06:00:00Z 2
a_run 40 2026-11-26T16:00:00Z; keeps 40 2026-11-26T16:00:00Z 1
check "the newest run of a page is the one read" "0 $REC_A" "$(read_record) $(got)"
fresh; a_page; a_run 30 2026-11-26T16:00:00Z; keeps 30 2026-11-26T16:00:00Z 1
a_run 40 2026-11-26T16:00:00Z; keeps 40 2026-11-26T16:00:00Z 2
check "two runs of the same day are walked from the newest id" "0 2026-11-26T16:00:00Z $(printf '%064d' 2)" "$(read_record) $(got)"

echo "-- an answer that cannot be read is a failure, never 'none'"
fresh; a_page; a_run 30 2026-11-26T16:00:00Z; keeps 30 2026-11-26T16:00:00Z 1
check "the runs cannot be listed" "1 absent" "$(FAIL_RUNS=1 read_record) $(got)"
check "the artifacts cannot be listed" "1 absent" "$(FAIL_ARTIFACTS=1 read_record) $(got)"
check "and it says whose artifacts it cannot list" "1 1" "$(FAIL_ARTIFACTS=1 read_record) $(says '::error::cannot list the artifacts of run')"
check "the artifact cannot be downloaded" "1 absent" "$(FAIL_DOWNLOAD=1 read_record) $(got)"
check "and it says which artifact it cannot download" "1 1" "$(FAIL_DOWNLOAD=1 read_record) $(says '::error::cannot download')"
rm "$STUB/content-30"
check "the artifact holds no record" "1 1" "$(read_record) $(says 'holds no published-index')"
for bad in "2026-11-26T16:00:00Z" "now $(printf '%064d' 1)" "2026-11-26T16:00:00Z abc"; do
	printf '%s\n' "$bad" > "$STUB/content-30"
	check "a record of '${bad:0:24}'" "1 absent" "$(read_record) $(got)"
done
keeps 30 2026-11-26T16:00:00Z 1
jq -n '{artifacts: [{name: "apt-published-index", expired: false}, {name: "apt-published-index", expired: false}]}' > "$STUB/artifacts-30.json"
check "two artifacts of the name in one run" "1 absent" "$(read_record) $(got)"
fresh
printf '{"workflow_runs":[{"id":"x","created_at":"2026-11-26T16:00:00Z","path":".github/workflows/publish.yml","head_branch":"main","event":"schedule","head_repository":{"full_name":"Glyndor/apt"}}]}' > "$STUB/page-1.json"
check "a run id that is not a number" "1 absent" "$(read_record) $(got)"
rc=0; PATH="$WORK/bin:$PATH" REPO="" bash "$SCRIPT" "$WORK/record" > "$WORK/out" 2>&1 || rc=$?
check "REPO unset" "2" "$rc"
rc=0; PATH="$WORK/bin:$PATH" REPO=Glyndor/apt bash "$SCRIPT" > "$WORK/out" 2>&1 || rc=$?
check "no output file" "2" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
