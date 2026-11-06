#!/usr/bin/env bash
# Execute generated installers through a pipe. Crypto is stubbed here: these
# cases test delivery atomicity, not signatures (covered by behaviour.test.sh).
set -uo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() {
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail + 1))
	fi
}

"$HERE/scripts/build/build-installers.sh" "$WORK/install" testpkg >/dev/null || exit 1
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/pkg/DEBIAN" "$WORK/pkg/usr/share/keyrings"
printf 'Package: glyndor-archive-keyring\nVersion: 1\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: delivery fixture\n' > "$WORK/pkg/DEBIAN/control"
echo fixture-key > "$WORK/pkg/usr/share/keyrings/glyndor.gpg"
dpkg-deb --root-owner-group --build "$WORK/pkg" "$WORK/keyring.deb" >/dev/null || exit 1
echo fixture-signature > "$WORK/keyring.deb.asc"
for cmd in id apt-get dpkg gpg testpkg unattended-upgrade; do
	cat > "$WORK/bin/$cmd" <<'SH'
#!/bin/sh
name=${0##*/}
echo "$name $*" >> "$WORK/state/commands"
case "$name" in
	id) echo 0 ;;
	gpg)
		case "$*" in
			*--show-keys*) printf 'pub:::::::::\nfpr:::::::::9ADF04EA8C3139CDB67303CFA6705C2EA153F3D6:\n' ;;
		esac ;;
	dpkg) cp "$WORK/pkg/usr/share/keyrings/glyndor.gpg" "$WORK/state/keyring" ;;
	testpkg) echo 'testpkg version 1' ;;
esac
exit 0
SH
	chmod +x "$WORK/bin/$cmd"
done

# The producer writes a real prefix to sh's pipe, then reports an interrupted
# transfer (18, curl's partial-file status). No sleeps or network are needed.
run_delivery() { # byte count, producer exit status
	rm -f "$WORK/state/commands" "$WORK/state/keyring"
	python3 - "$WORK/install/testpkg" "$1" "$2" <<'PY' |
import sys
data = open(sys.argv[1], 'rb').read()
sys.stdout.buffer.write(data[:int(sys.argv[2])])
sys.stdout.buffer.flush()
sys.exit(int(sys.argv[3]))
PY
		env -i PATH="$WORK/bin:$PATH" HOME="$WORK" WORK="$WORK" \
		KEYRING_URL="file://$WORK/keyring.deb" /bin/sh -x > "$WORK/out" 2>&1
	statuses=("${PIPESTATUS[@]}")
}

size="$(wc -c < "$WORK/install/testpkg")"
run_delivery "$size" 0
[ "${statuses[*]}" = '0 0' ] || cat "$WORK/out"
check 'the complete delivery has a successful producer and shell' '0 0' "${statuses[*]}"
check 'the complete delivery installs the sandbox keyring' 1 "$([ -f "$WORK/state/keyring" ] && echo 1 || echo 0)"
check 'the complete delivery reaches the product install' 1 "$(grep -q 'apt-get install -y testpkg' "$WORK/state/commands" && echo 1 || echo 0)"

# A cut after all installation statements but before the final closing message
# used to leave the keyring installed. It must now execute no commands at all.
cut_at="$(python3 - "$WORK/install/testpkg" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
print(data.index(b'closing "testpkg $version"'))
PY
)"
for cut in 10 "$cut_at" "$((size - 12))"; do
	run_delivery "$cut" 18
	check "cut at byte $cut preserves the producer failure" 18 "${statuses[0]}"
	check "cut at byte $cut executes no shell statements" 0 "$(grep -c '^+' "$WORK/out" || true)"
	check "cut at byte $cut executes no external commands" 0 "$([ -s "$WORK/state/commands" ] && echo 1 || echo 0)"
	check "cut at byte $cut leaves no installed keyring" 0 "$([ -f "$WORK/state/keyring" ] && echo 1 || echo 0)"
done

# A syntactically complete definition without its final invocation is a valid
# shell script; sh -n cannot tell whether the install was delivered in full.
last_line="$(tail -n 1 "$WORK/install/testpkg")"
cut="$((size - ${#last_line} - 1))"
run_delivery "$cut" 18
check 'the final-line cut preserves the producer failure' 18 "${statuses[0]}"
check 'without the final invocation no shell statement runs' 0 "$(grep -c '^+' "$WORK/out" || true)"
check 'without the final invocation no command runs' 0 "$([ -s "$WORK/state/commands" ] && echo 1 || echo 0)"
check 'without the final invocation no keyring remains' 0 "$([ -f "$WORK/state/keyring" ] && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
