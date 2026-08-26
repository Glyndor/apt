#!/usr/bin/env bash
#
# Tests for scripts/check-test-coverage.sh -- the gate that fails when a script
# in scripts/ has no test in tests/.
#
# The gate lives in scripts/, so it appears in its own input set. That is the
# whole design: exempting it, or deleting this file, turns the last case here
# red. A verifier that sits outside the set it verifies is how cargo-audit
# shipped a vulnerable dependency of its own for months while auditing everyone
# else's.
#
# Requires: nothing beyond coreutils.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$HERE/scripts/check-test-coverage.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

assert() { # <want-exit> <desc> -- <cmd...>
	local want="$1" desc="$2"; shift 3
	local got=0
	"$@" >/dev/null 2>&1 || got=$?
	if [ "$got" -eq "$want" ]; then
		echo "ok   - $desc (exit $got)"; pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want, got $got)"; fail=$((fail + 1))
	fi
}

assert_error() { # <want-exit> <needle> <desc> -- <cmd...>
	local want="$1" needle="$2" desc="$3"; shift 4
	local got=0 out
	out="$("$@" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$needle"; then
		echo "ok   - $desc (exit $got)"; pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want containing '$needle', got exit $got: $out)"
		fail=$((fail + 1))
	fi
}

mkscript() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; }

# --- a tree where every script has a test -----------------------------------
mkscript "$WORK/ok/scripts/alpha.sh"
mkscript "$WORK/ok/tests/alpha.test.sh"
assert 0 "a tree where every script has a test passes" \
	-- "$GATE" "$WORK/ok"

# --- one script without a test ----------------------------------------------
#
# The message must name the script. "1 script is uncovered" sends the reader
# looking, which is the difference between a gate and a nuisance.
mkscript "$WORK/gap/scripts/alpha.sh"
mkscript "$WORK/gap/scripts/beta.sh"
mkscript "$WORK/gap/tests/alpha.test.sh"
assert_error 1 "beta.sh" \
	"an uncovered script is named, not merely counted" \
	-- "$GATE" "$WORK/gap"

# --- every uncovered script, not just the first -----------------------------
#
# Reporting one at a time turns a five-script gap into five CI runs.
mkscript "$WORK/many/scripts/alpha.sh"
mkscript "$WORK/many/scripts/beta.sh"
mkscript "$WORK/many/scripts/gamma.sh"
mkscript "$WORK/many/tests/alpha.test.sh"
assert_error 1 "gamma.sh" \
	"the second uncovered script is named too" \
	-- "$GATE" "$WORK/many"
assert_error 1 "2 script(s)" \
	"and the count matches how many were named" \
	-- "$GATE" "$WORK/many"

# --- a tests/ file with no script is not an error ---------------------------
#
# The gate asserts one direction. tests/ also holds tests for things that are
# not scripts -- the README bootstrap, for one -- and flagging those would make
# the gate wrong about this repository.
mkscript "$WORK/extra/scripts/alpha.sh"
mkscript "$WORK/extra/tests/alpha.test.sh"
mkscript "$WORK/extra/tests/readme-bootstrap.test.sh"
assert 0 "a test with no matching script is not flagged" \
	-- "$GATE" "$WORK/extra"

# --- an empty scripts/ directory --------------------------------------------
#
# The glob stays literal when nothing matches. Without the existence check the
# gate would report a script called '*.sh'.
mkdir -p "$WORK/empty/scripts" "$WORK/empty/tests"
assert 0 "an empty scripts/ directory passes rather than inventing a name" \
	-- "$GATE" "$WORK/empty"

# --- a tree with no scripts/ at all -----------------------------------------
mkdir -p "$WORK/noscripts"
assert_error 1 "no scripts/ directory" \
	"a tree without scripts/ is refused rather than silently passing" \
	-- "$GATE" "$WORK/noscripts"

# --- the gate is inside its own input set -----------------------------------
#
# This is the case the design exists for. Delete tests/check-test-coverage.test.sh
# and the gate names scripts/check-test-coverage.sh as uncovered, which turns
# the run below red. The gate cannot pass while being the only unchecked thing
# in the repository.
assert 0 "the gate has a test of its own here" \
	-- test -f "$HERE/tests/check-test-coverage.test.sh"

assert 0 "the gate passes against this repository, itself included" \
	-- "$GATE" "$HERE"

# The case above is not enough on its own, and I only found that out by trying
# the shortcut. Adding `[ "$name" = check-test-coverage ] && continue` to the
# gate leaves this whole file green: the exemption is invisible while the test
# file exists. So put a copy of the gate in a tree where it has no test and
# require it to name itself. That is the property -- the gate is inside its own
# input set -- rather than the symptom.
mkdir -p "$WORK/self/scripts" "$WORK/self/tests"
cp "$GATE" "$WORK/self/scripts/check-test-coverage.sh"
assert_error 1 "scripts/check-test-coverage.sh" \
	"the gate reports itself when it is the uncovered script" \
	-- "$GATE" "$WORK/self"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
