#!/usr/bin/env bash
# Behaviour tests for scripts/monitoring/check-tool-versions.sh.
#
# The watcher compares the shellcheck and actionlint versions pinned in the
# reusables with the releases upstream publishes. Each case builds a tree with
# the two reusables, puts a stub `gh` on PATH that answers `gh release list`
# from a fixture, and fixes the clock, so nothing here reaches the network.
#
# The cases the watcher owes: a pin that is current, one behind within the lag,
# one behind past it, and an upstream it cannot read, which must fail rather
# than pass. Each failure asserts which failure.
#
# Requires: python3 with PyYAML.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/check-tool-versions.sh"
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

# 2026-11-21T00:00:00Z, so every age below is a whole number of days.
NOW=1795219200
day() { date -u -d "@$((NOW - $1 * 86400))" +%Y-%m-%dT%H:%M:%SZ; }

# A tree with the two reusables, pinning <shellcheck in shell-ci>
# <shellcheck in workflow-lint> <actionlint>.
tree() {
	rm -rf "$WORK/t"
	mkdir -p "$WORK/t/.github/workflows"
	printf 'on:\n  workflow_call:\n    inputs:\n      shellcheck-version:\n        type: string\n        default: "%s"\njobs: {}\n' \
		"$1" > "$WORK/t/.github/workflows/reusable-shell-ci.yml"
	printf 'on:\n  workflow_call:\n    inputs:\n      shellcheck-version:\n        type: string\n        default: "%s"\njobs:\n  workflow-lint:\n    env:\n      ACTIONLINT_VERSION: %s\n' \
		"$2" "$3" > "$WORK/t/.github/workflows/reusable-workflow-lint.yml"
}

# The stub answers for a repository from $WORK/gh/<owner>_<repo>.json, fails
# when there is no fixture, and records every call.
mkdir -p "$WORK/bin" "$WORK/gh"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
repo=""
while [ $# -gt 0 ]; do
	case "$1" in --repo) repo="$2"; shift 2 ;; *) shift ;; esac
