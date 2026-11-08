#!/usr/bin/env bash
# Files the installer made or downloaded can be swapped for a FIFO or a link
# while it runs, as root. Each swap here happens at the exact moment between
# two steps, done by a wrapper around the command that ends the earlier one,
# and each case runs under a deadline so a hang is a failed case. The control
# is a copy of the template with that check removed: there the FIFO times out
# and the link goes through, which shows the refusal comes from that check.
# The last case is the second signature check over the installed copy, which
# is all that is left when sha256sum is not on the machine.
# shellcheck disable=SC2016 # the patterns and the wrappers name variables on purpose
# shellcheck disable=SC1091 # shared fixture path is resolved at runtime
# shellcheck disable=SC2154 # the sourced fixture owns fingerprints and counters
. "$(cd "$(dirname "$0")/../../fixtures/installer" && pwd)/fixture.sh"
. "$(cd "$(dirname "$0")/../../fixtures/installer" && pwd)/sabotage.sh"

SWAP="$WORK/bin-swap"; mkdir -p "$SWAP"
cp "$BIN"/* "$SWAP/"
REAL_CURL="$(command -v curl)"; REAL_GPG="$(command -v gpg)"; REAL_CHMOD="$(command -v chmod)"
swap_file() { # $1=path  reads the kind from $WORK/swap-kind
	case "$(cat "$WORK/swap-kind")" in
		fifo) rm -f "$1"; mkfifo "$1" ;;
		link) mv "$1" "$1.real"; ln -s "$1.real" "$1" ;;
	esac
}
# After a download, swap the file that was just written.
cat > "$SWAP/curl" <<STUB
#!/bin/sh
$REAL_CURL "\$@"; rc=\$?
out=; prev=; for a in "\$@"; do [ "\$prev" = -o ] && out=\$a; prev=\$a; done
read -r want kind < "\$WORK/swap" 2>/dev/null || exit \$rc
case "\$out:\$want" in
	*.deb:deb|*.asc:asc) echo "\$kind" > "\$WORK/swap-kind"; . "\$WORK/swap-fn"; swap_file "\$out" ;;
esac
exit \$rc
STUB
declare -f swap_file > "$WORK/swap-fn"
# After the copy is made private, swap the copy.
cat > "$SWAP/chmod" <<STUB
#!/bin/sh
$REAL_CHMOD "\$@"; rc=\$?
read -r want kind < "\$WORK/swap" 2>/dev/null || exit \$rc
case "\$want:\$2" in
	copy:*/install/glyndor-archive-keyring.deb) echo "\$kind" > "\$WORK/swap-kind"; . "\$WORK/swap-fn"; swap_file "\$2" ;;
esac
exit \$rc
STUB
# After the first signature check, change the package that was checked, so the
# copy that is made next differs from what was signed.
cat > "$SWAP/gpg" <<STUB
#!/bin/sh
$REAL_GPG "\$@"; rc=\$?
case "\$*" in
	*--verify*)
		echo v >> "\$WORK/verifies"
		if [ "\$(wc -l < "\$WORK/verifies")" -eq 1 ] && [ -f "\$WORK/append" ]; then
			for last in "\$@"; do :; done; printf x >> "\$last"
		fi ;;
esac
exit \$rc
STUB
chmod +x "$SWAP/curl" "$SWAP/chmod" "$SWAP/gpg"

run_timed() { # $1=template $2=deb $3=PATH  (the swap to do is in $WORK/swap)
	rm -f "$WORK/marker" "$WORK/verifies"
	sed 's/@PRODUCT@/testpkg/g' "$1" > "$WORK/install.sh"
	timeout 20 env -i PATH="$3" HOME="$WORK" WORK="$WORK" DPKG_MARKER="$WORK/marker" \
		KEYRING_URL="file://$2" GLYNDOR_APT_FPR="$FPR_GOOD" \
		/bin/sh "$WORK/install.sh" >"$WORK/out" 2>&1
}

DEB="$(mkdeb ok good no)"
echo none > "$WORK/swap"
rc=0; run_timed "$ORIG" "$DEB" "$SWAP:$PATH" || rc=$?
check 'with the wrappers and no swap the package is installed' 0 "$rc"

# $1=what is swapped (deb|asc|copy)  $2=text of the check  $3=name of the control
swap_cases() {
	local what="$1" guard="$2" name="$3" CUT
	CUT="$(cut_template "$guard" ':' "$name")"
	echo "$what fifo" > "$WORK/swap"
	rc=0; run_timed "$ORIG" "$DEB" "$SWAP:$PATH" || rc=$?
	check "the $what swapped for a FIFO is refused, not waited on" 1 "$rc"
	check "and the refusal says it is a FIFO ($what)" 1 "$(said 'FIFO')"
	check "and nothing is installed ($what, FIFO)" 0 "$(installed)"
	rc=0; run_timed "$CUT" "$DEB" "$SWAP:$PATH" || rc=$?
	check "without the check on the $what a FIFO leaves the installer waiting" 124 "$rc"
	echo "$what link" > "$WORK/swap"
	rc=0; run_timed "$ORIG" "$DEB" "$SWAP:$PATH" || rc=$?
	check "the $what swapped for a symbolic link is refused" 1 "$rc"
	check "and the refusal says it is a link ($what)" 1 "$(said 'symbolic link')"
	rc=0; run_timed "$CUT" "$DEB" "$SWAP:$PATH" || rc=$?
	check "without the check on the $what the link is accepted" 0 "$rc"
}
swap_cases deb 'require_regular_file "$verified_deb" "the downloaded package"' verified
swap_cases asc 'require_regular_file "$workdir/glyndor-archive-keyring.deb.asc" "the detached signature"' asc

# The copy made for dpkg: only a link case, a FIFO there would be read by cat
# before the swap could happen.
CUT="$(cut_template 'require_regular_file "$install_deb" "the package to install"' ':' copy)"
echo 'copy link' > "$WORK/swap"
rc=0; run_timed "$ORIG" "$DEB" "$SWAP:$PATH" || rc=$?
check 'the copy swapped for a link before the second check is refused' 1 "$rc"
check 'and the refusal says it is a link (copy)' 1 "$(said 'symbolic link')"
rc=0; run_timed "$CUT" "$DEB" "$SWAP:$PATH" || rc=$?
check 'without the check on the copy the link is accepted' 0 "$rc"

# --- the second signature check -----------------------------------------------
# No sha256sum, so the digest comparison does not exist and only the signature
# over the copy can tell that the package changed after it was verified.
P="$(path_without sha256sum)"
for f in curl chmod gpg; do ln -sf "$SWAP/$f" "$P/$f"; done
echo none > "$WORK/swap"; : > "$WORK/append"
rc=0; run_timed "$ORIG" "$DEB" "$P" || rc=$?
check 'a package changed after it was verified is refused without sha256sum' 1 "$rc"
check 'and the refusal says it is not the verified one' 1 "$(said 'is not the one that was verified')"
check 'and nothing is installed (changed after verification)' 0 "$(installed)"
CUT="$(cut_template '	|| fail "the package to install is not the one that was verified; nothing was installed"' '	|| true' second)"
rc=0; run_timed "$CUT" "$DEB" "$P" || rc=$?
check 'without the second signature check the changed package is installed' 0 "$rc"
rm -f "$WORK/append"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
