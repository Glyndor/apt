#!/usr/bin/env bash
# Tests for scripts/lint-workflow-shell.sh.
#
# The point of the script is that a linter which inspected nothing prints the
# same success line as one that inspected everything, so the tests that matter
# here are the ones that plant a violation and require red, and the one that
# hands it a tree with no workflows and requires red for that too. A test that
# only ran it against the real tree and checked for exit 0 would pass just as
# happily against a script that returns 0 unconditionally.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/scripts/lint-workflow-shell.sh"

pass=0
fail=0

check() { # $1=description $2=expected $3=actual
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok   - $1"
	else
		fail=$((fail + 1))
		echo "FAIL - $1: expected '$2', got '$3'"
	fi
}

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "FAIL - shellcheck is not on PATH; these tests cannot run" >&2
	exit 1
fi

# --- the repository's own workflows --------------------------------------

out="$("$SCRIPT" style 2>&1)"
rc=$?
check "this repository's embedded shell is clean at the strictest severity" "0" "$rc"

# A count of zero would pass the exit-code assertion above while proving
# nothing, which is the whole failure mode this script exists to close.
blocks="$(printf '%s' "$out" | sed -n 's/^\([0-9]\+\) embedded.*/\1/p')"
check "and it reports how many blocks it inspected" "1" \
	"$([ -n "$blocks" ] && echo 1 || echo 0)"
check "and that count is greater than zero" "1" \
	"$([ "${blocks:-0}" -gt 0 ] && echo 1 || echo 0)"

# --- a planted violation must turn it red --------------------------------

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts" "$work/.github/workflows"
cp "$SCRIPT" "$work/scripts/"

cat >"$work/.github/workflows/planted.yml" <<'YML'
name: planted
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: a violation shellcheck is certain to catch
        run: |
          set -euo pipefail
          rm -rf $UNQUOTED/*
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
check "a planted violation fails" "1" "$rc"
check "and names the rule it tripped" "1" \
	"$(printf '%s' "$out" | grep -q 'SC2115' && echo 1 || echo 0)"

# The finding is useless if it points at a temporary file, and misleading if
# it points at the wrong line of the right file. `run: |` is line 8 of the
# workflow above and the offending command is line 10.
check "and reports it against the workflow, not the temporary copy" "1" \
	"$(printf '%s' "$out" | grep -q 'file=.github/workflows/planted.yml' && echo 1 || echo 0)"
check "and on the line the offending command is on" "1" \
	"$(printf '%s' "$out" | grep -q 'line=10' && echo 1 || echo 0)"

# --- an empty tree must turn it red too ----------------------------------

rm -f "$work/.github/workflows/planted.yml"
out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
check "a tree with no run: blocks fails rather than reporting success" "1" "$rc"
check "and says the extractor found nothing" "1" \
	"$(printf '%s' "$out" | grep -q 'found no' && echo 1 || echo 0)"

# --- a GitHub expression is not a finding --------------------------------

cat >"$work/.github/workflows/expressions.yml" <<'YML'
name: expressions
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: quoted expression, which is correct shell
        run: |
          set -euo pipefail
          echo "${{ github.sha }}"
YML

out="$(cd "$work" && ./scripts/lint-workflow-shell.sh style 2>&1)"
rc=$?
check "a quoted GitHub expression is not reported as a shell problem" "0" "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
