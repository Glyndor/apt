#!/usr/bin/env bash
# The runner of the catalogue is tested too: a catalogue whose entry dies, survives, is
# inert or leaves a syntax error has to be reported as such. A runner that always says
# "killed" would look as good as one that tells the truth, and nothing else tells them
# apart: the catalogue is only worth something if the runner refuses a survivor.
#
# The cases use a throwaway repository with a guard of its own; nothing touches the
# repository of this one, and nothing touches the network.
# shellcheck disable=SC2016 # the fixtures are literal shell code, ${1:-} included
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1 (expected $2, got $3)"
		fail=$((fail + 1))
	fi
}
has() { # <text> <file> -> the number of lines that hold the text
	grep -c -F -- "$1" "$2" || true
}
hasone() { # <text> <file> -> 1 when the file holds the text at least once
	grep -qF -- "$1" "$2" && echo 1 || echo 0
}

# A repository of its own: a guard with two refusals, so the catalogue has a text that
# appears twice to work with, a suite that watches that guard, a suite that fails on its
# own, and a suite whose name is on the runner's always-excluded list.
TOY="$WORK/toy"
mkdir -p "$TOY/scripts" "$TOY/tests/mutation" "$TOY/tests/ci/suites"
cat > "$TOY/scripts/guard.sh" <<'SH'
#!/usr/bin/env bash
# A guard with two refusals.
set -uo pipefail
if [ "${1:-}" = "bad" ]; then
	echo "refused"
	exit 1
fi
if [ "${1:-}" = "worse" ]; then
	echo "refused"
	exit 1
fi
echo "ok"
SH
cat > "$TOY/scripts/guard.py" <<'PY'
#!/usr/bin/env python3
# A guard that carries its python in a heredoc, the way the scripts of this
# repository carry theirs.
import sys

if len(sys.argv) > 1 and sys.argv[1] == "bad":
	print("refused")
	sys.exit(1)
print("ok")
PY
cat > "$TOY/tests/guard.test.sh" <<'SH'
#!/usr/bin/env bash
# The suite that watches the guard.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
rc=0
out="$(bash "$HERE/scripts/guard.sh" bad 2>&1)" || rc=$?
if [ "$rc" -ne 1 ]; then
	echo "FAIL  the guard did not refuse"
	exit 1
fi
if [ "$out" != "refused" ]; then
	echo "FAIL  the guard refused with $out"
	exit 1
fi
exit 0
SH
cat > "$TOY/tests/broken.test.sh" <<'SH'
#!/usr/bin/env bash
# A suite that fails whatever the mutant is: it cannot tell a mutant from an
# unmutated tree, so the runner has to exclude it.
echo "FAIL  this suite is red on its own"
exit 1
SH
cat > "$TOY/tests/ci/suites/check-suite-completeness.test.sh" <<'SH'
#!/usr/bin/env bash
# A suite whose name is on the runner's always-excluded list.
exit 0
SH
cat > "$TOY/scripts/hd.sh" <<'SH'
#!/usr/bin/env bash
python3 - "$@" <<'PY'
import sys
if len(sys.argv) > 1 and sys.argv[1] == "bad":
    print("refused")
    sys.exit(1)
print("ok")
PY
SH
cat > "$TOY/tests/hd.test.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
rc=0
out="$(bash "$HERE/scripts/hd.sh" bad 2>&1)" || rc=$?
if [ "$rc" -ne 1 ] || [ "$out" != "refused" ]; then
	echo "FAIL  the python guard did not refuse"
	exit 1
fi
exit 0
SH
cat > "$TOY/tests/crash.test.sh" <<'SH'
#!/usr/bin/env bash
# A suite that dies instead of failing an assertion: it prints no FAIL line.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
rc=0
bash "$HERE/scripts/guard.sh" bad >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { echo "died with $rc" >&2; exit 3; }
exit 0
SH
printf 'hello\n' > "$TOY/scripts/notes.txt"
# A workflow and a suite that reads it, for the mutations that target YAML.
mkdir -p "$TOY/.github/workflows"
printf 'suites: [a, b]\n' > "$TOY/.github/workflows/w.yml"
printf '#!/usr/bin/env bash\ngrep -qF "[a, b]" "$(dirname "$0")/../.github/workflows/w.yml"\n' > "$TOY/tests/w.test.sh"
git -C "$TOY" init -q .
git -C "$TOY" add -A
git -C "$TOY" -c user.name=t -c user.email=t@example.invalid commit -q -m base

