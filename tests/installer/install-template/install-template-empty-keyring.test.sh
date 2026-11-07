#!/usr/bin/env bash
# An empty shipped keyring must name the missing archive key, even though the
# later signature check would also refuse it. Use real packages and signatures.
# shellcheck disable=SC1091 # shared fixture path is resolved at runtime
# shellcheck disable=SC2154 # the sourced fixture owns fingerprints and counters
. "$(cd "$(dirname "$0")/../../fixtures/installer" && pwd)/fixture.sh"

# Prove that the sandbox can accept and install the same package shape.
DEB="$(mkdeb populated good no)"
rc=0; run_installer "$DEB" "$FPR_GOOD" || rc=$?
check 'a keyring carrying the expected key is accepted' 0 "$rc"
check 'the populated keyring reaches dpkg -i' 1 "$(installed)"

# Keep the keyring file but put no keys in it. Sign with good explicitly, since
# mkdeb normally signs with the first key included in the package.
DEB="$(mkdeb empty '' no good)"
check 'the fixture really ships a zero-byte keyring' 0 \
	"$(wc -c < "$WORK/pkg-empty/usr/share/keyrings/glyndor.gpg" | tr -d '[:space:]')"
rc=0; run_installer "$DEB" "$FPR_GOOD" || rc=$?
check 'a keyring without any archive key is rejected' 1 "$rc"
check 'the rejection names the missing archive key' 1 \
	"$(said 'carries no archive key at all')"
check 'the empty keyring never reaches dpkg -i' 0 "$(installed)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
