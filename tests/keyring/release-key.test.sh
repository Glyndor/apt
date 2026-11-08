#!/usr/bin/env bash
#
# The committed release public key, keyring/glyndor-release-ed25519.b64, is what
# verify-debs.sh checks every product .deb against. Every suite that reaches
# verify-debs generates its own throwaway key, so the committed file was read by
# nothing: a truncated or replaced key passed every pull request and surfaced as
# a failed publish the next morning.
#
# The rule here is verify-debs.sh's own reading of the file (one base64 key per
# non-empty, non-comment line, whitespace stripped), plus what an Ed25519 public
# key has to be: 32 bytes. The helper is run over broken copies first, because a
# check that accepts a bad file proves nothing about the real one.
#
# Requires: bash, base64, wc.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY="$HERE/keyring/glyndor-release-ed25519.b64"
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

# Prints "<n> keys" when every key line decodes to 32 bytes, else "bad: <why>".
audit() { # <file>
	local line n=0 bytes
	while IFS= read -r line || [ -n "$line" ]; do
		line="$(printf '%s' "$line" | tr -d '[:space:]')"
		case "$line" in '' | '#'*) continue ;; esac
		if ! bytes="$(printf '%s' "$line" | base64 -d 2>/dev/null | wc -c)"; then
			echo "bad: not base64"
			return
		fi
		[ "$bytes" -eq 32 ] || { echo "bad: $bytes bytes, not 32"; return; }
		n=$((n + 1))
	done < "$1"
	[ "$n" -ge 1 ] || { echo "bad: no keys"; return; }
	echo "$n keys"
}

printf 'not-a-key-at-all\n' > "$WORK/garbage"
check "a line that is not base64 is refused" "bad: not base64" "$(audit "$WORK/garbage")"

head -c 40 "$KEY" > "$WORK/truncated"
check "a truncated key is refused" "bad: 30 bytes, not 32" "$(audit "$WORK/truncated")"

printf '# only a comment\n\n' > "$WORK/empty"
check "a file with no keys is refused" "bad: no keys" "$(audit "$WORK/empty")"

check "the committed file is not empty" "1" "$([ -s "$KEY" ] && echo 1 || echo 0)"
check "every key in the committed file is a 32-byte Ed25519 public key" "1 keys" "$(audit "$KEY")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
