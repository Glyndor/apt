#!/usr/bin/env bash
#
# scripts/quality/coverage/check-mutation-coverage.sh fails when a refusal in a script
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
# Python that refuses with a message instead of a number, and the exits that are not refusals.
{
	printf '%s\n' '#!/usr/bin/env bash' "python3 - \"\$1\" <<'PY'" 'import sys'
	printf '%s\n' 'if sys.argv[1] == "a":' '    sys.exit("a plain string")'
	printf '%s\n' 'if sys.argv[1] == "b":' '    sys.exit(f"an f-string {sys.argv[1]}")'
	printf '%s\n' 'if sys.argv[1] == "c":' '    raise SystemExit("raised")'
	printf '%s\n' 'if sys.argv[1] == "d":' '    raise SystemExit(f"raised {sys.argv[1]}")'
	printf '%s\n' 'if sys.argv[1] == "e":' '    sys.exit("joined " + " ".join(sys.argv))'
	printf '%s\n' 'if sys.argv[1] == "zero":' '    sys.exit(0)'
	printf '%s\n' 'if sys.argv[1] == "empty":' '    sys.exit()'
	printf '%s\n' 'if sys.argv[1] == "none":' '    sys.exit(None)'
	printf '%s\n' 'if sys.argv[1] == "bare":' '    raise SystemExit'
	printf '%s\n' 'if sys.argv[1] == "name":' '    code = 2' '    sys.exit(code)'
	printf '%s\n' 'PY'
} > "$F/scripts/area/messages.sh"
{
	printf '%s\n' '#!/bin/sh' 'fail() {' '	echo "$*" >&2' '	exit 1' '}'
	printf '%s\n' '[ -f /etc/hostname ] || fail "no hostname"'
} > "$F/keyring/upgrade/tool"
# A function that refuses by returning 1 to its caller, the returns that are
# not refusals, and a Python `return 1` that is a value.
{
	printf '%s\n' '#!/usr/bin/env bash' 'probe() {' '	if [ ! -r "$1" ]; then' '		echo "unreadable" >&2'
	printf '%s\n' '		return 1' '	fi' '}'
	printf '%s\n' 'fine() { return 0; }' 'quiet() { return; }' 'passthrough() { "$@"; local rc=$?; return "$rc"; }'
	printf '%s\n' "python3 - <<'PY'" 'def check(value):' '    if value:' '        return 1' '    return 0' 'PY'
} > "$F/scripts/area/funcs.sh"
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
	entry func-unreadable scripts/area/funcs.sh 'if [ ! -r "$1" ]; then' 'if false; then' tests/a.test.sh
	for letter in a b c d e; do
		entry "message-$letter" scripts/area/messages.sh "if sys.argv[1] == \"$letter\":" 'if False:' tests/a.test.sh
	done
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
check "and counts the thirteen refusals, not the comment, the string, the text file, the undefined fail, the Python exits that end well or the returns that are not refusals" "1" \
	"$(said '13 refusal(s) in 5 script(s): 12 catalogued, 1 exempt.')"

# --- each shape of refusal is found once its cover is gone ------------------------
for case in "guard-argument:scripts/area/guard.sh:no argument" \
	"guard-bad:scripts/area/guard.sh:if [ \"\$1\" = bad ]; then" \
	"guard-unreadable:scripts/area/guard.sh:value=\"\$(cat" \
	"guard-dots:scripts/area/guard.sh:*..*)" \
	"guard-python:scripts/area/guard.sh:if len(sys.argv[1]) > 9:" \
	"publish-token:.github/workflows/publish.yml:if [ -z" \
	"func-unreadable:scripts/area/funcs.sh:if [ ! -r" \
	"message-a:scripts/area/messages.sh:if sys.argv[1] == \"a\":" \
	"message-b:scripts/area/messages.sh:if sys.argv[1] == \"b\":" \
	"message-c:scripts/area/messages.sh:if sys.argv[1] == \"c\":" \
	"message-d:scripts/area/messages.sh:if sys.argv[1] == \"d\":" \
	"message-e:scripts/area/messages.sh:if sys.argv[1] == \"e\":"; do
	id="${case%%:*}"; rest="${case#*:}"; file="${rest%%:*}"; first="${rest#*:}"
	reset; drop "$id"
	rc=0; run || rc=$?
	check "without $id the check fails" "1" "$rc"
	check "and names the refusal from its first line" "1" \
		"$(said "$file:$(line_of "$file" "$first")-")"
done

