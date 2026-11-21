#!/usr/bin/env bash
#
# The README tells a reader to run one gpg command on the unpacked keyring and says the
# fingerprint it prints must be exactly the one published beside it. That holds only if the
# command prints the fingerprint in the form the README shows: `gpg --show-keys` alone prints
# it as forty unbroken characters, and `--fingerprint` prints it in groups of four, so a
# README that asks for one and shows the other sends a careful reader to compare two strings
# that cannot be equal. The installer prints the grouped form, so the grouped form is the one
# the README keeps.
#
# This runs the command the README gives on the committed key, in the C locale, and requires
# every fingerprint line it prints to be a whole line of the README. The key is the committed
# armoured one rather than the unpacked package: the package carries the same key, and nothing
# here needs a build. Two copies of the README that break it, one by dropping the option that
# groups the digits and one by publishing the ungrouped form, must each be refused by name.
#
# Requires: gpg, coreutils, grep.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEYRING="$HERE/keyring/glyndor-apt-key.asc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# problems <readme>: one line per thing wrong, nothing when the command prints only what the
# README publishes. A command that cannot be read from the README, or that prints no
# fingerprint, is named: a check that inspected nothing must not read as a pass.
problems() {
	local readme="$1" cmd printed line
	local -a words
	cmd="$(grep -E '^gpg --show-keys ' "$readme" || true)"
	if [ "$(printf '%s' "$cmd" | grep -c .)" -ne 1 ]; then
		echo "the README does not give exactly one gpg --show-keys command"; return 0
	fi
	read -ra words <<<"$cmd"
	words[${#words[@]}-1]="$KEYRING"
	printed="$(LC_ALL=C "${words[@]}" 2>/dev/null | sed -E 's/^[[:space:]]+//' | grep -E '^[0-9A-F]{4}( {0,2}[0-9A-F]{4}){9}$' || true)"
	[ -n "$printed" ] || { echo "the command prints no fingerprint line"; return 0; }
	while IFS= read -r line; do
		grep -qxF -- "$line" "$readme" || echo "the command prints '$line', which the README does not publish"
	done <<<"$printed"
}

real="$(grep -E '^[0-9A-F]{4}( [0-9A-F]{4}){4}  [0-9A-F]{4}( [0-9A-F]{4}){4}$' "$HERE/README.md" | head -1)"
check "the README publishes its fingerprint in groups of four" "1" "$([ -n "$real" ] && echo 1 || echo 0)"
check "the command the README gives prints only what it publishes" "" "$(problems "$HERE/README.md")"

# A copy of the README with one change, which is refused for the reason it was made.
variant() { # <name> <sed expression>
	sed "$2" "$HERE/README.md" > "$WORK/$1.md"
	if cmp -s "$HERE/README.md" "$WORK/$1.md"; then echo "FIXTURE INERT: $1"; fi
}
variant ungrouped-command 's/^gpg --show-keys --fingerprint /gpg --show-keys /'
check "a command that prints the digits unbroken is refused for the form" \
	"the command prints '$(printf '%s' "$real" | tr -d ' ')', which the README does not publish" "$(problems "$WORK/ungrouped-command.md")"
variant ungrouped-published "s/^$real\$/$(printf '%s' "$real" | tr -d ' ')/"
check "a README that publishes the digits unbroken is refused for the form" \
	"the command prints '$real', which the README does not publish" "$(problems "$WORK/ungrouped-published.md")"
variant no-command '/^gpg --show-keys /d'
check "a README without the command is named, not passed" \
	"the README does not give exactly one gpg --show-keys command" "$(problems "$WORK/no-command.md")"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