CATALOG="$TOY/tests/mutation/catalog.txt"
entry() { # <id> <old> <new> [tests]
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "scripts/guard.sh" "$2" "$3" "${4:-tests/guard.test.sh}" >"$CATALOG"
}
run() { # <arguments...> -> the exit status of the runner, its output in $WORK/out
	local rc=0
	bash "$HERE/run-mutations.sh" --repo "$TOY" "$@" >"$WORK/out" 2>&1 || rc=$?
	echo "$rc"
}

# A mutation the suite notices: the runner says so and exits 0.
entry dies 'if [ "${1:-}" = "bad" ]; then' 'if false; then'
check "a mutation the suite notices passes the runner" "0" "$(run)"
check "and the message names the test that noticed it" "1" "$(has 'killed by tests/guard.test.sh' "$WORK/out")"
check "and the reason the suite went red, not only the colour" "1" "$(has 'the guard did not refuse' "$WORK/out")"

check "and a kill that shows its FAIL line raises no warning" "0" "$(has 'without a FAIL line' "$WORK/out")"

# A suite that dies instead of failing: it is still a kill, and the runner says it
# showed no reason, at the entry and again at the end of the sweep.
entry crashes 'if [ "${1:-}" = "bad" ]; then' 'if false; then' tests/crash.test.sh
check "a suite that dies counts as a kill" "0" "$(run)"
check "and the entry is flagged as one with no FAIL line" "1" "$(has 'went red without a FAIL line' "$WORK/out")"
check "and the sweep counts it at the end" "1" "$(has '1 kill(s) with no FAIL line' "$WORK/out")"
entry dies 'if [ "${1:-}" = "bad" ]; then' 'if false; then'

# A mutation no test notices: the runner has to fail and name it.
entry survives 'echo "ok"' 'echo "fine"'
check "a mutation no test notices fails the runner" "1" "$(run)"
check "and the message names the survivor" "1" "$(has 'mutation survives: SURVIVED' "$WORK/out")"
check "and says that it survived" "1" "$(has 'SURVIVED, none of the tests it names failed' "$WORK/out")"

# A text that appears nowhere: the mutation would change nothing and prove nothing.
entry absent 'if [ "${1:-}" = "absent" ]; then' 'if false; then'
check "a text that appears nowhere fails the runner" "1" "$(run)"
check "and says the text is not in the file" "1" "$(has 'the text to replace is not in' "$WORK/out")"

# A text that appears twice: the mutation is ambiguous.
entry repeated 'exit 1' 'exit 2'
check "a text that appears twice fails the runner" "1" "$(run)"
check "and says the text is not there exactly once" "1" "$(has 'exactly once' "$WORK/out")"

# A mutation that leaves the file with a syntax error is not a kill.
entry syntax 'echo "ok"' 'echo "ok'
check "a mutation that breaks the syntax fails the runner" "1" "$(run)"
check "and says the file has a syntax error" "1" "$(has 'syntax error' "$WORK/out")"

# A workflow is mutated like a script, and its syntax is checked as YAML.
printf '%s\t%s\t%s\t%s\t%s\n' yml-dies .github/workflows/w.yml "[a, b]" "[a, c]" tests/w.test.sh >"$CATALOG"
check "a mutation of a workflow that its suite notices passes the runner" "0" "$(run)"
printf '%s\t%s\t%s\t%s\t%s\n' yml-syntax .github/workflows/w.yml "[a, b]" "[a, b" tests/w.test.sh >"$CATALOG"
check "a mutation that breaks a workflow's YAML fails the runner" "1" "$(run)"
check "and says the workflow has a syntax error" "1" "$(has 'syntax error' "$WORK/out")"

# The python of a heredoc is part of the file: `bash -n` cannot see it, and a
# mutation that breaks it would read as a kill of a guard that was never removed.
printf '%s\t%s\t%s\t%s\t%s\n' \
	"pythonsyntax" "scripts/guard.py" "if len(sys.argv) > 1 and sys.argv[1] == \"bad\":" \
	"if len(sys.argv) > 1 and sys.argv[1] == \"bad\"" "tests/guard.test.sh" >"$CATALOG"
check "a mutation that breaks the python of a heredoc fails the runner" "1" "$(run)"
check "and says the file has a syntax error" "1" "$(has 'syntax error' "$WORK/out")"

