#!/usr/bin/env bash
# The installer opens the keyring it unpacks from the package before anything
# in the package has been verified. When that path is a FIFO, gpg waits for a
# writer that never comes: the installer hangs as root instead of refusing
# (issue #373). A link is refused for the same reason: the path is no longer
# the file that was looked at. Each case runs under a deadline, so a hang is a
# failed case and not a stuck job. The control is a copy of the template with
# the check on the keyring removed: there the FIFO times out and the link is
# accepted, which shows the refusal comes from that check.
# shellcheck disable=SC2016 # the patterns and the fixture command name variables on purpose
# shellcheck disable=SC1091 # shared fixture path is resolved at runtime
# shellcheck disable=SC2154 # the sourced fixture owns fingerprints and counters
. "$(cd "$(dirname "$0")/../../fixtures/installer" && pwd)/fixture.sh"

# run_installer with a deadline: 124 means the installer was still waiting.
run_timed() { # $1=template $2=deb $3=optional directory of stubs ahead of the rest
	rm -f "$WORK/marker"
	sed 's/@PRODUCT@/testpkg/g' "$1" > "$WORK/install.sh"
	timeout 20 env -i PATH="${3:+$3:}$BIN:$PATH" HOME="$WORK" WORK="$WORK" \
		DPKG_MARKER="$WORK/marker" KEYRING_URL="file://$2" GLYNDOR_APT_FPR="$FPR_GOOD" \
		/bin/sh "$WORK/install.sh" >"$WORK/out" 2>&1
}

# A package whose keyring path is made by $2 (a command run in the keyrings dir).
special_deb() { # $1=name $2=command
	local deb root
	deb="$(mkdeb "$1" good no)"
	root="$WORK/pkg-$1"
	( cd "$root/usr/share/keyrings" && rm -f glyndor.gpg && eval "$2" )
	dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null 2>&1
	sign_deb good "$deb"
	echo "$deb"
}

CUT="$WORK/install-without-the-check.sh"
grep -q 'require_regular_file "\$workdir/extracted\$KEYRING_PATH"' "$TEMPLATE" \
	|| { echo "FAIL  the template does not check the keyring path"; exit 1; }
sed 's|^require_regular_file "\$workdir/extracted\$KEYRING_PATH".*|:|' "$TEMPLATE" > "$CUT"
check 'the control differs from the template' 1 "$(cmp -s "$TEMPLATE" "$CUT" && echo 0 || echo 1)"

DEB="$(mkdeb ok good no)"
rc=0; run_timed "$TEMPLATE" "$DEB" || rc=$?
check 'a package with a regular keyring is installed' 0 "$rc"

DEB="$(special_deb fifo 'mkfifo glyndor.gpg')"
rc=0; run_timed "$TEMPLATE" "$DEB" || rc=$?
check 'a keyring that is a FIFO is refused, not waited on' 1 "$rc"
check 'and the refusal says it is a FIFO' 1 "$(said 'FIFO')"
check 'and nothing is installed' 0 "$(installed)"
rc=0; run_timed "$CUT" "$DEB" || rc=$?
check 'without the check the same package leaves the installer waiting' 124 "$rc"

DEB="$(special_deb link 'cp "$WORK/ring-good.gpg" real.gpg && ln -s real.gpg glyndor.gpg')"
rc=0; run_timed "$TEMPLATE" "$DEB" || rc=$?
check 'a keyring that is a symbolic link is refused' 1 "$rc"
check 'and the refusal says it is a link' 1 "$(said 'symbolic link')"
rc=0; run_timed "$CUT" "$DEB" || rc=$?
check 'without the check the same package is installed' 0 "$rc"

# A directory is neither a link nor a FIFO: it reaches the last refusal of the check,
# which names the path as "not a regular file".
DEB="$(special_deb dir 'mkdir glyndor.gpg')"
rc=0; run_timed "$TEMPLATE" "$DEB" || rc=$?
check 'a keyring that is a directory is refused' 1 "$rc"
check 'and the refusal says it is not a regular file' 1 "$(said 'is not a regular file')"
check 'and nothing is installed from it' 0 "$(installed)"

# The verified package is copied into a file the script makes, and made private. Each
# step has its own refusal; a stub that fails exactly that command reaches it.
FAILBIN="$WORK/failbin"; mkdir -p "$FAILBIN"
REAL_MKDIR="$(command -v mkdir)"; REAL_CHMOD="$(command -v chmod)"
printf '#!/bin/sh\nfor a in "$@"; do last=$a; done\ncase $last in */install) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_MKDIR" > "$FAILBIN/mkdir"
printf '#!/bin/sh\n[ "$1" = 600 ] && exit 1\nexec %s "$@"\n' "$REAL_CHMOD" > "$FAILBIN/chmod"
"$REAL_CHMOD" +x "$FAILBIN/mkdir" "$FAILBIN/chmod"
DEB="$(mkdeb copy good no)"
rc=0; run_timed "$TEMPLATE" "$DEB" "$FAILBIN" || rc=$?
check 'a package that cannot be copied to a private file is refused' 1 "$rc"
check 'and the refusal says it could not prepare the package' 1 "$(said 'could not prepare the verified package')"
check 'and nothing is installed after the failed copy' 0 "$(installed)"
rm -f "$FAILBIN/mkdir"
rc=0; run_timed "$TEMPLATE" "$DEB" "$FAILBIN" || rc=$?
check 'a private copy that cannot be made private is refused' 1 "$rc"
check 'and the refusal says it could not make it private' 1 "$(said 'could not make the verified package private')"
check 'and nothing is installed after the failed chmod' 0 "$(installed)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
