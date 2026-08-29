#!/usr/bin/env bash
# Behaviour tests for the shellcheck job in
# .github/workflows/reusable-shell-ci.yml.
#
# The collection step decides what gets linted, and everything it fails to
# collect is a file the gate reports success on without opening. That is the
# failure this repository already hit once, so the cases below are about what
# the collector finds rather than about shellcheck itself.
#
# Requires: python3, git, shellcheck.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Pull one step's `run:` body out of a workflow, dedented, so it can be run.
# Same helper as tests/update-workflow.test.sh: the point is to exercise the
# shell as it ships rather than a copy of it that can drift.
step_script() { # $1=workflow path  $2=step name substring
	python3 - "$1" "$2" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "name: " + sys.argv[2] in l)
run = next(i for i, l in enumerate(lines) if i > start and l.strip() == "run: |")
body = []
for line in lines[run + 1:]:
    if not line.strip():
        body.append("")
        continue
    if not line.startswith(" " * 10):
        break
    body.append(line[10:])
print("\n".join(body))
PY
}

WORKFLOW="$HERE/.github/workflows/reusable-shell-ci.yml"
step_script "$WORKFLOW" "Collect shell scripts" > "$WORK/collect.sh"
step_script "$WORKFLOW" "Run shellcheck" > "$WORK/lint.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "FAIL  shellcheck is not on PATH; these tests cannot run" >&2
	exit 1
fi

# $RUNNER_TEMP is where the collector writes its file list on a runner.
run_both() { # $1=dir -> collector then linter, in that directory
	local tmp="$WORK/rt"
	rm -rf "$tmp"; mkdir -p "$tmp"
	( cd "$1" && RUNNER_TEMP="$tmp" bash "$WORK/collect.sh" \
		&& RUNNER_TEMP="$tmp" SEVERITY=style bash "$WORK/lint.sh" ) 2>&1
}

collected() { # $1=dir -> how many files the collector picked up
	local tmp="$WORK/rt2"
	rm -rf "$tmp"; mkdir -p "$tmp"
	( cd "$1" && RUNNER_TEMP="$tmp" bash "$WORK/collect.sh" ) >/dev/null 2>&1
	tr -cd '\0' < "$tmp/shell-files" | wc -c
}

new() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; printf '%s' "$WORK/t"; }

# --- a violation in a .sh must be reported -------------------------------

d="$(new)"
# The single quotes are the point: the fixture must contain a literal
# `$UNQUOTED` for shellcheck to complain about when it lints the file,
# not this test's expansion of it.
# shellcheck disable=SC2016
printf '#!/bin/sh\nrm -rf $UNQUOTED/*\n' > "$d/bad.sh"
# xargs reports 123 when a command it ran failed, so the job's exit is 123
# rather than shellcheck's own 1. What the gate promises is a red job, so
# that is what is asserted; pinning the exact number would make this test
# fail the day the runner is changed to loop instead of using xargs.
out="$(run_both "$d")"; rc=$?
check "a violation in a .sh fails" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and names the rule" "1" \
	"$(printf '%s' "$out" | grep -q 'SC2115' && echo 1 || echo 0)"

# --- an extensionless script is found by its shebang ---------------------
#
# This is the half of the collector that has no extension to go on, so a
# regression here is invisible: the file is simply never opened.

d="$(new)"
# The single quotes are the point: the fixture must contain a literal
# `$UNQUOTED` for shellcheck to complain about when it lints the file,
# not this test's expansion of it.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nrm -rf $UNQUOTED/*\n' > "$d/hook"
chmod +x "$d/hook"
check "an extensionless script with a shell shebang is collected" "1" "$(collected "$d")"
out="$(run_both "$d")"; rc=$?
check "and its violation fails the job" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# --- a shebang that is not a shell is left alone -------------------------

d="$(new)"
printf '#!/usr/bin/env python3\nimport os\n' > "$d/tool"
chmod +x "$d/tool"
check "a python shebang is not collected" "0" "$(collected "$d")"

# --- clean input passes --------------------------------------------------

d="$(new)"
printf '#!/bin/sh\nset -eu\necho "hello"\n' > "$d/good.sh"
out="$(run_both "$d")"; rc=$?
check "a clean script passes" "0" "$rc"
check "and it was actually collected, not skipped into a pass" "1" "$(collected "$d")"

# --- nothing to lint is not a failure, but must collect nothing ----------

d="$(new)"
printf 'plain text\n' > "$d/notes.txt"
check "a tree with no shell collects nothing" "0" "$(collected "$d")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
