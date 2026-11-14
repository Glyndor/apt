#!/usr/bin/env bash
#
# Tests for scripts/installer/install-template.sh, the rendered installer that runs as
# root on the operator's machine, downloads the archive keyring, and installs
# a Glyndor product from it.
#
# The cases pin an ORDER: the archive keyring is verified BEFORE dpkg is
# allowed to run anything from the package. A .deb that executes first can
# write the very keyring the check then reads, with the expected fingerprint
# alongside an attacker's, which the presence test admits. The verify reads
# the extracted payload, not a file dpkg has already written.
#
# Cases 1-3 are structural assertions: they read the rendered script rather
# than running it, because running the real installer needs root and a live
# archive. A reader must know these are not behavioural tests.
#
# Requires: bash, sed, the rendered install.sh is executable.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$HERE/scripts/installer/install-template.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# assert <expected-exit> <description> -- <command...>
assert() {
	local want="$1" desc="$2"
	shift 3 # drop want, desc, and the literal "--"
	local got=0
	"$@" >/dev/null 2>&1 || got=$?
	if [ "$got" -eq "$want" ]; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want, got $got)"
		fail=$((fail + 1))
	fi
}

# assert_error <expected-exit> <needle> <description> -- <command...>
# Same as assert, but also requires the combined stdout+stderr to contain
# needle, so a rejection is checked for the right reason, not just any exit.
assert_error() {
	local want="$1" needle="$2" desc="$3"
	shift 4 # drop want, needle, desc, and the literal "--"
	local got=0 out
	out="$("$@" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && printf '%s' "$out" | grep -qF "$needle"; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want containing '$needle', got exit $got: $out)"
		fail=$((fail + 1))
	fi
}

# Render the template the way scripts/build/build-installers.sh does: a single
# `sed s/@PRODUCT@/<product>/g`. The cases must work against the rendered
# output (what end users actually run), not the template's literal placeholder.
render() {
	local product="$1"
	sed "s/@PRODUCT@/$product/g" "$TEMPLATE" > "$WORK/install.sh"
	chmod +x "$WORK/install.sh"
}

render podup

# --- Cases 1-3: inspect executable extraction, never comments -----------------
# The producer reads the deb into a bounded tar stream. The consumer must run
# after that stream exists and before gpg reads the extracted keyring.
extraction_order() { # $1=rendered installer
	local producer extract verify install
	producer="$(grep -nE '^[[:blank:]]*dpkg-deb --fsys-tarfile ' "$1" | cut -d: -f1)"
	extract="$(grep -nE '^[[:blank:]]*tar -x -f - -C ' "$1" | cut -d: -f1)"
	verify="$(grep -nE '^keyring_fprs=.*gpg --show-keys --with-colons ' "$1" | cut -d: -f1)"
	install="$(grep -nE '^[[:blank:]]*dpkg -i ' "$1" | cut -d: -f1)"
	[ -n "$producer" ] && [ -n "$extract" ] && [ -n "$verify" ] && [ -n "$install" ] \
		&& [ "$producer" -lt "$extract" ] && [ "$extract" -lt "$verify" ] \
		&& [ "$verify" -lt "$install" ]
}
assert 0 "the tar stream is extracted before fingerprint verification and installation" \
	-- extraction_order "$WORK/install.sh"

# Sabotage copies only: leaving the old dpkg-deb -x COMMENT must not save them.
sed '/^tar -x /,+1d' "$WORK/install.sh" > "$WORK/no-extraction.sh"
assert 1 "deleting extraction fails the order check even with the old comment" \
	-- extraction_order "$WORK/no-extraction.sh"
# Move the real consumer before the producer. Merely seeing both commands is
# insufficient: it would try to read a stream that has not yet been produced.
awk '/^dpkg-deb --fsys-tarfile / {print "tar -x -f - -C \"$workdir/extracted\" --no-same-owner < \"$workdir/keyring.tar\""}
	/^tar -x / {skip=1; next} skip {skip=0; next} {print}' \
	"$WORK/install.sh" > "$WORK/early-extraction.sh"
assert 1 "moving extraction before its producer fails the order check" \
	-- extraction_order "$WORK/early-extraction.sh"

# --- Case 4: a machine without apt-get is refused before any download --------
# Run the installer with an empty PATH so apt-get cannot be found. The script
# must exit on the apt-get check rather than reaching the network. bash is
# invoked by absolute path: `env PATH=... bash ...` would otherwise resolve
# `bash` through the new (empty) PATH and fail with "bash: not found", which
# would pass the assertion for the wrong reason.
# The fixture must be valid in every respect EXCEPT the one under test. The
# installer checks for root (line 36) BEFORE it checks for apt-get (line 38),
# so a non-root test can never reach the apt-get check: it dies on "run this as
# root" and the assertion would pass for the wrong reason. The PATH below
# therefore carries a stub `id` that reports uid 0 -- the test is not root, it
# only needs the root guard to let it through -- plus the coreutils the script
# uses before the apt-get check, and deliberately no apt-get.
mkdir -p "$WORK/no-apt/bin"
cat >"$WORK/no-apt/bin/id" <<'STUB'
#!/bin/sh
echo 0
STUB
chmod +x "$WORK/no-apt/bin/id"
for c in cat rm mktemp; do
	src="$(command -v "$c" 2>/dev/null)" || continue
	[ -n "$src" ] && ln -sf "$src" "$WORK/no-apt/bin/$c"
done
assert_error 1 "no apt-get found" \
	"a machine without apt-get is refused before anything is downloaded" \
	-- env PATH="$WORK/no-apt/bin" /bin/bash "$WORK/install.sh"

echo
echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
