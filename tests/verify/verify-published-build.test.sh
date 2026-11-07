#!/usr/bin/env bash
# Bind publication read-back to the local build, even when an old snapshot
# still has valid signatures and a consistent index/pool/bootstrap chain.
# file:// keeps real curl and GPG verification without a listening socket.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$HERE/scripts/verify/verify-published.sh"
FIXTURES="$HERE/tests/fixtures/verify/published-build"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# Verification only needs public keys. Keep the real GPG commands, but do not
# require an agent socket merely to import them in a restricted environment.
mkdir -p "$WORK/bin"
REAL_GPG="$(command -v gpg)"
export REAL_GPG
cat > "$WORK/bin/gpg" <<'SH'
#!/usr/bin/env bash
exec "$REAL_GPG" --no-autostart "$@"
SH
chmod +x "$WORK/bin/gpg"
export PATH="$WORK/bin:$PATH"

check() { # <exit> <output-fragment> <description> -- <command...>
	local want="$1" needle="$2" desc="$3" got=0 out
	shift 4
	out="$("$@" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && grep -qF "$needle" <<< "$out"; then
		echo "ok   - $desc (exit $got)"; pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want containing '$needle', got exit $got)"
		printf '%s\n' "$out"
		fail=$((fail + 1))
	fi
}

# These complete, pre-signed snapshots use one public test key. No private
# key or signing agent is needed at test time; gpg/gpgv remain the verifiers.
snapshot() { # <old|new> <version>
	local target="$WORK/$1"
	mkdir -p "$target/dists/stable/main/binary-amd64" "$target/pool"
	cp "$FIXTURES/$1/"{InRelease,Release,Release.gpg} "$target/dists/stable/"
	cp "$FIXTURES/$1/Packages" "$target/dists/stable/main/binary-amd64/Packages"
	cp "$FIXTURES/$1/podup.deb.txt" "$target/pool/podup_${2}_amd64.deb"
	cp "$FIXTURES/bootstrap.deb.txt" "$target/pool/keyring_1.0.0_all.deb"
	cp "$FIXTURES/bootstrap.deb.txt" "$target/glyndor-archive-keyring.deb"
	cp "$FIXTURES/bootstrap.deb.asc" "$target/glyndor-archive-keyring.deb.asc"
}
snapshot old 1.0.0
snapshot new 2.0.0
KEY="$FIXTURES/archive-key.asc"
NEW_HASH="$(sha256sum "$WORK/new/dists/stable/InRelease" | cut -d' ' -f1)"
OLD_HASH="$(sha256sum "$WORK/old/dists/stable/InRelease" | cut -d' ' -f1)"
if [ "$NEW_HASH" = "$OLD_HASH" ]; then
	echo 'FAIL - replay fixture must differ from the local build'; exit 1
fi
SUCCESS='bootstrap keyring package and its signature are served as signed'
MISMATCH='InRelease does not match the published build'

check 0 "$SUCCESS" 'old snapshot is valid against its own digest' -- \
	"$VERIFY" "file://$WORK/old" "$KEY" 1 0 600 "$OLD_HASH"
check 0 "$SUCCESS" 'new snapshot is valid against its own digest (positive control)' -- \
	"$VERIFY" "file://$WORK/new" "$KEY" 1 0 600 "$NEW_HASH"
check 1 "$MISMATCH" 'old signed snapshot is refused for the newly published build' -- \
	"$VERIFY" "file://$WORK/old" "$KEY" 1 0 600 "$NEW_HASH"
check 0 "$SUCCESS" 'unbound health mode still accepts a consistent snapshot' -- \
	"$VERIFY" "file://$WORK/old" "$KEY" 1 0 600
check 1 'expected InRelease SHA256 must be' 'explicit empty digest cannot disable publication binding' -- \
	"$VERIFY" "file://$WORK/new" "$KEY" 1 0 600 ''
check 1 'expected InRelease SHA256 must be' 'malformed expected digest is refused as such' -- \
	"$VERIFY" "file://$WORK/new" "$KEY" 1 0 600 'not-a-digest'

# A matching digest must not replace signature verification.
cp -a "$WORK/new" "$WORK/unsigned"
cp "$WORK/unsigned/dists/stable/Release" "$WORK/unsigned/dists/stable/InRelease"
UNSIGNED_HASH="$(sha256sum "$WORK/unsigned/dists/stable/InRelease" | cut -d' ' -f1)"
check 1 'signature verification failed' 'matching digest still requires a signed index' -- \
	"$VERIFY" "file://$WORK/unsigned" "$KEY" 1 0 600 "$UNSIGNED_HASH"

# Complete purge convergence deterministically at the retry boundary.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/sleep" <<'SH'
#!/usr/bin/env bash
if [ -n "${CONVERGE_FROM:-}" ]; then
	cp -a "$CONVERGE_FROM/." "$CONVERGE_TO/"
fi
SH
chmod +x "$WORK/bin/sleep"
cp -a "$WORK/old" "$WORK/edge"
check 0 "$SUCCESS" 'old edge snapshot converges to the expected build on retry' -- \
	env PATH="$WORK/bin:$PATH" CONVERGE_FROM="$WORK/new" CONVERGE_TO="$WORK/edge" \
	"$VERIFY" "file://$WORK/edge" "$KEY" 2 0 600 "$NEW_HASH"

# Execute the workflow's actual read-back body with local public/ = new and
# the served snapshot varied independently. Removing the argument at the
# caller must be observable, not just removing the check inside the script.
python3 - "$HERE/.github/workflows/publish.yml" > "$WORK/read-back.sh" <<'PY'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
for step in workflow['jobs']['publish']['steps']:
	if './scripts/verify/verify-published.sh' in step.get('run', ''):
		print(step['run'])
		break
else:
	raise SystemExit('read-back step not found')
PY
mkdir -p "$WORK/caller/scripts/verify" "$WORK/caller/keyring"
ln -s "$VERIFY" "$WORK/caller/scripts/verify/verify-published.sh"
cp "$KEY" "$WORK/caller/keyring/glyndor-apt-key.asc"
cp -a "$WORK/new" "$WORK/caller/public"
workflow_readback() {
	(cd "$WORK/caller" && ARCHIVE_URL="file://$WORK/$1" PATH="$WORK/bin:$PATH" \
		bash -euo pipefail "$WORK/read-back.sh")
}
check 0 "$SUCCESS" 'publish read-back accepts the local build served back' -- workflow_readback new
check 1 "$MISMATCH" 'publish read-back rejects an older complete signed snapshot' -- workflow_readback old

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
