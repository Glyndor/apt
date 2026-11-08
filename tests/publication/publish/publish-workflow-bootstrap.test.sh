#!/usr/bin/env bash
#
# The keyring signature of publish.yml: which step signs, when it runs, what
# it signs, and whether the gpg pipeline it names actually produces a
# signature that verifies.
#
# The keyring package has to exist (Build signed apt repository has copied it
# into public/) and the upload must not have happened yet (Publish to R2). The
# file checks below assert WHICH file is signed and WHERE the .asc is written;
# the step-order check asserts only WHEN.
#
# The structural cases prove the workflow step NAMES the right paths. They do
# NOT prove the gpg pipeline produces a .asc that verifies against the same
# key and not against a different one. Asserting the shape of a control is not
# asserting the control, and this file has been bitten by exactly that before.
# The last block runs the same import + fingerprint-select + sign gpg commands
# against throwaway keys in a private GNUPGHOME and proves the mechanism
# works, so a future regression in the gpg flags is caught here even if the
# workflow file is left untouched.
#
# The order of the steps around the signature is in
# tests/publication/publish/publish-workflow.test.sh; the sync policy is in
# tests/publication/publish/publish-workflow-sync.test.sh and the download in
# tests/publication/publish/publish-workflow-assets.test.sh.
#
# Requires: gpg.
set -u

cd "$(dirname "$0")/../../.." || exit 1
WF=".github/workflows/publish.yml"
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Line of the first step whose name contains $1, or empty. Anchored to the step
# list's indentation so a mention inside a comment cannot satisfy it -- the
# comments in this workflow discuss these steps by name at length.
step_line() { grep -n "^      - name:.*$1" "$WF" | head -1 | cut -d: -f1; }

before() { # <a> <b> -> 1 when both exist and a comes first
	[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ] && echo 1 || echo 0
}

build_repo="$(step_line 'Build signed apt repository')"
sign_keyring="$(step_line 'Sign the keyring package')"
publish="$(step_line 'Publish to R2')"

# --- the keyring-signing step runs in the right place ----------------------
#
# The keyring has to exist (Build signed apt repository has copied it into
# public/) and the upload must not have happened yet (Publish to R2). The
# file checks below assert WHICH file is signed and WHERE the .asc is
# written; this one asserts only WHEN.
check "the keyring-signing step runs after the keyring is built" "1" \
	"$(before "$build_repo" "$sign_keyring")"
check "the keyring-signing step runs before the archive is uploaded" "1" \
	"$(before "$sign_keyring" "$publish")"

# --- the keyring-signing step signs the SERVED copy -------------------------
#
# The body of the step: from its `- name:` line up to the next `- name:` or
# `- uses:` line, with comment lines removed so a mention of `debs/` in the
# step's own comment cannot satisfy the wrong-path check below.
all_step_lines="$(grep -n '^      - name:\|^      - uses:' "$WF" | cut -d: -f1)"
sign_end="$(printf '%s\n' "$all_step_lines" | awk -v s="$sign_keyring" '$1 > s {print; exit}')"
[ -n "$sign_end" ] || sign_end="$(wc -l <"$WF")"
sign_body="$(sed -n "${sign_keyring},${sign_end}p" "$WF" | grep -v '^[[:space:]]*#')"

# The .asc must land under public/ so the existing upload (which syncs the
# whole public/ tree) picks it up. A signature dropped next to debs/ would
# never reach the served archive and the deploy split fails its purpose.
check "the keyring-signing step writes the .asc under public/" "1" \
	"$(printf '%s\n' "$sign_body" | grep -q 'public/glyndor-archive-keyring.deb.asc' && echo 1 || echo 0)"

