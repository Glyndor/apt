#!/usr/bin/env bash
#
# The step of publish.yml that admits the product .deb files: it has to run
# scripts/verify/verify-debs.sh, and a signature that does not verify has to
# stop the publish (issue #368).
#
# tests/verify/verify-debs.test.sh runs the verifier directly, and the shape
# suite checks the names and the order of the steps. Neither notices a call
# replaced by `true`: the step keeps its name, the verifier keeps passing its
# own suite, and a release with a forged signature is admitted. This suite
# extracts the step as shipped and runs it in a sandbox with the real verifier
# and a signed .deb, then with an invalid signature. Then the same two cases
# run against a copy of the workflow with the call replaced by `true`, and the
# invalid signature has to pass there, so the refusal is shown to come from
# the call and not from something else.
#
# Requires: python3 with the `cryptography` module, dpkg-deb.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WF="$HERE/.github/workflows/publish.yml"
STEP="Verify product .deb release signatures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

extract() { # $1=workflow file -> the run: body of the step, dedented
	python3 -I - "$1" "$STEP" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "name: " + sys.argv[2] in l)
run = next(i for i, l in enumerate(lines) if i > start and l.strip() == "run: |")
body = []
for line in lines[run + 1:]:
	if not line.strip():
		body.append("")
		continue
	if not line.startswith(" " * 10):
		break
	body.append(line[10:])
print("\n".join(body))
PY
}

# A sandbox the step can run in: the real verifier, a release key, one signed
# product .deb and the tag the download step would have pinned.
python3 -I - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
w = sys.argv[1]
k = Ed25519PrivateKey.generate()
raw = serialization.Encoding.Raw
open(os.path.join(w, "key.b64"), "w").write(base64.b64encode(k.public_key().public_bytes(raw, serialization.PublicFormat.Raw)).decode() + "\n")
open(os.path.join(w, "priv.b64"), "w").write(base64.b64encode(k.private_bytes(raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())).decode())
PY

sandbox() { # $1=name $2=good|bad -> prints the directory
	local d="$WORK/$1" root="$WORK/root-$1"
	mkdir -p "$d/scripts/verify" "$d/keyring" "$d/debs/podup" "$d/tags" "$root/DEBIAN"
	cp "$HERE/scripts/verify/verify-debs.sh" "$d/scripts/verify/"
	cp "$WORK/key.b64" "$d/keyring/glyndor-release-ed25519.b64"
	printf 'Package: podup\nVersion: 1.0.0\nArchitecture: amd64\nMaintainer: Glyndor <packages@glyndor.net>\nDescription: fixture\n' > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$root" "$d/debs/podup/podup_1.0.0_amd64.deb" >/dev/null
	if [ "$2" = good ]; then
		python3 -I - "$WORK/priv.b64" "$d/debs/podup/podup_1.0.0_amd64.deb" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(sys.argv[1]).read()))
open(sys.argv[2] + ".sig", "wb").write(k.sign(open(sys.argv[2], "rb").read()))
PY
	else
		head -c 64 /dev/zero > "$d/debs/podup/podup_1.0.0_amd64.deb.sig"
	fi
	echo v1.0.0 > "$d/tags/podup"
	echo "$d"
}

run_step() { # $1=sandbox $2=step file -> rc
	(cd "$1" && PRODUCTS="podup:x" bash "$2" >"$WORK/out" 2>&1)
}

extract "$WF" > "$WORK/step.sh"
check "the step was extracted from the workflow" "1" \
	"$(grep -v '^[[:space:]]*#' "$WORK/step.sh" | grep -c 'verify-debs.sh')"

D="$(sandbox good good)"; rc=0; run_step "$D" "$WORK/step.sh" || rc=$?
check "a .deb with a valid signature is admitted" "0" "$rc"
check "and it is moved into debs/ for the build" "1" "$([ -f "$D/debs/podup_1.0.0_amd64.deb" ] && echo 1 || echo 0)"

D="$(sandbox bad bad)"; rc=0; run_step "$D" "$WORK/step.sh" || rc=$?
check "a .deb with an invalid signature stops the step" "1" "$rc"
check "and says the signature is invalid" "1" "$(grep -qi 'invalid signature' "$WORK/out" && echo 1 || echo 0)"
check "and the .deb is not moved into debs/" "0" "$([ -f "$D/debs/podup_1.0.0_amd64.deb" ] && echo 1 || echo 0)"

# --- the control: with the call replaced by true, the invalid one passes ------
sed 's|^\( *\)\./scripts/verify/verify-debs\.sh .*|\1true|' "$WF" > "$WORK/publish-cut.yml"
check "the sabotage changed the workflow" "1" "$(cmp -s "$WF" "$WORK/publish-cut.yml" && echo 0 || echo 1)"
extract "$WORK/publish-cut.yml" > "$WORK/step-cut.sh"
D="$(sandbox cut bad)"; rc=0; run_step "$D" "$WORK/step-cut.sh" || rc=$?
check "without the call, the invalid signature is admitted (the refusal is the call's)" "0" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
