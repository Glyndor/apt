#!/usr/bin/env bash
#
# Tests for the budgets of scripts/verify/verify-published.sh: the budget that
# stops the retries, and the caps that keep the gate from turning into an
# unbounded download.
#
# The archive, the keys and the local HTTP server come from
# tests/fixtures/verify/verify-published-fixture.sh. The index and the pool are in
# tests/verify/verify-published.test.sh, and the bootstrap pair is in
# tests/verify/verify-published/verify-published-bootstrap.test.sh.
#
# Each case asserts the script's exit status (0 = archive consistent,
# non-zero = rejected) so a regression that lets a broken archive through
# fails CI.
#
# Requires: gpg, curl, python3, sha256sum.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/fixtures/verify/verify-published-fixture.sh
. "$HERE/tests/fixtures/verify/verify-published-fixture.sh"

pass=0
fail=0

# --- the budget stops the retries, where attempts alone could not ------------
#
# The retry loop exists to absorb an asynchronous edge purge, and until
# 2026-09-08 nothing bounded what it could cost. Against a peer that accepts a
# connection and never answers, one fetch burned --max-time times curl's own
# retries: measured that day, four attempts and 18.0s at --max-time 3, which is
# 1800s at the 300 the script then carried, against a 900s job. The job was
# cancelled, so the ::error:: naming the file was never printed and the
# operator read a cancellation instead of a diagnosis.
#
# The observation that differs: with a mismatch that will never converge, the
# run ends by NAMING the budget rather than by exhausting attempts. Asserting
# only a non-zero exit would be satisfied by the attempts path, which is the
# one that already worked.
build_archive
sed -i 's/Architecture: arm64/Architecture: ar_64/' "$DIST/main/binary-arm64/Packages"
# The needle is the ATTEMPT NUMBER, not the word budget. Both paths end in the
# same message-selection branch, so a run that exhausted nine attempts and then
# noticed it was over budget prints the budget wording too. Only the attempt
# the loop STOPS on distinguishes them: bounded by the budget it is the first,
# bounded by attempts it is the ninth. Measured while writing this: asserting
# the wording passed with the budget condition deleted.
# The measurement is HOW MANY TIMES it retried, not the wording. Both paths end
# in the same message-selection branch, so a run that exhausted every attempt
# and then noticed it was over budget prints the budget wording too: asserting
# the words passed with the budget condition deleted, measured while writing
# this. The retry count is what the budget actually changes.
budget_out="$("$VERIFY" "$BASE" "$TRUSTED_ASC" 9 1 1 2>&1 || true)"
budget_retries="$(printf '%s' "$budget_out" | grep -c 'not yet consistent, re-reading')"
if [ "$budget_retries" -le 2 ]; then
	echo "ok   - the budget stops the retries early ($budget_retries re-reads of a possible 8)"
	pass=$((pass + 1))
else
	echo "FAIL - the budget did not stop the retries ($budget_retries re-reads)"
	printf '%s\n' "$budget_out" | sed 's/^/       /'
	fail=$((fail + 1))
fi

# The control. With a budget that is not in the way the same archive uses every
# attempt it was given, so the assertion above is about the budget rather than
# about a loop that never retries.
build_archive
sed -i 's/Architecture: arm64/Architecture: ar_64/' "$DIST/main/binary-arm64/Packages"
roomy_out="$("$VERIFY" "$BASE" "$TRUSTED_ASC" 4 0 600 2>&1 || true)"
roomy_retries="$(printf '%s' "$roomy_out" | grep -c 'not yet consistent, re-reading')"
if [ "$roomy_retries" -eq 3 ]; then
	echo "ok   - and with room to spare it uses every attempt ($roomy_retries re-reads)"
	pass=$((pass + 1))
else
	echo "FAIL - the roomy control did not use its attempts ($roomy_retries re-reads, wanted 3)"
	fail=$((fail + 1))
fi

# The other half. With a budget that is not in the way, the same archive still
# ends the way it always did, or the assertion above would be satisfied by a
# script that reported the budget for everything.
build_archive
sed -i 's/Architecture: arm64/Architecture: ar_64/' "$DIST/main/binary-arm64/Packages"
assert_error 1 "after 1 attempt" \
	"and with room to spare it still ends on the attempts" \
	-- "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0 600

# The budget is global: once it is spent, no further object is fetched, in the
# same round either. A curl that logs every request and then does the real work
# makes that visible: with a budget of one second the run must start fewer transfers
# than with room to spare, and still name what it did not verify. The spy
# sleeps a second per request so that a one-second budget is spent by the first.
build_archive
mkdir -p "$WORK/curlspy"
cat > "$WORK/curlspy/curl" <<SPY
#!/bin/sh
echo "\$*" >> "$WORK/curlspy/log"
sleep 1
exec $(command -v curl) "\$@"
SPY
chmod +x "$WORK/curlspy/curl"
: > "$WORK/curlspy/log"
PATH="$WORK/curlspy:$PATH" "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0 600 >/dev/null 2>&1 || true
roomy_fetches="$(wc -l < "$WORK/curlspy/log")"
: > "$WORK/curlspy/log"
zero_out="$(PATH="$WORK/curlspy:$PATH" "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0 1 2>&1 || true)"
zero_fetches="$(wc -l < "$WORK/curlspy/log")"
# A margin, not just "fewer": the transfers before verify_set (the signed indices)
# are made either way, and the old loop saved one of twelve by accident.
if [ $((zero_fetches + 4)) -le "$roomy_fetches" ]; then
	echo "ok   - a spent budget starts no further transfer ($zero_fetches against $roomy_fetches)"
	pass=$((pass + 1))
else
	echo "FAIL - a spent budget still started every transfer ($zero_fetches against $roomy_fetches)"
	fail=$((fail + 1))
