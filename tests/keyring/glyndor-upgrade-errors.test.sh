#!/usr/bin/env bash
# Run the shipped timer script through each dependency and runtime failure.
# All other inputs describe a pending podup upgrade, so an earlier empty-plan
# return cannot satisfy a failure assertion. Never invoke the host's apt.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1 (expected: $2; actual: $3)"
		cat "$WORK/out" 2>/dev/null || true
		fail=$((fail + 1))
	fi
}

mkdir -p "$WORK/bin" "$WORK/run"
printf 'Package: podup\nVersion: 2\n' > "$WORK/Packages"
cat > "$WORK/bin/apt-get" <<'STUB'
#!/bin/sh
case "$1" in
	update)
		[ ! -f "$WORK/update-fails" ] || { echo 'E: update fixture failed' >&2; exit 100; } ;;
	indextargets) echo "$WORK/Packages" ;;
	-s) echo 'Inst podup [1] (2 stable)' ;;
	*) exit 2 ;;
esac
STUB
cat > "$WORK/bin/apt-helper" <<'STUB'
#!/bin/sh
[ "$1" = cat-file ] || exit 2
cat "$2"
STUB
cat > "$WORK/bin/dpkg-query" <<'STUB'
#!/bin/sh
printf 'ii  podup\n'
STUB
cat > "$WORK/bin/unattended-upgrade" <<'STUB'
#!/bin/sh
cp "$APT_CONFIG" "$WORK/seen.conf"
if [ -f "$WORK/engine-fails" ]; then
	echo 'unattended-upgrade: error processing upgrade' >&2
	exit 42
fi
STUB
chmod +x "$WORK/bin/"*

run_upgrade() { # optional apt-helper, engine and RUN overrides
	rm -f "$WORK/seen.conf"
	env WORK="$WORK" PATH="$WORK/bin:$PATH" \
		GLYNDOR_APT_HELPER="${1:-$WORK/bin/apt-helper}" \
		GLYNDOR_UNATTENDED="${2:-$WORK/bin/unattended-upgrade}" \
		GLYNDOR_RUN_DIR="${3:-$WORK/run}" \
		sh "$HERE/keyring/upgrade/glyndor-upgrade" > "$WORK/out" 2>&1
}
ran() { [ -f "$WORK/seen.conf" ] && echo 1 || echo 0; }
says() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }

run_upgrade; rc=$?
check "the healthy pending upgrade succeeds" "0" "$rc"
check "the healthy path reaches the engine" "1" "$(ran)"
check "the engine receives the pending package" "1" "$(grep -cF '"^podup$";' "$WORK/seen.conf")"

touch "$WORK/engine-fails"
run_upgrade; rc=$?
check "an engine failure propagates its nonzero exit code" "42" "$rc"
check "the failing engine was reached" "1" "$(ran)"
check "the engine's error reaches the journal" "1" "$(says 'unattended-upgrade: error processing upgrade')"
check "an engine failure still removes its private config" "0" "$(find "$WORK/run" -name 'apt.conf*' | wc -l)"
rm "$WORK/engine-fails"

run_upgrade "$WORK/bin/apt-helper" "$WORK/missing-engine"; rc=$?
check "an absent engine exits 127" "127" "$rc"
check "the absent engine is named in the journal" "1" "$(says "$WORK/missing-engine")"
check "an absent engine still removes its private config" "0" "$(find "$WORK/run" -name 'apt.conf*' | wc -l)"

run_upgrade "$WORK/missing-helper"; rc=$?
check "an absent apt-helper exits 1" "1" "$rc"
check "an absent apt-helper reports the unreadable index" "1" "$(says "cannot read the Glyndor index $WORK/Packages")"
check "an absent apt-helper prevents the engine from running" "0" "$(ran)"

touch "$WORK/update-fails"
run_upgrade; rc=$?
check "a failed apt-get update exits 100" "100" "$rc"
check "the update error reaches the journal" "1" "$(says 'E: update fixture failed')"
check "a failed update prevents the engine from running" "0" "$(ran)"
rm "$WORK/update-fails"

# A regular file as the parent is uncreatable even with root's DAC override.
# chmod 000 would make this case dependent on the runner's privileges.
: > "$WORK/not-a-directory"
run_upgrade "$WORK/bin/apt-helper" "$WORK/bin/unattended-upgrade" "$WORK/not-a-directory/run"; rc=$?
check "an uncreatable RUN directory exits 1" "1" "$rc"
check "the directory creation error reaches the journal" "1" "$(says 'mkdir:')"
check "an uncreatable RUN directory prevents the engine from running" "0" "$(ran)"

run_upgrade; rc=$?
check "after restoring dependencies the same pending upgrade succeeds" "0" "$rc"
check "the restored path reaches the engine" "1" "$(ran)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
