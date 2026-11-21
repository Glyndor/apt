#!/usr/bin/env bash
#
# scripts/quality/check-mutation-coverage.sh fails when a refusal in a script
# has neither an entry in the mutation catalogue nor a written exemption. A
# checker that always agrees looks as good as one that reads the scripts, so the
# fixture carries every shape of refusal the scripts here use and each case
# removes the one thing that covers a single refusal and requires that refusal
# to be named. Then the checker runs over this repository, which has to pass,
# and over a copy with one entry taken out, which must not.
#
# Requires: bash, python3.
# shellcheck disable=SC2016,SC1003 # the fixtures are literal shell code, quotes and $ included
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$HERE/scripts/quality/check-mutation-coverage.sh"
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
mkdir -p "$F/scripts/area" "$F/keyring/upgrade" "$F/tests/mutation" "$F/.github/workflows"
{
	printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
	printf '%s\n' '# exit 1 in a comment is not a refusal'
	printf '%s\n' 'echo "a string that says exit 1 is not one either"'
	printf '%s\n' '[ -n "${1:-}" ] || { echo "no argument" >&2; exit 2; }'
	printf '%s\n' 'if [ "$1" = bad ]; then' '	echo "bad" >&2' '	exit 1' 'fi'
	printf '%s\n' 'value="$(cat "$1")" \' '	|| { echo "unreadable" >&2; exit 1; }'
	printf '%s\n' 'case "$value" in' '	*..*)' '		echo "dots" >&2' '		exit 1 ;;' 'esac'
	printf '%s\n' 'python3 - "$value" <<'"'"'PY'"'"'' 'import sys' 'if len(sys.argv[1]) > 9:' '    sys.exit(3)' 'PY'
	printf '%s\n' 'fail "not a helper here, so not a refusal"' 'echo ok'
} > "$F/scripts/area/guard.sh"
{
	printf '%s\n' '#!/bin/sh' 'fail() {' '	echo "$*" >&2' '	exit 1' '}'
	printf '%s\n' '[ -f /etc/hostname ] || fail "no hostname"'
} > "$F/keyring/upgrade/tool"
printf '%s\n' 'not a script, so its exit 1 is not read' > "$F/scripts/area/notes.txt"
{
	printf '%s\n' 'jobs:' '  publish:' '    steps:' '      - name: Step' '        run: |'
	printf '%s\n' '          if [ -z "$TOKEN" ]; then' '            echo "::error::no token"' '            exit 1' '          fi'
} > "$F/.github/workflows/publish.yml"

entry() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
{
	entry guard-argument scripts/area/guard.sh '[ -n "${1:-}" ] || { echo "no argument" >&2; exit 2; }' '[ -n "${1:-}" ] || true' tests/a.test.sh
	entry guard-bad scripts/area/guard.sh 'if [ "$1" = bad ]; then' 'if false; then' tests/a.test.sh
	entry guard-unreadable scripts/area/guard.sh '|| { echo "unreadable" >&2; exit 1; }' '|| true' tests/a.test.sh
	entry guard-dots scripts/area/guard.sh '*..*)' '__never__)' tests/a.test.sh
	entry guard-python scripts/area/guard.sh 'if len(sys.argv[1]) > 9:' 'if False:' tests/a.test.sh
	entry publish-token .github/workflows/publish.yml 'if [ -z "$TOKEN" ]; then' 'if false; then' tests/b.test.sh
} > "$F/tests/mutation/catalog.txt"
printf '%s\t%s\t%s\n' keyring/upgrade/tool '|| fail "no hostname"' 'the fixture exempts it' > "$F/tests/mutation/exemptions.txt"
cp -r "$F" "$WORK/pristine"

run() { # -> rc; output in $WORK/out
	bash "$CHECK" "$F" > "$WORK/out" 2>&1
}
said() { grep -cF -- "$1" "$WORK/out"; }
reset() { rm -rf "$F"; cp -r "$WORK/pristine" "$F"; }
drop() { # <id>: remove one entry from the fixture catalogue
	grep -v "^$1	" "$F/tests/mutation/catalog.txt" > "$WORK/cat" && mv "$WORK/cat" "$F/tests/mutation/catalog.txt"
}
line_of() { grep -nF -- "$2" "$F/$1" | head -1 | cut -d: -f1; }