# A message is a refusal, and the exits that end well are not: the same line
# becomes one the moment its argument is a string, so each was passed over for
# its argument and not by accident of where it sits.
for form in 'sys.exit(0)' 'sys.exit()' 'sys.exit(None)' 'raise SystemExit'; do
	reset; awk -v form="    $form" '$0 == form { print "    sys.exit(\"now a message\")"; next } { print }' \
		"$F/scripts/area/messages.sh" > "$WORK/messages" && mv "$WORK/messages" "$F/scripts/area/messages.sh"
	rc=0; run || rc=$?
	check "$form is not a refusal, and becomes one as sys.exit(\"...\")" "1" "$rc"
	check "naming the line it is on" "1" "$(said 'now a message')"
done
reset; awk '$0 == "    sys.exit(code)" { print "    sys.exit(\"now a message\")"; next } { print }' \
	"$F/scripts/area/messages.sh" > "$WORK/messages" && mv "$WORK/messages" "$F/scripts/area/messages.sh"
rc=0; run || rc=$?
check "a status held in a variable is not read, and a message in its place is" "1" "$rc"

# A literal non-zero return of a shell function is a refusal; `return 0`, a
# bare `return` and a status held in a variable are not, and each becomes one
# the moment its status is a literal 1. The Python `return 1` is a value, and
# reads as a refusal once the heredoc that makes it Python is gone.
for form in 'fine() { return 0; }' 'quiet() { return; }' 'passthrough() { "$@"; local rc=$?; return "$rc"; }'; do
	reset; awk -v form="$form" '$0 == form { sub(/return( 0| "\$rc")?;/, "return 1;") } { print }' \
		"$F/scripts/area/funcs.sh" > "$WORK/funcs" && mv "$WORK/funcs" "$F/scripts/area/funcs.sh"
	now="$(grep -F "${form%%(*}()" "$F/scripts/area/funcs.sh")"
	check "the fixture now returns 1 in ${form%%(*}" "1" "$(printf '%s\n' "$now" | grep -c 'return 1;')"
	rc=0; run || rc=$?
	check "${form} is not a refusal, and becomes one as return 1" "1" "$rc"
	check "naming the line it is on" "1" "$(said ": $now")"
done
reset; sed -i "s/^python3 - <<'PY'\$/cat <<'PY'/" "$F/scripts/area/funcs.sh"
rc=0; run || rc=$?
check "a return 1 in the Python of a heredoc is not read, and is once the heredoc is not Python" "1" "$rc"
check "naming the line" "1" "$(said "scripts/area/funcs.sh:$(line_of scripts/area/funcs.sh '    if value:')-")"

# An exit that hands on a status it holds in a variable is the verdict of a step or
# of a script: changed to `exit 0`, nothing it collected reaches the caller. It is
# read, whatever the status is on a given run. The forms that hand nothing on are
# not, and neither is a helper that returns a status to its caller.
# shellcheck disable=SC2016 # the forms are literal shell code
for form in 'exit "$verdict"' 'exit $verdict' 'exit "${verdict}"' 'exit $?'; do
	reset; printf '%s\n' 'verdict=0' 'true || verdict=1' "$form" >> "$F/scripts/area/guard.sh"
	rc=0; run || rc=$?
	check "$form hands on a status, and is a refusal" "1" "$rc"
	check "naming the line it is on" "1" "$(said ": $form")"
done
# shellcheck disable=SC2016
for form in 'exit 0' 'exit' 'echo "exit $verdict"' "trap 'exit \"\$verdict\"' EXIT" 'hand_back() { "$@"; local rc=$?; return "$rc"; }'; do
	reset; printf '%s\n' 'verdict=0' "$form" >> "$F/scripts/area/guard.sh"
	rc=0; run || rc=$?
	check "$form hands on nothing, and is not a refusal" "0" "$rc"
done
# The word in the Python of a heredoc is not the shell's, and is once the heredoc
# is not Python.
# shellcheck disable=SC2016
for reader in "python3 -" cat; do
	reset; printf '%s\n' '#!/usr/bin/env bash' "$reader <<'PY'" 'verdict = 0' 'exit $verdict' 'PY' > "$F/scripts/area/heredoc.sh"
	rc=0; run || rc=$?
	case "$reader" in
		cat) check "an exit with an expansion in a heredoc that is not Python is read" "1 1" "$rc $(said ': exit $verdict')" ;;
		*) check "an exit with an expansion in the Python of a heredoc is not read as the shell's" "0 0" "$rc $(said ': exit $verdict')" ;;
	esac
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