done
f="$GH_FIXTURES/${repo/\//_}.json"
[ -f "$f" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$WORK/bin/gh"

upstream() { # <owner_repo> <tag> <days ago> [<tag> <days ago>...]
	local name="$1" sep=""; shift
	{
		printf '['
		while [ $# -gt 1 ]; do
			printf '%s{"tagName":"%s","publishedAt":"%s"}' "$sep" "$1" "$(day "$2")"
			sep=","; shift 2
		done
		printf ']\n'
	} > "$WORK/gh/$name.json"
}

run() { # [root] -> output, status in rc
	: > "$WORK/gh.log"
	out="$(PATH="$WORK/bin:$PATH" GH_LOG="$WORK/gh.log" GH_FIXTURES="$WORK/gh" \
		CHECK_TOOL_VERSIONS_NOW="$NOW" bash "$SCRIPT" "${1:-$WORK/t}" 2>&1)"
	rc=$?
}

# --- current -------------------------------------------------------------------
tree v0.11.0 v0.11.0 v1.7.12
upstream koalaman_shellcheck v0.11.0 100 v0.10.0 400
upstream rhysd_actionlint v1.7.12 50 v1.7.11 90
run
check "pins that are the newest releases pass" "0" "$rc"
check "and each tool is reported current" "1" "$(said "$out" 'actionlint: v1.7.12 is the newest release')"
check "and both upstreams were asked, with the job's gh" "2" "$(grep -c '^release list --repo ' "$WORK/gh.log")"
check "and drafts and pre-releases are left out" "2" "$(grep -c -- '--exclude-drafts --exclude-pre-releases' "$WORK/gh.log")"

# --- behind, within the lag -----------------------------------------------------
upstream rhysd_actionlint v1.7.13 10 v1.7.12 50
run
check "a pin behind a release ten days old passes" "0" "$rc"
check "and says it is behind within the lag" "1" "$(said "$out" 'within the 30-day lag')"

# --- behind, past the lag --------------------------------------------------------
upstream rhysd_actionlint v1.7.13 40 v1.7.12 50
run
check "a pin behind a release forty days old fails" "1" "$rc"
check "and names the tool, the pin and the newest release" "1" \
	"$(said "$out" 'actionlint: v1.7.12 is pinned, v1.7.13 is the newest release of rhysd/actionlint')"
check "and the age of the release" "1" "$(said "$out" 'has been out 40 days')"
check "and shellcheck, which is current, is not blamed" "0" "$(said "$out" 'shellcheck: v0.11.0 is pinned')"

# The age counts from the first release after the pin, so a recent release does
# not reset the clock on a pin two releases behind.
upstream rhysd_actionlint v1.7.14 3 v1.7.13 40 v1.7.12 50
run
check "a pin behind an old release and a new one fails on the old one" "1" "$rc"
check "and the age is the old release's" "1" "$(said "$out" 'has been out 40 days')"

MAX_LAG_DAYS=60 run
check "the lag comes from MAX_LAG_DAYS, and sixty days admits the same pin" "0" "$rc"

# --- upstream cannot be read ----------------------------------------------------
upstream rhysd_actionlint v1.7.12 50
rm "$WORK/gh/koalaman_shellcheck.json"
run
check "an upstream gh cannot read fails" "1" "$rc"
check "and says which upstream" "1" "$(said "$out" 'cannot read the releases of koalaman/shellcheck')"

printf 'not json\n' > "$WORK/gh/koalaman_shellcheck.json"
run
check "an upstream answer that is not JSON fails" "1" "$rc"
check "and is reported as unreadable" "1" "$(said "$out" 'cannot read the releases of koalaman/shellcheck')"

printf '[]\n' > "$WORK/gh/koalaman_shellcheck.json"
run
check "an upstream that lists no release fails rather than passing" "1" "$rc"
check "and says nothing was compared" "1" "$(said "$out" 'lists no vMAJOR.MINOR.PATCH release')"

upstream koalaman_shellcheck latest 1 nightly 1
run
check "an upstream with no versioned release fails" "1" "$rc"
check "for the same reason" "1" "$(said "$out" 'lists no vMAJOR.MINOR.PATCH release')"

# --- pins that cannot be read ----------------------------------------------------
upstream koalaman_shellcheck v0.11.0 100
tree v0.11.0 v0.10.0 v1.7.12
run
check "two shellcheck pins that differ fail" "1" "$rc"
check "and say the two reusables disagree" "1" "$(said "$out" 'pin different shellcheck versions')"

tree v0.11.0 v0.11.0 latest
run
check "an actionlint pin that is not a version fails" "1" "$rc"
check "and says so" "1" "$(said "$out" "pinned version 'latest' is not")"

tree v0.11.0 v0.11.0 v1.9.0
run
check "a pin newer than every upstream release fails" "1" "$rc"
check "and says the pin is not an upstream release" "1" "$(said "$out" 'newer than every release of rhysd/actionlint')"

# --- the real reusables --------------------------------------------------------
# The pins of this repository, read the way the job reads them, against an
# upstream that lists exactly those versions.
real="$(python3 -I - "$HERE" <<'PY'
import sys, yaml
root = sys.argv[1]
lint = yaml.safe_load(open(root + "/.github/workflows/reusable-workflow-lint.yml"))
print(lint[True]["workflow_call"]["inputs"]["shellcheck-version"]["default"],
      lint["jobs"]["workflow-lint"]["env"]["ACTIONLINT_VERSION"])
PY
)"
upstream koalaman_shellcheck "${real% *}" 1
upstream rhysd_actionlint "${real#* }" 1
run "$HERE"
check "the pins of this repository are read and compared" "0" "$rc"
check "and both tools are compared" "1" "$(said "$out" '2 pinned tool(s) compared')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
