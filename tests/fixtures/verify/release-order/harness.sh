#!/usr/bin/env bash
# Sourced by check-release-order.test.sh. No signing agent is needed.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
VERIFY="$HERE/scripts/verify/check-release-order.sh"
FIXTURES="$HERE/tests/fixtures/verify/published-build"
EXTRA="$HERE/tests/fixtures/verify/release-order"
WORK="$(mktemp -d)"
SITE="$WORK/site"
DIST="$SITE/dists/stable"
SERVER_PID=""
cleanup() {
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$DIST" "$WORK/bin"
# As in verify-published-build: public imports need no signing-agent socket.
REAL_GPG="$(command -v gpg)"
export REAL_GPG
cat > "$WORK/bin/gpg" <<'SH'
#!/usr/bin/env bash
exec "$REAL_GPG" --no-autostart "$@"
SH
chmod 755 "$WORK/bin/gpg"
export PATH="$WORK/bin:$PATH"

snapshot() { # old/new use the existing signed snapshots; others the extra key.
	local name="$1" arch
	rm -rf "$DIST"
	mkdir -p "$DIST/main/binary-amd64"
	KEY="$FIXTURES/archive-key.asc"
	if [ "$name" = old ] || [ "$name" = new ]; then
		cp "$FIXTURES/$name/InRelease" "$DIST/InRelease"
		cp "$FIXTURES/$name/Packages" "$DIST/main/binary-amd64/Packages"
	else
		KEY="$EXTRA/archive-key.asc"
		[ -f "$EXTRA/$name/archive-key.asc" ] && KEY="$EXTRA/$name/archive-key.asc"
		if [ -f "$EXTRA/$name/InRelease.gz" ]; then
			python3 -I - "$EXTRA/$name/InRelease.gz" "$DIST/InRelease" <<'PY'
import gzip
import pathlib
import sys
pathlib.Path(sys.argv[2]).write_bytes(gzip.decompress(pathlib.Path(sys.argv[1]).read_bytes()))
PY
		else
			cp "$EXTRA/$name/InRelease" "$DIST/InRelease"
		fi
		for arch in amd64 arm64; do
			if [ -f "$EXTRA/$name/Packages-$arch" ]; then
				mkdir -p "$DIST/main/binary-$arch"
				cp "$EXTRA/$name/Packages-$arch" "$DIST/main/binary-$arch/Packages"
			fi
		done
	fi
}

snapshot new
# Local server/readiness pattern from verify-published-fixture.sh. Binding port
# zero in the server avoids the reserve-close-rebind race of a separate probe.
if [ "${RELEASE_ORDER_TEST_TRANSPORT:-http}" = file ]; then
	BASE="file://$SITE"
	echo 'SIN VERIFICAR: HTTP local (explicit file:// transport selected)'
else
	python3 -I - "$SITE" "$WORK/port" >"$WORK/server.log" 2>&1 <<'PY' &
import functools
import http.server
import pathlib
import sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
    pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
    server.serve_forever()
PY
	SERVER_PID=$!
	for _ in $(seq 1 50); do
		[ -s "$WORK/port" ] && break
		kill -0 "$SERVER_PID" 2>/dev/null || break
		sleep 0.1
	done
	if [ ! -s "$WORK/port" ]; then
		echo 'FAIL: SIN VERIFICAR HTTP server could not start'
		cat "$WORK/server.log"
		printf 'DONE %s 0 1\n' "${0##*/}"
		exit 1
	fi
	BASE="http://127.0.0.1:$(cat "$WORK/port")"
	curl -fsS --max-time 2 "$BASE/dists/stable/InRelease" -o /dev/null
fi

# The candidate .deb the publish workflow has downloaded by now. Its Debian
# version is CAND when a case sets it; otherwise it carries a high epoch, so
# the Debian comparison never decides a case that is about the SemVer one.
# CAND=NONE leaves the directory empty, as a download that found nothing would.
candidates() {
	local dir="$WORK/debs/$PRODUCT" version="${CAND-99:${TAG#v}}" root="$WORK/deb-root"
	rm -rf "$WORK/debs" "$root"
	mkdir -p "$dir" "$root/DEBIAN"
	[ "$version" = NONE ] && return 0
	printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: t <t@example.invalid>\nDescription: fixture\n' \
		"${CAND_PACKAGE:-$PRODUCT}" "$version" > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$root" "$dir/c.deb" >/dev/null
}
run() { candidates; bash "$ACTIVE" "$PRODUCT" "$TAG" "$BASE" "$KEY" "$WORK/debs/$PRODUCT"; }
check() { # expected status, distinguishing output, label
	local want="$1" needle="$2" label="$3" got=0 out
	out="$(run 2>&1)" || got=$?
	LAST_STATUS="$got"
	if [ "$got" -eq "$want" ] && grep -qF "$needle" <<< "$out"; then
		echo "ok   - $label (exit $got)"
		pass=$((pass + 1))
		return 0
	fi
	echo "FAIL - $label (want $want / $needle; got $got)"
	printf '%s\n' "$out"
	fail=$((fail + 1))
	return 1
}

case_with_control() { # label status output mutation
	local label="$1" want="$2" needle="$3" mutation="$4" saved_pass saved_fail
	ACTIVE="$VERIFY"
	if ! check "$want" "$needle" "$label"; then
		echo "SIN VERIFICAR: CONTROL $label (baseline failed)"
		return
	fi
	ACTIVE="$WORK/mutant.sh"
	python3 -I "$EXTRA/mutate.py" "$VERIFY" "$ACTIVE" "$mutation"
	echo "CONTROL $label: $mutation (diff follows)"
	local diff_status=0
	diff -u "$VERIFY" "$ACTIVE" || diff_status=$?
	if [ "$diff_status" -ne 1 ]; then
		echo 'FAIL - SABOTAGE INERT or diff error'; fail=$((fail + 1)); return
	fi
	saved_pass="$pass"; saved_fail="$fail"
	if check "$want" "$needle" "CONTROL expected failure: $label"; then
		pass="$saved_pass"; fail=$((saved_fail + 1))
		echo "FAIL - CONTROL survived: $label"
	else
		if [ "$want" -eq 1 ] && [ "$mutation" != size ] && [ "$mutation" != description ] && [ "$mutation" != index-cap ] && [ "$LAST_STATUS" -ne 0 ]; then
			pass="$saved_pass"; fail=$((saved_fail + 1))
			echo "FAIL - CONTROL rejected for another reason: $label"
		else
			pass=$((saved_pass + 1)); fail="$saved_fail"
			echo "ok   - CONTROL detected: $label"
		fi
	fi
}
