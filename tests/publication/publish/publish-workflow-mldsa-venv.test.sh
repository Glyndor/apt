#!/usr/bin/env bash
#
# publish.yml installs the cryptography wheel that ML-DSA-65 needs only once an
# ML-DSA-65 key is committed, and its verification step then runs on that
# wheel's python.
#
# Until the key exists the job must behave exactly as before: no venv, no pip,
# nothing from PyPI beside the signing keys of the later steps. The day the key
# is committed it must install the hash-pinned wheel, or the first release that
# carries a second signature would stop the daily publish of every product on a
# library without ML-DSA. Both halves are decided by shell in the workflow, so
# the steps are extracted as shipped and run here: the install step against a
# stubbed sudo and python3 that record what they were asked to do, and the
# verification step against a real signed .deb with a venv stand-in that records
# that it was the python used. Each half is then run from a copy of the workflow
# with its decision removed, and the case it guards has to notice.
#
# Requires: python3 with the `cryptography` module, dpkg-deb.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WF="$HERE/.github/workflows/publish.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
REAL_PYTHON="$(command -v python3)"

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

extract() { # $1=workflow file $2=step name -> the run: body, dedented
	python3 -I - "$1" "$2" <<'PY'
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
INSTALL="Install reprepro and the signature verifier"
VERIFY="Verify product .deb release signatures"

# --- the install step ---------------------------------------------------------
#
# sudo records its arguments and succeeds. python3 handles `-m venv <dir>` by
# creating <dir>/bin/python, which records its arguments as the pip call; any
# other use of python3 is refused, so the step cannot reach the real one.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$LOG"
SH
cat > "$WORK/stub/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -m ] && [ "${2:-}" = venv ] && [ -n "${3:-}" ]; then
	printf 'venv %s\n' "$3" >> "$LOG"
	mkdir -p "$3/bin"
	printf '#!/usr/bin/env bash\nprintf "pip %%s\\n" "$*" >> "$LOG"\nexit "${PIP_RC:-0}"\n' > "$3/bin/python"
	chmod +x "$3/bin/python"
	exit 0
fi
printf 'python3 %s\n' "$*" >> "$LOG"
exit 1
SH
chmod +x "$WORK/stub/sudo" "$WORK/stub/python3"

install_run() { # $1=step file $2=key file content -> rc; the log is $WORK/log
	local d="$WORK/install"
	rm -rf "$d"; mkdir -p "$d/keyring" "$d/scripts/verify" "$d/rt"
	printf '%s' "$2" > "$d/keyring/glyndor-release-mldsa65.b64"
	: > "$WORK/log"
	(cd "$d" && LOG="$WORK/log" RUNNER_TEMP="$d/rt" PATH="$WORK/stub:$PATH" bash -e "$1" >"$WORK/out" 2>&1)
}
said() { grep -c -- "$1" "$WORK/log" || true; }

extract "$WF" "$INSTALL" > "$WORK/install.sh"
check "the install step was extracted from the workflow" "1" \
	"$(grep -v '^[[:space:]]*#' "$WORK/install.sh" | grep -c 'apt-get install')"

rc=0; install_run "$WORK/install.sh" "$(cat "$HERE/keyring/glyndor-release-mldsa65.b64")" || rc=$?
if grep -qvE '^[[:space:]]*(#|$)' "$HERE/keyring/glyndor-release-mldsa65.b64"; then
	echo "not run - the committed key file installs nothing (it holds a key now)"
else
	check "with the committed key file, which holds no key, the step succeeds" "0" "$rc"
	check "and it installs the same distribution packages as before" "1" \
		"$(said '^sudo apt-get install -y -qq reprepro python3-cryptography$')"
	check "and it creates no venv and runs no pip" "0 0" "$(said '^venv ') $(said '^pip ')"
fi

rc=0; install_run "$WORK/install.sh" "$(printf '# comment\n\n   \n\t# indented comment\n')" || rc=$?
check "a key file of comments and blank lines installs nothing" "0 0 0" "$rc $(said '^venv ') $(said '^pip ')"

rc=0; install_run "$WORK/install.sh" "$(printf '# the key\nAAAA\n')" || rc=$?
check "a key file with a key creates the venv outside the workspace" "0 1" \
	"$rc $(said "^venv $WORK/install/rt/mldsa-venv\$")"
check "and installs the wheel pinned by hash, binary only, from the requirements file" "1" \
	"$(said '^pip -m pip install --quiet --disable-pip-version-check --require-hashes --only-binary=:all: -r scripts/verify/verify-debs-requirements.txt$')"
check "and still installs the distribution packages" "1" "$(said '^sudo apt-get install -y -qq reprepro python3-cryptography$')"

rc=0; PIP_RC=1 install_run "$WORK/install.sh" "$(printf 'AAAA\n')" || rc=$?
check "a pip install that fails stops the step" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# The controls: the decision forced either way, and the case that guards it red.
sed 's|^\( *\)if grep -qvE .*glyndor-release-mldsa65\.b64 2>/dev/null; then$|\1if true; then|' "$WF" > "$WORK/wf-always.yml"
check "the always-install sabotage changed the workflow" "1" "$(cmp -s "$WF" "$WORK/wf-always.yml" && echo 0 || echo 1)"
extract "$WORK/wf-always.yml" "$INSTALL" > "$WORK/install-always.sh"
install_run "$WORK/install-always.sh" "$(printf '# no key\n')" || true
check "without the decision a file with no key installs from PyPI (the refusal is the decision's)" "1" "$(said '^pip ')"
sed 's|^\( *\)if grep -qvE .*glyndor-release-mldsa65\.b64 2>/dev/null; then$|\1if false; then|' "$WF" > "$WORK/wf-never.yml"
extract "$WORK/wf-never.yml" "$INSTALL" > "$WORK/install-never.sh"
install_run "$WORK/install-never.sh" "$(printf 'AAAA\n')" || true
check "and with it forced off a committed key installs nothing (the install is the decision's)" "0" "$(said '^pip ')"

# --- the verification step ------------------------------------------------------
#
# A sandbox with the real verifier, a release key and one signed .deb. The venv
# stand-in's python3 records that it ran and hands over to the real python, so
# the signature is still checked for real.
"$REAL_PYTHON" -I - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
w = sys.argv[1]
k = Ed25519PrivateKey.generate()
open(os.path.join(w, "ed.b64"), "w").write(base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode() + "\n")
open(os.path.join(w, "ed.priv"), "wb").write(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption()))
PY
verify_run() { # $1=step file $2=with|without venv, or unset RUNNER_TEMP -> rc
	local d="$WORK/verify" root="$WORK/root"
	rm -rf "$d" "$root"; mkdir -p "$d/scripts/verify" "$d/keyring" "$d/debs/podup" "$d/tags" "$d/rt" "$root/DEBIAN"
	cp "$HERE/scripts/verify/verify-debs.sh" "$d/scripts/verify/"
	cp "$WORK/ed.b64" "$d/keyring/glyndor-release-ed25519.b64"
	printf 'Package: podup\nVersion: 1.0.0\nArchitecture: amd64\nMaintainer: Glyndor <packages@glyndor.net>\nDescription: fixture\n' > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$root" "$d/debs/podup/podup_1.0.0_amd64.deb" >/dev/null
	"$REAL_PYTHON" -I -c 'import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
open(sys.argv[2] + ".sig", "wb").write(k.sign(open(sys.argv[2], "rb").read()))' "$WORK/ed.priv" "$d/debs/podup/podup_1.0.0_amd64.deb"
	echo v1.0.0 > "$d/tags/podup"
	if [ "$2" = with ]; then
		mkdir -p "$d/rt/mldsa-venv/bin"
		printf '#!/usr/bin/env bash\necho used >> "%s"\nexec "%s" "$@"\n' "$WORK/venv-used" "$REAL_PYTHON" > "$d/rt/mldsa-venv/bin/python3"
		chmod +x "$d/rt/mldsa-venv/bin/python3"
	fi
	rm -f "$WORK/venv-used"
	(
		cd "$d" || exit 1
		if [ "$2" = unset ]; then unset RUNNER_TEMP; else export RUNNER_TEMP="$d/rt"; fi
		PRODUCTS=podup bash "$1" >"$WORK/out" 2>&1
	)
}
used() { [ -s "$WORK/venv-used" ] && echo 1 || echo 0; }

extract "$WF" "$VERIFY" > "$WORK/verify.sh"
rc=0; verify_run "$WORK/verify.sh" with || rc=$?
check "with the venv present the package is admitted" "0" "$rc"
check "and the verifier ran on the venv's python" "1" "$(used)"
rc=0; verify_run "$WORK/verify.sh" without || rc=$?
check "without it the package is admitted on the system python, as before" "0 0" "$rc $(used)"
rc=0; verify_run "$WORK/verify.sh" unset || rc=$?
check "and the step runs where RUNNER_TEMP is not set at all" "0" "$rc"

# shellcheck disable=SC2016 # the workflow's own text, matched literally
sed 's|^\( *\)PATH="$mldsa_venv/bin:$PATH"$|\1:|' "$WF" > "$WORK/wf-nopath.yml"
check "the no-PATH sabotage changed the workflow" "1" "$(cmp -s "$WF" "$WORK/wf-nopath.yml" && echo 0 || echo 1)"
extract "$WORK/wf-nopath.yml" "$VERIFY" > "$WORK/verify-nopath.sh"
verify_run "$WORK/verify-nopath.sh" with || true
check "without the PATH line the venv is not used (the use is the line's)" "0" "$(used)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
