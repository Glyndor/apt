#!/usr/bin/env bash
#
# scripts/quality/coverage/check-mutation-coverage.sh reads the `run:` blocks of
# every workflow under .github/workflows/, not only publish.yml: the other
# workflows hold the gates of every pull request, and a refusal added to one of
# them has to have a mutation entry or an exemption like any other. Only the
# shell is read, so YAML that says `exit 1` in a name or a description is not a
# refusal.
#
# The fixture is a tree with two workflows. Each case removes the one thing that
# covers a refusal and requires the check to name it. Then the check runs over
# this repository, which has to pass, and over a copy with the entry of one
# workflow refusal taken out, which must not. This suite is separate from
# check-mutation-coverage.test.sh because its verdict depends on every
# workflow, so a change to any of them selects it.
#
# Requires: bash, python3.
# shellcheck disable=SC2016 # the fixtures are literal shell code, quotes and $ included
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECK="$HERE/scripts/quality/coverage/check-mutation-coverage.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

F="$WORK/fixture"
mkdir -p "$F/scripts" "$F/keyring/upgrade" "$F/tests/mutation" "$F/.github/workflows"
{
	printf '%s\n' 'jobs:' '  publish:' '    steps:' '      - name: Step' '        run: |'
	printf '%s\n' '          if [ -z "$TOKEN" ]; then' '            echo "::error::no token"' '            exit 1' '          fi'
} > "$F/.github/workflows/publish.yml"
{
	printf '%s\n' 'name: Gate' 'description: stops with exit 1 when the gate fails' 'jobs:' '  gate:'
	printf '%s\n' '    # a comment that says exit 1' '    steps:' '      - name: exit 1 in a step name'
	printf '%s\n' '        run: |' '          if [ -z "$VALUE" ]; then' '            exit 1' '          fi'
	printf '%s\n' '      - run: test -n "$OTHER" || exit 2'
	printf '%s\n' '      - name: Folded' '        run: >-' '          [ -n "$THIRD" ]' '          || exit 3'
} > "$F/.github/workflows/gate.yml"

entry() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
{
	entry publish-token .github/workflows/publish.yml 'if [ -z "$TOKEN" ]; then' 'if false; then' tests/b.test.sh
	entry gate-value .github/workflows/gate.yml 'if [ -z "$VALUE" ]; then' 'if false; then' tests/b.test.sh
	entry gate-other .github/workflows/gate.yml 'test -n "$OTHER" || exit 2' 'true' tests/b.test.sh
	entry gate-third .github/workflows/gate.yml '|| exit 3' '|| true' tests/b.test.sh
} > "$F/tests/mutation/catalog.txt"
: > "$F/tests/mutation/exemptions.txt"
cp -r "$F" "$WORK/pristine"

run() { bash "$CHECK" "$F" > "$WORK/out" 2>&1; }
said() { grep -cF -- "$1" "$WORK/out"; }
reset() { rm -rf "$F"; cp -r "$WORK/pristine" "$F"; }
drop() { grep -v "^$1	" "$F/tests/mutation/catalog.txt" > "$WORK/cat" && mv "$WORK/cat" "$F/tests/mutation/catalog.txt"; }
line_of() { grep -nF -- "$2" "$F/$1" | head -1 | cut -d: -f1; }

# --- the control -----------------------------------------------------------------
rc=0; run || rc=$?
check "a tree whose every workflow refusal is covered passes" "0" "$rc"
check "and counts the shell of both workflows, not the name, the description or the comment" "1" \
	"$(said '4 refusal(s) in 2 script(s): 4 catalogued, 0 exempt.')"

# --- a workflow that is not publish.yml is read ------------------------------------
for case in "gate-value:if [ -z" "gate-other:- run: test -n" "gate-third:[ -n \"\$THIRD\" ]"; do
	id="${case%%:*}"; first="${case#*:}"
	reset; drop "$id"
	rc=0; run || rc=$?
	check "without $id the check fails" "1" "$rc"
	check "and names the refusal in gate.yml from its first line" "1" \
		"$(said ".github/workflows/gate.yml:$(line_of .github/workflows/gate.yml "$first")-")"
done

# The YAML around the shell says `exit 1` three times and none of it runs. The
# same words in a `run:` are a refusal, so they were passed over for where they
# sit and not because the pattern misses them.
reset; sed -i 's/^description: stops with exit 1 when the gate fails$/  run: exit 1/' "$F/.github/workflows/gate.yml"
rc=0; run || rc=$?
check "a description that says exit 1 is not read, and the same words as a run: are" "1" "$rc"
check "naming the line" "1" "$(said '.github/workflows/gate.yml:2-')"
reset; sed -i 's/^      - name: exit 1 in a step name$/      - run: exit 1/' "$F/.github/workflows/gate.yml"
rc=0; run || rc=$?
check "a step name that says exit 1 is not read, and the same words as a run: are" "1" "$rc"

# A line indented under the run: key and past the end of its block is YAML again.
reset; printf '%s\n' '        env:' '          NOTE: exit 4' >> "$F/.github/workflows/gate.yml"
rc=0; run || rc=$?
check "a key after the block ends is not shell" "0" "$rc"

reset; rm "$F/.github/workflows/"*.yml
mkdir -p "$F/scripts/area"; printf '%s\n' '#!/bin/sh' '[ -n "$1" ] || exit 1' > "$F/scripts/area/one.sh"
entry one scripts/area/one.sh '[ -n "$1" ] || exit 1' '[ -n "$1" ] || true' tests/a.test.sh > "$F/tests/mutation/catalog.txt"
rc=0; run || rc=$?
check "a tree with no workflow is an error, not a smaller set" "1" "$rc"
check "and says the workflows cannot be read" "1" "$(said 'holds no workflow')"

# --- this repository -----------------------------------------------------------------
rc=0; bash "$CHECK" "$HERE" > "$WORK/out" 2>&1 || rc=$?
check "every refusal of this repository, its workflows included, has an entry or an exemption" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$WORK/out"

R="$WORK/repo"
mkdir -p "$R/tests/mutation" "$R/.github/workflows" "$R/keyring"
cp -r "$HERE/scripts" "$R/"; cp -r "$HERE/keyring/upgrade" "$R/keyring/"
cp "$HERE"/.github/workflows/*.yml "$R/.github/workflows/"
cp "$HERE/tests/mutation/exemptions.txt" "$R/tests/mutation/"
grep -v '^health-check-stale	' "$HERE/tests/mutation/catalog.txt" > "$R/tests/mutation/catalog.txt"
rc=0; bash "$CHECK" "$R" > "$WORK/out" 2>&1 || rc=$?
check "and the same tree without the entry of the health check's staleness refusal fails" "1" "$rc"
check "naming the refusal of health-check.yml it covered" "1" \
	"$(grep -c '.github/workflows/health-check.yml:.*a refusal with no entry' "$WORK/out")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
