#!/usr/bin/env bash
#
# Per-object transport caps in verify-published.sh. The budget suite exercises
# retries and aggregate declarations; these cases exercise delivered bytes.
# Extract the shipped fetch function and caps, as the publish workflow suites
# extract their shipped step. Real curl reads sparse file:// bodies, so neither
# a signing key nor a listening socket nor external network access is needed.
# The destination is /dev/null: even the 300 MiB boundary allocates no disk.
#
# Requires: curl, python3, truncate, sha256sum.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VERIFY="$HERE/scripts/verify/verify-published.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

# Keep both the limits and their call-site wiring under test. verify_set's
# fourth argument is the transport cap for index/package bodies; the bootstrap
# signature passes its cap directly to fetch. A caller that drops its argument
# must not be hidden by a test that always supplies the expected constant.
python3 - "$VERIFY" > "$WORK/transport.sh" <<'PY'
import re
import sys
source = open(sys.argv[1]).read()
for name in ('MAX_INDEX_BYTES', 'MAX_POOL_OBJECT_BYTES', 'MAX_BOOTSTRAP_SIG_BYTES'):
    print(re.search(r'^' + name + r'=.*$', source, re.M)[0])
print(re.search(r'^fetch\(\) \{\n.*?^\}', source, re.M | re.S)[0])
for name, label in (('index', 'index file(s)'), ('package', 'package(s)')):
    call = next(line for line in source.splitlines()
                if line.startswith('verify_set "' + label + '"'))
    print(name + '_transfer() { ' + call + '; }')
sig_call = re.search(r'if (fetch "\$BASE_URL/\$BOOTSTRAP_DEB.asc".*?)(?=\s*\\\n\s*&&)',
                     source, re.S)[1]
print('signature_transfer() { ' + sig_call + '; }')
PY
# shellcheck source=/dev/null
. "$WORK/transport.sh"

# Only the budget clock and the verification layer are replaced. The curl
# invocation, byte caps and call-site arguments above are production code.
remaining() { echo 600; }
verify_set() { fetch "$BODY_URL" /dev/null "$4"; }
BASE_URL="file://$WORK"
# Read by the extracted index_transfer call.
# shellcheck disable=SC2034
DIST_PATH="dists/stable"
BOOTSTRAP_DEB="glyndor-archive-keyring.deb"
ln -s /dev/null "$WORK/bootstrap.asc"

check_transfer() { # <kind> <logical-bytes> <expected-curl-exit>
	local kind="$1" bytes="$2" want="$3" got=0 out
	truncate -s "$bytes" "$WORK/$BOOTSTRAP_DEB.asc"
	BODY_URL="$BASE_URL/$BOOTSTRAP_DEB.asc"
	out="$("${kind}_transfer" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ]; then
		echo "ok   - $kind body of $bytes bytes (curl exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $kind body of $bytes bytes (want curl exit $want, got $got)"
		printf '%s\n' "$out" | sed 's/^/       /'
		fail=$((fail + 1))
	fi
}

# curl's 63 identifies the transport size refusal, rather than a later hash,
# signature, timeout or URL error. Removing --max-filesize makes each attack
# return 0, which must fail even though a later verification could reject it.
# The exact-boundary control also rules out an unconditional curl failure and
# an off-by-one refusal. Use production defaults, not scaled-down test caps.
check_transfer index "$MAX_INDEX_BYTES" 0
check_transfer index "$((MAX_INDEX_BYTES + 1))" 63
check_transfer package "$MAX_POOL_OBJECT_BYTES" 0
check_transfer package "$((MAX_POOL_OBJECT_BYTES + 1))" 63
check_transfer signature "$MAX_BOOTSTRAP_SIG_BYTES" 0
check_transfer signature "$((MAX_BOOTSTRAP_SIG_BYTES + 1))" 63

# The real verify_set, with the real check_entry and fetch behind it, handed a small cap:
# the cap it is given has to reach curl. Replacing verify_set by a function that calls
# fetch directly, as the cases above do, would not notice a verify_set that dropped it.
python3 - "$VERIFY" > "$WORK/chain.sh" <<'PY'
import re
import sys
source = open(sys.argv[1]).read()
print(re.search(r'^sha256_of\(\) \{.*\}$', source, re.M)[0])
for name in ('check_entry', 'verify_set'):
    print(re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)[0])
PY
chain() { # $1=body size; the cap handed to verify_set is 1024 bytes
	(
		# shellcheck source=/dev/null
		. "$WORK/transport.sh"
		# shellcheck source=/dev/null
		. "$WORK/chain.sh"
		# The functions below are called by the extracted verify_set, not from here.
		# shellcheck disable=SC2317,SC2329
		elapsed() { echo 0; }
		# shellcheck disable=SC2317,SC2329
		retry_wait() { echo 0; }
		# shellcheck disable=SC2317,SC2329
		sleep() { :; }
		# shellcheck disable=SC2034
		BUDGET=600
		# shellcheck disable=SC2034
		ATTEMPTS=1
		BASE_URL="file://$WORK"
		rm -f "$WORK/obj.bin" "$WORK/served"
		head -c "$1" /dev/zero > "$WORK/obj.bin"
		printf '%s %s obj.bin\n' "$(sha256sum "$WORK/obj.bin" | cut -d' ' -f1)" "$1" > "$WORK/entries"
		verify_set "objects" "$WORK/entries" "" 1024 "" >/dev/null 2>&1
	)
}
rc=0; chain 1024 || rc=$?
check_exit() { # <description> <expected exit> <actual exit>
	if [ "$2" = "$3" ]; then
		echo "ok   - $1 (exit $3)"
		pass=$((pass + 1))
	else
		echo "FAIL - $1 (want exit $2, got $3)"
		fail=$((fail + 1))
	fi
}
check_exit "verify_set serves an object exactly at the cap it was handed" 0 "$rc"
rc=0; chain 1025 || rc=$?
check_exit "verify_set refuses an object one byte over the cap it was handed" 1 "$rc"

# The bootstrap package goes through the same pool cap on a call written over two
# lines, which the extraction above does not read. Join the continuation and
# require the cap to be the one the pool uses.
bootstrap_call="$(sed -z 's/\\\n[[:space:]]*/ /g' "$HERE/scripts/verify/verify-published.sh" | grep -F 'verify_set "bootstrap package(s)"' || true)"
# shellcheck disable=SC2016 # the pattern is the literal text of the call
case "$bootstrap_call" in
*'"$MAX_POOL_OBJECT_BYTES"'*)
	echo 'ok   - the bootstrap package is fetched under the pool object cap'
	pass=$((pass + 1))
	;;
*)
	echo "FAIL - the bootstrap package call does not pass MAX_POOL_OBJECT_BYTES: $bootstrap_call"
	fail=$((fail + 1))
	;;
esac

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