# A suite that fails on its own cannot tell a mutant from an unmutated tree, so
# the runner excludes it instead of counting it as a kill.
entry red 'if [ "${1:-}" = "bad" ]; then' 'if false; then' "tests/broken.test.sh"
check "a suite that fails on its own fails the runner" "1" "$(run)"
check "and the runner says it is excluded" "1" "$(has 'fails without any mutation, it is excluded' "$WORK/out")"
check "and refuses to count the entry as a kill" "1" "$(has 'none of them can tell' "$WORK/out")"

# A suite on the always-excluded list is never run, whatever it would say.
entry excluded 'if [ "${1:-}" = "bad" ]; then' 'if false; then' \
	"tests/ci/suites/check-suite-completeness.test.sh"
check "a suite on the always-excluded list fails the runner" "1" "$(run)"
check "and the runner says why it is excluded" "1" "$(hasone 'needs the git metadata the copy does not have' "$WORK/out")"

# --list prints the ids and runs nothing.
entry dies 'if [ "${1:-}" = "bad" ]; then' 'if false; then'
rc=0
out="$(bash "$HERE/run-mutations.sh" --repo "$TOY" --list 2>&1)" || rc=$?
check "--list exits 0" "0" "$rc"
check "and prints the id" "dies" "$out"

# An id that is not in the catalogue is an error, not a silent pass.
check "an unknown id fails the runner" "2" "$(run absent-id)"
check "and says there is no mutation with that id" "1" "$(has 'no mutation with the id' "$WORK/out")"

# Catalogues the runner has to refuse before it measures anything.
entryf() { # <id> <file> <old> <new> [tests]
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-tests/guard.test.sh}" >"$CATALOG"
}
printf '# nothing here\n' >"$CATALOG"
check "a catalogue with no entries fails the runner" "2" "$(run)"
check "and says it has no entries" "1" "$(has 'has no entries' "$WORK/out")"
printf 'twice\tscripts/guard.sh\techo "ok"\techo "fine"\ttests/guard.test.sh\ntwice\tscripts/guard.sh\techo "ok"\techo "fine"\ttests/guard.test.sh\n' >"$CATALOG"
check "a catalogue with a repeated id fails the runner" "2" "$(run)"
check "and says the id is repeated" "1" "$(has 'more than once' "$WORK/out")"
printf 'empty\tscripts/guard.sh\t\techo "fine"\ttests/guard.test.sh\n' >"$CATALOG"
check "a catalogue line with an empty field fails the runner" "2" "$(run)"
check "and says the field is empty" "1" "$(has 'empty field' "$WORK/out")"
printf 'tabs\tscripts/guard.sh\techo "ok"\n' >"$CATALOG"
check "a catalogue line with the wrong number of tabs fails the runner" "2" "$(run)"
check "and says it needs four tabs" "1" "$(has 'four tabs' "$WORK/out")"

# An entry the runner cannot measure is not a kill.
entryf missing scripts/nope.sh 'echo "ok"' 'echo "fine"'
check "a file that is not in the repository fails the runner" "1" "$(run)"
check "and says the file is not in the copy" "1" "$(has 'is not in the copy of the repository' "$WORK/out")"
entryf notes scripts/notes.txt 'hello' 'bye'
check "a file the runner cannot parse fails the runner" "1" "$(run)"
check "and says there is no syntax check for it" "1" "$(has 'no syntax check' "$WORK/out")"
entry same 'echo "ok"' 'echo "ok"'
check "a mutation that replaces the text with itself fails the runner" "1" "$(run)"

# A suite that is already red measures nothing: counting it as a kill would turn any
# broken suite into a green sweep.
entry red 'echo "ok"' 'echo "fine"' tests/broken.test.sh
check "an entry whose suite fails without any mutation fails the runner" "1" "$(run)"
check "and says the suite fails without any mutation" "1" "$([ "$(has 'fails without any mutation' "$WORK/out")" -ge 1 ] && echo 1 || echo 0)"

# The python of a heredoc is part of the file and `bash -n` cannot see it: a mutation that
# breaks it dies of a python error, which must not read as a guard that was removed.
entryf pyhd scripts/hd.sh 'if len(sys.argv) > 1 and sys.argv[1] == "bad":' 'if len(sys.argv) > 1 and sys.argv[1] == "bad"' tests/hd.test.sh
check "a mutation that breaks the python of a heredoc fails the runner" "1" "$(run)"
check "and says the file has a syntax error" "1" "$(has 'syntax error' "$WORK/out")"
entryf pyok scripts/hd.sh 'sys.exit(1)' 'sys.exit(0)' tests/hd.test.sh
check "a python guard that is really removed is killed" "0" "$(run)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