# The signature must sign the SERVED copy. A signature over debs/.../X.deb
# is not a signature over public/.../X.deb; signing one and serving the
# other is exactly the silent mismatch this guard exists to catch, because
# the comment in the step says "not the debs/ one" and the assertion below
# reads commands, not prose.
check "the keyring-signing step signs the served copy, not the debs/ one" "1" \
	"$(printf '%s\n' "$sign_body" | grep -q 'public/glyndor-archive-keyring.deb' && \
	   printf '%s\n' "$sign_body" | grep -qE 'public/glyndor-archive-keyring\.deb([[:space:]]*$|\\)' && \
	   ! printf '%s\n' "$sign_body" | grep -qE 'debs/glyndor-archive-keyring' && \
	   echo 1 || echo 0)"

# --- the release tag survives the step boundary -----------------------------
#
# verify-debs.sh binds each .deb to the release it came from, and it takes that
# tag as an argument. The download step resolves it; the verification step runs
# in a different shell and cannot see the variable. An empty fourth argument
# means "do not check", which is right for the suite and would be a silently
# disabled gate here, so the workflow has to persist the tag and refuse when it
# is absent.
#
# Asserted on the workflow text because the failure is a shell-scope one that no
# amount of running verify-debs.sh in isolation can surface.
# shellcheck disable=SC2016  # these patterns are the literal shell text in the
# workflow, so `$p` and `$tag` must stay unexpanded; expanding them here would
# search for this test's own empty variables and match nothing, which is a
# search that always succeeds at finding no problem.
check "the download step records the pinned tag for the next step" "1" \
	"$(grep -c 'tags/\$p"$' "$WF")"