# --- the control: everything covered ------------------------------------------
rc=0; run || rc=$?
check "a fixture whose every refusal is covered passes" "0" "$rc"
check "and counts the seven refusals, not the comment, the string, the text file or the undefined fail" "1" \
	"$(said '7 refusal(s) in 3 script(s): 6 catalogued, 1 exempt.')"

# --- each shape of refusal is found once its cover is gone ------------------------
for case in "guard-argument:scripts/area/guard.sh:no argument" \
	"guard-bad:scripts/area/guard.sh:if [ \"\$1\" = bad ]; then" \
	"guard-unreadable:scripts/area/guard.sh:value=\"\$(cat" \
	"guard-dots:scripts/area/guard.sh:*..*)" \
	"guard-python:scripts/area/guard.sh:if len(sys.argv[1]) > 9:" \
	"publish-token:.github/workflows/publish.yml:if [ -z"; do
	id="${case%%:*}"; rest="${case#*:}"; file="${rest%%:*}"; first="${rest#*:}"
	reset; drop "$id"
	rc=0; run || rc=$?
	check "without $id the check fails" "1" "$rc"
	check "and names the refusal from its first line" "1" \
		"$(said "$file:$(line_of "$file" "$first")-")"
done

reset; : > "$F/tests/mutation/exemptions.txt"
rc=0; run || rc=$?
check "a fail call of a helper the file defines is a refusal" "1" "$rc"
check "and it is named with its line" "1" "$(said "keyring/upgrade/tool:$(line_of keyring/upgrade/tool '|| fail')-")"

# --- exemptions -----------------------------------------------------------------
reset; printf '%s\t%s\t%s\n' keyring/upgrade/tool '*' 'the whole file' > "$F/tests/mutation/exemptions.txt"
rc=0; run || rc=$?
check "a whole-file exemption covers the file" "0" "$rc"

reset; printf '%s\t%s\t%s\n' scripts/area/guard.sh '*' 'the whole file' >> "$F/tests/mutation/exemptions.txt"
rc=0; run || rc=$?
check "a whole-file exemption of a file with entries is refused" "1" "$rc"
check "and says to exempt its refusals one by one" "1" "$(said 'exempt its refusals one by one')"

reset; printf '%s\t%s\t%s\n' keyring/upgrade/tool '|| fail "no such text"' 'gone' > "$F/tests/mutation/exemptions.txt"
rc=0; run || rc=$?
check "an exemption whose text is not in the file is refused" "1" "$rc"
check "and says so" "1" "$(said 'its text is not in keyring/upgrade/tool: ')"

# Two refusals written alike cannot be told apart by an entry, whose text the
# runner wants once; one exemption may name both, and every place its text
# occurs has to be a refusal.
reset; printf '%s\n' '[ -d /etc ] || fail "no hostname"' >> "$F/keyring/upgrade/tool"
rc=0; run || rc=$?
check "an exemption whose text occurs twice exempts both refusals" "0" "$rc"
reset; printf '%s\n' "echo '|| fail \"no hostname\"'" >> "$F/keyring/upgrade/tool"
rc=0; run || rc=$?
check "and one of whose occurrences is not a refusal is refused" "1" "$rc"
check "naming where it reaches nothing" "1" "$(said 'reaches no refusal; delete it or narrow it')"

reset; printf '%s\t%s\t\n' keyring/upgrade/tool '|| fail "no hostname"' > "$F/tests/mutation/exemptions.txt"
rc=0; run || rc=$?
check "an exemption without a reason is refused" "1" "$rc"

