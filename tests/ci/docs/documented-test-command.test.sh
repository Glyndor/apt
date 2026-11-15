#!/usr/bin/env bash
#
# CONTRIBUTING.md gives the command that runs every suite before a push. The
# completeness runner executes the suites it is handed, so a documented loop that
# also runs them ran every suite twice. This runs the command as written over a
# small git tree and requires each nested suite to run exactly once, a failing
# one to fail the command and be named, and shellcheck to see nested scripts.
#
# Requires: bash, git, find, xargs, sort, awk.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
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

block="$(awk '/^## Tests/{t=1;next} /^## /{t=0} t&&/^```sh/{f=1;next} t&&/^```/{f=0} t&&f' "$HERE/CONTRIBUTING.md")"
check "CONTRIBUTING.md has a documented test command" "1" "$([ -n "$block" ] && echo 1 || echo 0)"

mkdir -p "$WORK/bin" "$WORK/t/tests/a/b" "$WORK/t/tests/ci/suites" "$WORK/t/scripts/x"
printf '#!/usr/bin/env bash\necho ran-good\nexit 0\n' > "$WORK/t/tests/a/good.test.sh"
printf '#!/usr/bin/env bash\necho ran-bad\nexit 1\n' > "$WORK/t/tests/a/b/bad.test.sh"
printf '#!/usr/bin/env bash\n: ok\n' > "$WORK/t/scripts/x/tool.sh"
# shellcheck disable=SC2016 # the stand-in reads these variables when it runs
printf '#!/usr/bin/env bash\n[ "$#" -gt 0 ] || { echo usage >&2; exit 2; }\nrc=0\nfor f in "$@"; do "$f" || { echo "FAIL  $f"; rc=1; }; done\nexit $rc\n' \
	> "$WORK/t/tests/ci/suites/check-suite-completeness.test.sh"
chmod +x "$WORK/t/tests/a/good.test.sh" "$WORK/t/tests/a/b/bad.test.sh" "$WORK/t/tests/ci/suites/check-suite-completeness.test.sh"
# shellcheck disable=SC2016 # the stub reads this variable when it runs
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/shellcheck.args"\nexit 0\n' "$WORK" > "$WORK/bin/shellcheck"
chmod +x "$WORK/bin/shellcheck"
git -C "$WORK/t" init -q
git -C "$WORK/t" add -A

out="$(cd "$WORK/t" && PATH="$WORK/bin:$PATH" bash -c "$block" 2>&1)"
rc=$?
check "a nested failing suite makes the documented command fail" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "the nested passing suite runs exactly once" "1" "$(printf '%s' "$out" | grep -c ran-good)"
check "the nested failing suite runs exactly once" "1" "$(printf '%s' "$out" | grep -c ran-bad)"
check "and the failure is named" "1" "$(printf '%s' "$out" | grep -c 'FAIL.*bad.test.sh')"
check "shellcheck is given a nested script" "1" "$(grep -c 'scripts/x/tool.sh' "$WORK/shellcheck.args" 2>/dev/null)"

git -C "$WORK/t" rm -qf tests/a/b/bad.test.sh
out="$(cd "$WORK/t" && PATH="$WORK/bin:$PATH" bash -c "$block" 2>&1)"
rc=$?
check "with every suite passing the documented command succeeds" "0" "$rc"

# A runner that lost its executable bit must not turn the command green by being
# skipped: it fails the command and says which file is the problem.
chmod -x "$WORK/t/tests/ci/suites/check-suite-completeness.test.sh"
out="$(cd "$WORK/t" && PATH="$WORK/bin:$PATH" bash -c "$block" 2>&1)"
rc=$?
check "a runner that is not executable fails the documented command" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and the message names the runner" "1" "$(printf '%s' "$out" | grep -c 'check-suite-completeness.test.sh is not executable')"
chmod +x "$WORK/t/tests/ci/suites/check-suite-completeness.test.sh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
