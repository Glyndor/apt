#!/usr/bin/env bash
# Real deb/tar/gpg, with only the shared fixture's privileged actions stubbed.
# Hostile members always target this fixture's private temporary directories.
# A sparse file is bounded to 16 MiB so the regression is safe to reproduce.
# shellcheck disable=SC1091 # fixture path is resolved at runtime
# shellcheck disable=SC2154 # the fixture supplies keys, paths and counters
. "$(cd "$(dirname "$0")/../../fixtures/installer" && pwd)/fixture.sh"

if [ "${#FPR_GOOD}" -ne 40 ] || [ "${#FPR_NEW}" -ne 40 ]; then
	echo 'FAIL  fixture: real gpg could not generate the test keys (check gpg-agent)'
	printf 'DONE %s 0 1\n' "${BASH_SOURCE[0]##*/}"
	exit 1
fi

for tool in python3 ar tar timeout; do
	command -v "$tool" >/dev/null || exit 1
done

# Observe the real extraction before the installer's EXIT trap removes it.
# No arguments or return codes are changed by this wrapper.
REAL_TAR="$(command -v tar)"
cat > "$BIN/tar" <<'WRAPPER'
#!/bin/sh
dest=
previous=
for arg do
	[ "$previous" != -C ] || dest="$arg"
	previous="$arg"
done
@REAL_TAR@ "$@"
rc=$?
if [ -n "$dest" ]; then
	printf '%s\n' "$rc" > "$WORK/tar-status"
	if [ -e "$dest/../escaped" ]; then
		: > "$WORK/escaped"
	fi
	if [ -f "$dest/sparse" ]; then
		stat -c %s "$dest/sparse" > "$WORK/sparse-size"
	fi
fi
exit "$rc"
WRAPPER
sed -i "s|@REAL_TAR@|$REAL_TAR|" "$BIN/tar"
chmod +x "$BIN/tar"

mkdir -p "$WORK/outside" "$WORK/control"
printf 'unchanged\n' > "$WORK/outside/sentinel"
export_ring good "$WORK/good.gpg"
printf 'Package: glyndor-archive-keyring\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' \
	> "$WORK/control/control"
printf '2.0\n' > "$WORK/debian-binary"
"$REAL_TAR" -czf "$WORK/control.tar.gz" -C "$WORK/control" .

hostile_deb() { # $1=attack; prints the resulting deb path
	local attack="$1"
	python3 -I - "$WORK" "$attack" <<'PY'
import io
import os
import sys
import tarfile

root, attack = sys.argv[1:]
with tarfile.open(root + "/data.tar", "w", format=tarfile.GNU_FORMAT) as archive:
    archive.add(root + "/good.gpg", arcname="usr/share/keyrings/glyndor.gpg")
    member = tarfile.TarInfo()
    member.mode = 0o644
    payload = b"escaped\n"
    if attack == "absolute":
        member.name = root + "/outside/absolute"
    elif attack == "traversal":
        member.name = "../escaped"
    elif attack == "intermediate-link":
        member.name = "pivot"
        member.type = tarfile.SYMTYPE
        member.linkname = root + "/outside"
        archive.addfile(member)
        member = tarfile.TarInfo("pivot/escaped")
    elif attack == "hardlink":
        member.name = "hard"
        member.type = tarfile.LNKTYPE
        member.linkname = root + "/outside/sentinel"
        archive.addfile(member)
    elif attack == "sparse":
        # GNU's old sparse header: small archive, 16 MiB logical output.
        member.name = "sparse"
        member.type = tarfile.GNUTYPE_SPARSE
        member.size = 1
        header = bytearray(member.tobuf(format=tarfile.GNU_FORMAT))
        header[386:398] = tarfile.itn(16 * 1024 * 1024 - 1, 12)
        header[398:410] = tarfile.itn(1, 12)
        header[483:495] = tarfile.itn(16 * 1024 * 1024, 12)
        header[148:156] = b"        "
        header[148:156] = bytes("%06o\0 " % sum(header), "ascii")
        archive.fileobj.write(header + b"\0" * 512)
        archive.offset += 1024
    if attack not in ("hardlink", "sparse"):
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
assert os.path.getsize(root + "/data.tar") < 8 * 1024 * 1024
PY
	( cd "$WORK" && ar rc "$attack.deb" debian-binary control.tar.gz data.tar )
	sign_deb good "$WORK/$attack.deb"
	printf '%s\n' "$WORK/$attack.deb"
}

run_attack() { # $1=deb; same PATH sandbox, with a deadline for hostile input
	rm -f "$WORK/marker"
	sed 's/@PRODUCT@/testpkg/g' "$TEMPLATE" > "$WORK/install.sh"
	env -i PATH="$BIN:$PATH" HOME="$WORK" WORK="$WORK" DPKG_MARKER="$WORK/marker" \
		KEYRING_URL="file://$1" GLYNDOR_APT_FPR="$FPR_GOOD" \
		timeout 20 /bin/sh "$WORK/install.sh" > "$WORK/out" 2>&1
}

# Positive control: a blanket refusal or a broken fixture must fail this suite.
DEB="$(mkdeb control good no)"
rc=0; run_installer "$DEB" "$FPR_GOOD" || rc=$?
check 'control: a genuine keyring package succeeds' 0 "$rc"
check 'control: dpkg -i is reached' 1 "$(installed)"

for attack in absolute traversal intermediate-link hardlink sparse; do
	DEB="$(hostile_deb "$attack")"
	rm -f "$WORK/escaped" "$WORK/tar-status" "$WORK/sparse-size"
	rc=0; run_attack "$DEB" || rc=$?
	# The sparse package is refused by the listing, before tar extracts anything.
	[ "$attack" = sparse ] || check "$attack: extraction was exercised" 1 "$([ -f "$WORK/tar-status" ] && echo 1 || echo 0)"
	if [ "$attack" = absolute ]; then
		# tar strips the leading slash, so the member lands inside the extraction
		# directory and the otherwise genuine package installs; what must hold is
		# containment, checked below.
		check "absolute: the member is contained, not written at its absolute path" 0 "$([ -e "$WORK/outside/absolute" ] && echo 1 || echo 0)"
	else
		check "$attack: the installer refuses the package" 1 "$rc"
		check "$attack: dpkg -i is never reached" 0 "$(installed)"
	fi
	check "$attack: no traversal write outside extraction" 0 "$([ -e "$WORK/escaped" ] && echo 1 || echo 0)"
	check "$attack: the outside directory has no new members" sentinel "$(ls -A "$WORK/outside")"
	check "$attack: the outside sentinel is unchanged" unchanged "$(cat "$WORK/outside/sentinel")"
	if [ "$attack" = sparse ]; then
		check 'sparse: extraction does not create a file beyond the 8 MiB ceiling' 1 \
			"$([ "$(cat "$WORK/sparse-size" 2>/dev/null || echo 0)" -le $((8 * 1024 * 1024)) ] && echo 1 || echo 0)"
		printf 'NOTE  sparse logical bytes extracted: %s\n' "$(cat "$WORK/sparse-size" 2>/dev/null || echo 0)"
	fi
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