fi
if printf '%s' "$zero_out" | grep -q 'budget ran out'; then
	echo "ok   - and it names the budget"
	pass=$((pass + 1))
else
	echo "FAIL - the spent budget was not named"
	printf '%s\n' "$zero_out" | sed 's/^/       /'
	fail=$((fail + 1))
fi

# --- The budget bounds the waits and the transfers, not only the loops -------
#
# Two holes sat behind the checks above, which only read the budget between
# rounds. A delay longer than the budget was slept in full: given a 3600s delay
# and a 3s budget, a mismatch that never converges waited an hour before the
# budget was looked at again. And every transfer carried a fixed 30s/60s
# deadline, so one download could spend more than the whole budget.
#
# The wait is measured by how long the run takes, under a hard timeout, and by
# the delay it announces: asserting only a non-zero exit is satisfied by the
# timeout killing it.
build_archive
sed -i 's/Architecture: arm64/Architecture: ar_64/' "$DIST/main/binary-arm64/Packages"
started="$(date -u +%s)"
long_out="$(timeout 40 "$VERIFY" "$BASE" "$TRUSTED_ASC" 3 3600 3 2>&1 || true)"
long_took=$(( $(date -u +%s) - started ))
long_waits="$(printf '%s' "$long_out" | sed -n 's/.*not yet consistent, re-reading in \([0-9]*\)s.*/\1/p' | sort -n | tail -1)"
if [ "$long_took" -lt 30 ] && [ -n "$long_waits" ] && [ "$long_waits" -le 3 ]; then
	echo "ok   - a delay longer than the budget is cut to what is left (${long_took}s, longest wait ${long_waits}s)"
	pass=$((pass + 1))
else
	echo "FAIL - a delay longer than the budget was slept in full (${long_took}s, longest wait '${long_waits}')"
	printf '%s\n' "$long_out" | sed 's/^/       /'
	fail=$((fail + 1))
fi
if printf '%s' "$long_out" | grep -q 'budget ran out'; then
	echo "ok   - and the run names the budget it ran out of"
	pass=$((pass + 1))
else
	echo "FAIL - the long delay did not end naming the budget"
	fail=$((fail + 1))
fi

# The control: a delay that fits is not shortened, or the cut above could be a
# script that no longer waits at all.
build_archive
sed -i 's/Architecture: arm64/Architecture: ar_64/' "$DIST/main/binary-arm64/Packages"
fits_out="$(timeout 60 "$VERIFY" "$BASE" "$TRUSTED_ASC" 2 2 600 2>&1 || true)"
if printf '%s' "$fits_out" | grep -q 're-reading in 2s'; then
	echo "ok   - and a delay that fits is waited in full"
	pass=$((pass + 1))
else
	echo "FAIL - a delay that fits was shortened"
	printf '%s\n' "$fits_out" | sed 's/^/       /'
	fail=$((fail + 1))
fi

# The transfers: the deadline handed to curl is what is left of the budget.
# The spy records the --max-time of every call and answers for it.
build_archive
mkdir -p "$WORK/limitspy"
cat > "$WORK/limitspy/curl" <<SPY
#!/bin/sh
echo "\$*" >> "$WORK/limitspy/log"
exec $(command -v curl) "\$@"
SPY
chmod +x "$WORK/limitspy/curl"
: > "$WORK/limitspy/log"
PATH="$WORK/limitspy:$PATH" "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0 5 >/dev/null 2>&1 || true
tight_max="$(sed -n 's/.*--max-time \([0-9]*\).*/\1/p' "$WORK/limitspy/log" | sort -n | tail -1)"
tight_retry="$(sed -n 's/.*--retry-max-time \([0-9]*\).*/\1/p' "$WORK/limitspy/log" | sort -n | tail -1)"
: > "$WORK/limitspy/log"
PATH="$WORK/limitspy:$PATH" "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0 600 >/dev/null 2>&1 || true
roomy_max="$(sed -n 's/.*--max-time \([0-9]*\).*/\1/p' "$WORK/limitspy/log" | sort -n | tail -1)"
if [ -n "$tight_max" ] && [ "$tight_max" -le 5 ] && [ "$tight_retry" -le 5 ]; then
	echo "ok   - no transfer is given a deadline past the budget (--max-time $tight_max, --retry-max-time $tight_retry, budget 5)"
	pass=$((pass + 1))
else
	echo "FAIL - a transfer outlasted the budget (--max-time '$tight_max', --retry-max-time '$tight_retry', budget 5)"
	fail=$((fail + 1))
fi
if [ "$roomy_max" = "30" ]; then
	echo "ok   - and with room to spare the transfer keeps its 30s deadline"
	pass=$((pass + 1))
else
	echo "FAIL - the roomy transfer deadline changed (--max-time '$roomy_max', wanted 30)"
	fail=$((fail + 1))
fi

# --- The caps: bounded work, not just bounded objects ------------------------
# The two caps are the only thing keeping a hostile or runaway index from
# turning this gate into an unbounded download. They are exercised here by
# lowering them below what the fixture declares, because an archive large
# enough to trip the defaults is not a fixture anybody should build.
build_archive
assert_error 1 "over the 3 cap" "an index declaring more files than the entry cap is rejected" -- \
	env VERIFY_PUBLISHED_MAX_ENTRIES=3 "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0
assert_error 1 "bytes of packages, over the 1 cap" "indices declaring more package bytes than the pool cap are rejected" -- \
	env VERIFY_PUBLISHED_MAX_POOL_BYTES=1 "$VERIFY" "$BASE" "$TRUSTED_ASC" 1 0
assert 0 "the caps at their defaults accept the same archive" -- run

# --- Result ------------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