reset; printf '%s\t%s\t%s\n' scripts/area/guard.sh 'echo ok' 'reaches nothing' >> "$F/tests/mutation/exemptions.txt"
rc=0; run || rc=$?
check "an exemption that reaches no refusal is refused" "1" "$rc"
check "and says to delete it" "1" "$(said 'reaches no refusal; delete it')"

reset; printf '%s\t%s\t%s\n' scripts/area/guard.sh 'if [ "$1" = bad ]; then' 'also catalogued' >> "$F/tests/mutation/exemptions.txt"
rc=0; run || rc=$?
check "an exemption of a catalogued refusal is refused" "1" "$rc"
check "and says to delete the exemption" "1" "$(said 'has an entry; delete the exemption')"

reset; printf '%s\t%s\t%s\n' scripts/area/notes.txt '*' 'not a script' >> "$F/tests/mutation/exemptions.txt"
rc=0; run || rc=$?
check "an exemption of a file the check does not read is refused" "1" "$rc"

reset; rm "$F/.github/workflows/publish.yml"; drop publish-token
rc=0; run || rc=$?
check "a missing publish workflow is an error, not a smaller set" "1" "$rc"

# --- an entry the sweep could not apply ---------------------------------------------
# The runner refuses these too, but only when it reaches them.
reset; entry guard-gone scripts/area/guard.sh 'a text the script no longer holds' 'true' tests/a.test.sh >> "$F/tests/mutation/catalog.txt"
rc=0; run || rc=$?
check "an entry whose text is not in its file is refused" "1" "$rc"
check "naming the entry and the count" "1" "$(said 'guard-gone: its text is in scripts/area/guard.sh 0 time(s), not once')"
reset; entry guard-twice scripts/area/guard.sh 'exit 1' 'exit 0' tests/a.test.sh >> "$F/tests/mutation/catalog.txt"
rc=0; run || rc=$?
check "an entry whose text is in its file more than once is refused" "1" "$rc"
check "naming the entry" "1" "$(said 'guard-twice: its text is in scripts/area/guard.sh ')"
reset; entry guard-same scripts/area/guard.sh 'echo ok' 'echo ok' tests/a.test.sh >> "$F/tests/mutation/catalog.txt"
rc=0; run || rc=$?
check "an entry that replaces its text with itself is refused" "1" "$rc"
check "and says so" "1" "$(said 'guard-same: it replaces its text with itself')"
reset; entry elsewhere-gone docs/absent.md 'anything' 'nothing' tests/a.test.sh >> "$F/tests/mutation/catalog.txt"
rc=0; run || rc=$?
check "an entry of a file that is not there is refused, outside the scripts as well" "1" "$rc"
check "naming the file" "1" "$(said 'elsewhere-gone: docs/absent.md cannot be read')"
mkdir -p "$F/docs"; printf '%s\n' 'anything' > "$F/docs/absent.md"
rc=0; run || rc=$?
check "and the same entry passes once its text is there once" "0" "$rc"

# --- this repository --------------------------------------------------------------
rc=0; bash "$CHECK" "$HERE" > "$WORK/out" 2>&1 || rc=$?
check "every refusal in this repository has an entry or an exemption" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$WORK/out"

R="$WORK/repo"
mkdir -p "$R/tests/mutation" "$R/.github/workflows"
cp -r "$HERE/scripts" "$R/"; mkdir -p "$R/keyring"; cp -r "$HERE/keyring/upgrade" "$R/keyring/"
cp "$HERE"/.github/workflows/*.yml "$R/.github/workflows/"
cp "$HERE/tests/mutation/exemptions.txt" "$R/tests/mutation/" 2>/dev/null || true
grep -v '^verify-debs-missing-signature	' "$HERE/tests/mutation/catalog.txt" > "$R/tests/mutation/catalog.txt"
rc=0; bash "$CHECK" "$R" > "$WORK/out" 2>&1 || rc=$?
check "and the same tree without the missing-signature entry fails" "1" "$rc"
check "naming the refusal of verify-debs.sh it covered" "1" \
	"$(grep -c 'scripts/verify/verify-debs.sh:.*a refusal with no entry' "$WORK/out")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