# shellcheck disable=SC2016  # same reason as above: literal workflow text.
check "the verification step reads that recorded tag back" "1" \
	"$(grep -c 'tag="\$(cat "tags/\$p"' "$WF")"
check "and refuses when no tag was recorded, rather than skipping the binding" "1" \
	"$(grep -c 'no pinned tag was recorded' "$WF")"
# shellcheck disable=SC2016  # same reason as above: literal workflow text.
check "the admission gate is called with the tag as its fourth argument" "1" \
	"$(grep -c 'verify-debs.sh "debs/\$p" keyring/glyndor-release-ed25519.b64 "\$p" "\$tag"' "$WF")"

# The guard has to be able to fire. Run the same two lines the workflow runs,
# in a directory with no recorded tag, and require the refusal.
guard_dir="$(mktemp -d)"
guard_out="$(cd "$guard_dir" && p=podup; tag="$(cat "tags/$p" 2>/dev/null || true)"; \
	[ -n "$tag" ] || { echo "::error::no pinned tag was recorded for $p"; exit 1; }; echo "reached the gate" )" \
	&& guard_rc=0 || guard_rc=$?
rm -rf "$guard_dir"
check "the recorded-tag guard exits non-zero with no tag on disk" "1" "$guard_rc"
check "and says which product had none" "1" \
	"$(printf '%s' "$guard_out" | grep -c 'no pinned tag was recorded for podup')"

# --- the same gpg commands actually sign and verify end to end -------------
#
# The structural cases above prove the workflow step NAMES the right paths.
# They do NOT prove the gpg pipeline produces a .asc that verifies against
# the same key and not against a different one. Asserting the shape of a
# control is not asserting the control, and this file has been bitten by
# exactly that before. This block runs the same import + fingerprint-select
# + sign gpg commands against throwaway keys in a private GNUPGHOME and
# proves the mechanism works, so a future regression in the gpg flags is
# caught here even if the workflow file is left untouched.
#
# Requires: gpg.
WORK_PW="$(mktemp -d)"
trap 'timeout 10 gpgconf --kill all 2>/dev/null || true; rm -rf "$WORK_PW"' EXIT

mkkey_pw() { # $1=uid -> prints the armored secret key
	local home="$WORK_PW/gnupg-$1"
	mkdir -p "$home"; chmod 700 "$home"
	GNUPGHOME="$home" gpg --batch --quiet --passphrase '' \
		--quick-generate-key "$1 <$1@test.invalid>" default default never \
		>/dev/null 2>&1
	GNUPGHOME="$home" gpg --batch --armor --export-secret-keys "$1"
}
pubof_pw() { # $1=uid -> prints the armored public key
	GNUPGHOME="$WORK_PW/gnupg-$1" gpg --batch --armor --export "$1"
}

# Only alpha's secret half is imported anywhere: bravo exists to prove the
# signature does NOT verify against a key that did not sign it, and for that
# only its public half is needed. Generated for its side effect, so the
# secret is not bound to a name nothing reads.
KEY_A_PW="$(mkkey_pw alpha)"
mkkey_pw bravo >/dev/null
PUB_A_PW="$(pubof_pw alpha)"
PUB_B_PW="$(pubof_pw bravo)"

# A fixture standing in for the served keyring .deb. What is being tested is
# the gpg pipeline, not the .deb's contents.
DEB_PW="$WORK_PW/glyndor-archive-keyring.deb"
printf 'fake keyring package body\n' > "$DEB_PW"

# Same import + fingerprint-select path build-repo.sh and the new step use.
SIGNHOME_PW="$WORK_PW/sign"
mkdir -p "$SIGNHOME_PW"; chmod 700 "$SIGNHOME_PW"
printf '%s' "$KEY_A_PW" | GNUPGHOME="$SIGNHOME_PW" gpg --batch --quiet --import
sec_count_pw="$(GNUPGHOME="$SIGNHOME_PW" gpg --batch --with-colons --list-secret-keys \
	| { grep -c '^sec:' || true; })"
check "the import guard admits exactly one secret key" "1" \
	"$( [ "$sec_count_pw" -eq 1 ] && echo 1 || echo 0 )"
fpr_pw="$(GNUPGHOME="$SIGNHOME_PW" gpg --batch --with-colons --list-secret-keys \
	| awk -F: '/^fpr:/{print $10; exit}')"
check "the fingerprint extract reads the only key (40 hex chars)" "40" "${#fpr_pw}"

# Read the signing step body, dedented to the columning it would have
# inside a workflow (same shape as the helper that extracts the download
# step body above). The cut point -- immediately before the line that
# imports a GitHub Actions secret the test has no source for -- is the
# documented exception, not a stubbed gpg. Everything after the cut runs
# against our pre-imported keyring and the pre-computed fingerprint.
python3 - "$WF" "Sign the keyring package" > "$WORK_PW/sign_step.sh" <<'PY'
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
awk '/^unset GLYNDOR_APT_GPG_PRIVATE_KEY$/{found=1} found' \
	"$WORK_PW/sign_step.sh" > "$WORK_PW/sign_body.sh"

# A scratch tree mirroring what the step sees at run time: a served
# keyring .deb under public/, and keyring/glyndor-apt-key.asc carrying
# alpha's public key so the step's fingerprint-membership check (the
# "signing key is not present in keyring/glyndor-apt-key.asc" guard)
# passes against the same key the body just selected.
SIGN_TREE="$WORK_PW/tree"
mkdir -p "$SIGN_TREE/public" "$SIGN_TREE/keyring"
cp "$DEB_PW" "$SIGN_TREE/public/glyndor-archive-keyring.deb"
printf '%s' "$PUB_A_PW" > "$SIGN_TREE/keyring/glyndor-apt-key.asc"

(
	cd "$SIGN_TREE" || exit 1
	GNUPGHOME="$SIGNHOME_PW" FPR="$fpr_pw" \
		bash "$WORK_PW/sign_body.sh"
)

ASC="$SIGN_TREE/public/glyndor-archive-keyring.deb.asc"
DEB="$SIGN_TREE/public/glyndor-archive-keyring.deb"

# All crypto cases below read $ASC, the artifact the step produced. Gate
# them on a real .asc existing: without the gate, the file-reading
# assertions would error out (counted as red) while the verify-fails
# assertions would pass by accident, because verifying a missing .asc
# always fails for the wrong reason.
if [ ! -s "$ASC" ]; then
	check "the sign command produces a non-empty .asc (no .asc written)" "1" "0"
	check "the .asc is detached (does not embed the signed data) (no .asc written)" "1" "0"
	check "and it carries the armoured PGP signature header (no .asc written)" "1" "0"
	check "the .asc verifies against the matching public key (no .asc written)" "1" "0"
	check "the .asc does not verify against a non-matching public key (no .asc written)" "1" "0"
	check "the .asc does not verify against a tampered .deb (no .asc written)" "1" "0"
	check "the extracted signing step produces a signature gpgv accepts (no .asc written)" "1" "0"
else
	check "the sign command produces a non-empty .asc" "1" \
		"$( [ -s "$ASC" ] && echo 1 || echo 0 )"

	# Detached check: --armor + --detach-sign gives a standalone signature, not
	# the data plus signature. A fixture whose first line appears in the .asc
	# means the sign was made without --detach-sign.
	check "the .asc is detached (does not embed the signed data)" "0" \
		"$( grep -q 'fake keyring package body' "$ASC" && echo 1 || echo 0 )"
	check "and it carries the armoured PGP signature header" "1" \
		"$( head -1 "$ASC" | grep -q -- '-----BEGIN PGP SIGNATURE-----' && echo 1 || echo 0 )"

	# Verify with the matching public key: must succeed. Use a separate GNUPGHOME
	# so the signing keyring never leaks into the verifier and a passing check
	# here is the verifier alone admitting the signature.
	VRF_PW="$WORK_PW/vrf"
	mkdir -p "$VRF_PW"; chmod 700 "$VRF_PW"
	printf '%s' "$PUB_A_PW" | GNUPGHOME="$VRF_PW" gpg --batch --quiet --import
	if GNUPGHOME="$VRF_PW" gpg --batch --verify "$ASC" "$DEB" >/dev/null 2>&1; then
		echo "ok    the .asc verifies against the matching public key"
		pass=$((pass + 1))
	else
		echo "FAIL  the .asc did not verify against the matching public key"
		fail=$((fail + 1))
	fi

	# Verify with a different public key: must fail (the whole point).
	VRF2_PW="$WORK_PW/vrf2"
	mkdir -p "$VRF2_PW"; chmod 700 "$VRF2_PW"
	printf '%s' "$PUB_B_PW" | GNUPGHOME="$VRF2_PW" gpg --batch --quiet --import
	if GNUPGHOME="$VRF2_PW" gpg --batch --verify "$ASC" "$DEB" >/dev/null 2>&1; then
		echo "FAIL  the .asc verified against a non-matching public key"
		fail=$((fail + 1))
	else
		echo "ok    the .asc does not verify against a non-matching public key"
		pass=$((pass + 1))
	fi

	# Tampered .deb must fail verification against the matching key. The
	# fingerprint check stops an attacker who swapped the key; this is the
	# separate property that the .asc catches an attacker who swapped the
	# bytes after the signature was made.
	cp "$DEB" "$DEB.tampered"
	printf 'injected bytes\n' >> "$DEB.tampered"
	if GNUPGHOME="$VRF_PW" gpg --batch --verify "$ASC" "$DEB.tampered" >/dev/null 2>&1; then
		echo "FAIL  the .asc verified against a tampered .deb"
		fail=$((fail + 1))
	else
		echo "ok    the .asc does not verify against a tampered .deb"
		pass=$((pass + 1))
	fi

	# The structural grep cases above prove the workflow step NAMES the right
	# paths; the gpg cases above prove the same gpg flags produce a verifying
	# signature. The closing case proves the step's body, as written, actually
	# produces one. A regression that drops --detach-sign, swaps --local-user
	# for --default-key, or writes the .asc next to debs/ instead of public/
	# changes the body the step runs and this assertion goes red, regardless
	# of whether the typed copy still looks correct.
	if GNUPGHOME="$VRF_PW" gpgv --keyring "$VRF_PW/pubring.kbx" \
		"$ASC" "$DEB" >/dev/null 2>&1; then
		echo "ok    the extracted signing step produces a signature gpgv accepts"
		pass=$((pass + 1))
	else
		echo "FAIL  the extracted signing step produces a signature gpgv accepts"
		fail=$((fail + 1))
	fi
fi

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
