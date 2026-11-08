#!/usr/bin/env bash
# Guards of the installer that no other suite breaks: the refusal when it is
# not run as root, when dpkg, dpkg-deb or gpg cannot be had, when dpkg -i
# fails, the derived signature URL, the private copy it hands to dpkg, the
# flags on both downloads and the ceiling on the unpacked archive. Each case
# is paired with a copy of the template with that one guard removed, and the
# copy behaves differently: that difference is what shows the case tests the
# guard and not something next to it.
# shellcheck disable=SC2016 # the patterns and the stubs name variables on purpose
# shellcheck disable=SC1091 # shared fixture path is resolved at runtime
# shellcheck disable=SC2154 # the sourced fixture owns fingerprints and counters
. "$(cd "$(dirname "$0")/../../fixtures/installer" && pwd)/fixture.sh"

. "$(cd "$(dirname "$0")/../../fixtures/installer" && pwd)/sabotage.sh"

DEB="$(mkdeb ok good no)"
rc=0; run_installer "$DEB" "$FPR_GOOD" || rc=$?
check 'the baseline package is installed' 0 "$rc"

# --- root ---------------------------------------------------------------------
NOROOT="$WORK/bin-user"; mkdir -p "$NOROOT"
cp "$BIN"/* "$NOROOT/"; printf '#!/bin/sh\necho 1000\n' > "$NOROOT/id"
rc=0; INSTALLER_PATH="$NOROOT:$PATH" run_installer "$DEB" "$FPR_GOOD" || rc=$?
check 'run by a user that is not root it refuses' 1 "$rc"
check 'and says to run it as root' 1 "$(said 'run this as root')"
check 'and nothing is installed' 0 "$(installed)"
CUT="$(cut_template '[ "$run_uid" -eq 0 ] || fail' ': || fail' root)"
rc=0; INSTALLER_PATH="$NOROOT:$PATH" with_template "$CUT" "$DEB" "$FPR_GOOD" || rc=$?
check 'without the root guard the same run goes on' 0 "$rc"

# --- tools --------------------------------------------------------------------
for tool in dpkg dpkg-deb; do
	P="$(path_without "$tool")"
	rc=0; INSTALLER_PATH="$P" run_installer "$DEB" "$FPR_GOOD" || rc=$?
	check "without $tool it refuses" 1 "$rc"
	check "and says no $tool was found" 1 "$(said "no $tool found")"
	check "and nothing is installed (no $tool)" 0 "$(installed)"
	CUT="$(cut_template "command -v $tool >/dev/null 2>&1 || fail \"no $tool found\"" ':' "no-$tool")"
	rc=0; INSTALLER_PATH="$P" with_template "$CUT" "$DEB" "$FPR_GOOD" || rc=$?
	check "without the $tool guard the run does not stop at it" 0 "$(said "no $tool found")"
done

# gpg missing and apt-get unable to install it: stop, do not go on to dpkg -i.
P="$(path_without gpg)"
printf '#!/bin/sh\ncase "$*" in *gnupg*) exit 1 ;; esac\nexit 0\n' > "$WORK/bin/apt-get"
rc=0; INSTALLER_PATH="$P" run_installer "$DEB" "$FPR_GOOD" || rc=$?
check 'when gnupg cannot be installed it refuses' 1 "$rc"
check 'and says so' 1 "$(said 'could not install gnupg')"
check 'and dpkg -i is never reached' 0 "$(installed)"
CUT="$(cut_template 'apt-get install -y -qq gnupg </dev/null || fail "could not install gnupg"' 'apt-get install -y -qq gnupg </dev/null || true' gnupg)"
rc=0; INSTALLER_PATH="$P" with_template "$CUT" "$DEB" "$FPR_GOOD" || rc=$?
check 'without the guard the run goes on past the failed install' 0 "$(said 'could not install gnupg')"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/apt-get"

# --- dpkg -i fails ------------------------------------------------------------
FAILDPKG="$WORK/bin-dpkg-fails"; mkdir -p "$FAILDPKG"
cp "$BIN"/* "$FAILDPKG/"
printf '#!/bin/sh\ncase "$1" in -i) echo "$*" >> "$DPKG_MARKER"; exit 1 ;; esac\nexit 0\n' > "$FAILDPKG/dpkg"
rc=0; INSTALLER_PATH="$FAILDPKG:$PATH" run_installer "$DEB" "$FPR_GOOD" || rc=$?
check 'when dpkg -i fails the installer fails' 1 "$rc"
check 'and says the keyring package was not installed' 1 "$(said 'could not install the keyring package')"
check 'and does not report the keyring as installed' 0 "$(said 'Keyring installed')"
CUT="$(cut_template '|| fail "could not install the keyring package"' '|| true' dpkg-i)"
rc=0; INSTALLER_PATH="$FAILDPKG:$PATH" with_template "$CUT" "$DEB" "$FPR_GOOD" || rc=$?
check 'without the guard a failed dpkg -i is ignored' 0 "$rc"

# --- the signature URL is derived ---------------------------------------------
cp "$DEB.asc" "$WORK/genuine.asc"
GNUPGHOME="$WORK/gnupg-evil" gpg --batch --yes --quiet --pinentry-mode loopback --passphrase '' \
	--local-user evil --armor --detach-sign --output "$WORK/other.asc" "$DEB" >/dev/null 2>&1
run_with_sig_url() { # $1=template
	rm -f "$WORK/marker"
	sed 's/@PRODUCT@/testpkg/g' "$1" > "$WORK/install.sh"
	env -i PATH="$BIN:$PATH" HOME="$WORK" WORK="$WORK" DPKG_MARKER="$WORK/marker" \
		KEYRING_URL="file://$DEB" KEYRING_SIG_URL="file://$WORK/other.asc" GLYNDOR_APT_FPR="$FPR_GOOD" \
		/bin/sh "$WORK/install.sh" >"$WORK/out" 2>&1
}
rc=0; run_with_sig_url "$ORIG" || rc=$?
check 'a KEYRING_SIG_URL in the environment does not move the signature' 0 "$rc"
CUT="$(cut_template 'KEYRING_SIG_URL="$KEYRING_URL.asc"' 'KEYRING_SIG_URL="${KEYRING_SIG_URL:-$KEYRING_URL.asc}"' sigurl)"
rc=0; run_with_sig_url "$CUT" || rc=$?
check 'if it could be overridden the foreign signature would be used and refused' 1 "$rc"

# --- the copy handed to dpkg is private ---------------------------------------
MODES="$WORK/bin-modes"; mkdir -p "$MODES"
cp "$BIN"/* "$MODES/"
printf '#!/bin/sh\ncase "$1" in -i) echo "$*" >> "$DPKG_MARKER"; stat -c %%a "$2" > "$WORK/mode-file"; stat -c %%a "$(dirname "$2")" > "$WORK/mode-dir" ;; esac\nexit 0\n' > "$MODES/dpkg"
rc=0; INSTALLER_PATH="$MODES:$PATH" run_installer "$DEB" "$FPR_GOOD" || rc=$?
check 'the package dpkg is given is a private file' 600 "$(cat "$WORK/mode-file" 2>/dev/null)"
check 'in a private directory' 700 "$(cat "$WORK/mode-dir" 2>/dev/null)"
CUT="$(cut_template '( umask 077; set -C; mkdir' '( set -C; mkdir' umask)"
rm -f "$WORK/mode-file" "$WORK/mode-dir"
rc=0; INSTALLER_PATH="$MODES:$PATH" with_template "$CUT" "$DEB" "$FPR_GOOD" || rc=$?
check 'without the umask the directory is not private' 1 "$([ "$(cat "$WORK/mode-dir" 2>/dev/null)" = 700 ] && echo 0 || echo 1)"

# --- both downloads keep their flags ------------------------------------------
LOGBIN="$WORK/bin-curl"; mkdir -p "$LOGBIN"
cp "$BIN"/* "$LOGBIN/"
printf '#!/bin/sh\necho "$*" >> "$WORK/curl-args"\nexec %s "$@"\n' "$(command -v curl)" > "$LOGBIN/curl"
chmod +x "$LOGBIN/curl"
rm -f "$WORK/curl-args"
rc=0; INSTALLER_PATH="$LOGBIN:$PATH" run_installer "$DEB" "$FPR_GOOD" || rc=$?
for flag in '--proto-redir =https' '--connect-timeout 20' '--max-time 300'; do
	check "both downloads carry $flag" 2 "$(grep -cF -- "$flag" "$WORK/curl-args" || true)"
done
check 'the package download is capped at 8 MB' 1 "$(grep -c -- '--max-filesize 8388608' "$WORK/curl-args" || true)"
check 'the signature download is capped at 64 KB' 1 "$(grep -c -- '--max-filesize 65536' "$WORK/curl-args" || true)"

# --- the unpacked archive is read through a ceiling ---------------------------
# A producer that streams 100 MB and records how much it managed to write: with
# the ceiling the reader stops after 8 MB and the producer is cut by SIGPIPE.
BOMB="$WORK/bin-bomb"; mkdir -p "$BOMB"
cp "$BIN"/* "$BOMB/"
cat > "$BOMB/dpkg-deb" <<'STUB'
#!/usr/bin/env python3
import os, sys
if "--fsys-tarfile" not in sys.argv:
    os.execv("/usr/bin/dpkg-deb", ["dpkg-deb"] + sys.argv[1:])
written = 0
chunk = b"\0" * (1 << 20)
try:
    for _ in range(100):
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        written += 1
except BrokenPipeError:
    pass
open(os.environ["WORK"] + "/produced", "w").write(str(written))
STUB
chmod +x "$BOMB/dpkg-deb"
rm -f "$WORK/produced"
rc=0; INSTALLER_PATH="$BOMB:$PATH" run_installer "$DEB" "$FPR_GOOD" || rc=$?
check 'an archive that unpacks to 100 MB is refused' 1 "$rc"
check 'the reader stopped long before the producer finished' 1 "$([ "$(cat "$WORK/produced" 2>/dev/null || echo 100)" -le 12 ] && echo 1 || echo 0)"
CUT="$(cut_template '| head -c $((8 * 1024 * 1024 + 1)) > "$workdir/keyring.tar"' '> "$workdir/keyring.tar"' ceiling)"
rm -f "$WORK/produced"
rc=0; INSTALLER_PATH="$BOMB:$PATH" with_template "$CUT" "$DEB" "$FPR_GOOD" || rc=$?
check 'without the ceiling the producer writes all 100 MB' 100 "$(cat "$WORK/produced" 2>/dev/null)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
