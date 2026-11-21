#!/usr/bin/env bash
#
# The keyring signature of publish.yml: which step makes it, when it runs, what
# it signs, and with which key.
#
# The bootstrap installer downloads glyndor-archive-keyring.deb from the archive
# root and refuses it without a detached signature by the archive key, so the
# publish has to serve both before the upload. Both come from the step that
# builds the signed repository: scripts/build/build-repo.sh, given --bootstrap,
# copies the keyring package to the root of public/ and signs that served copy
# with the key it imported and checked for the index. A second step used to
# import the secret again and repeat those checks; build-repo.sh always reached
# them first, so the copies could be deleted with every suite green.
#
# The structural cases below say WHERE: the build step runs before the upload,
# and it is the only step that holds the archive secret. The last block runs the
# build step as shipped, with the real build-repo.sh and throwaway keys, and
# only reprepro and the landing page stubbed: the served package and its
# signature have to come out of it, signed by the key in
# keyring/glyndor-apt-key.asc, and a copy of the workflow without --bootstrap
# must serve no signature, so the signature is shown to come from that call.
#
# The order of the other steps is in
# tests/publication/publish/publish-workflow.test.sh; the sync policy is in
# tests/publication/publish/publish-workflow-sync.test.sh and the download in
# tests/publication/publish/publish-workflow-assets.test.sh. What build-repo.sh
# does with --bootstrap on its own is in tests/build/build-repo.test.sh.
#
# Requires: gpg.
set -u

cd "$(dirname "$0")/../../.." || exit 1
HERE="$PWD"
WF=".github/workflows/publish.yml"
STEP="Build signed apt repository"
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

build_keyring="$(step_line 'Build keyring package')"
build_repo="$(step_line "$STEP")"
publish="$(step_line 'Publish to R2')"

# --- the bootstrap signature is made before the upload ----------------------
check "the repository is built after the keyring package" "1" \
	"$(before "$build_keyring" "$build_repo")"
check "and before the archive is uploaded, so the .asc is uploaded with it" "1" \
	"$(before "$build_repo" "$publish")"
# One step holds the archive secret. A second import would need its own copy of
# every check on the key, and a copy the first step always reaches before it is
# a check nothing can watch fail. Every place the workflow names the secret
# counts, its env, its run and anything else, not only an `env:` key of that
# name, and the one step that names it must be the one that runs build-repo.sh.
secret_steps() { # <workflow> -> the names of the steps that mention the secret
	python3 -I - "$1" <<'PY'
import sys
import yaml
for job in yaml.safe_load(open(sys.argv[1]))["jobs"].values():
    for step in job.get("steps", []):
        if "GLYNDOR_APT_GPG_PRIVATE_KEY" in yaml.safe_dump(step):
            print(step.get("name", step.get("uses", "?")))
PY
}
check "the archive secret is named by one step only, the one that builds the repository" \
	"$STEP" "$(secret_steps "$WF")"
WORK_SEC="$(mktemp -d)"
python3 -I - "$WF" "$WORK_SEC/leak.yml" <<'PY'
import sys
text = open(sys.argv[1]).read()
old = '          ./scripts/build/build-installers.sh public/install $installers\n'
assert text.count(old) == 1
open(sys.argv[2], "w").write(text.replace(old, '          : "${{ secrets.GLYNDOR_APT_GPG_PRIVATE_KEY }}"\n' + old))
PY
check "the control: the secret named inside a later run block is seen" "2" \
	"$(secret_steps "$WORK_SEC/leak.yml" | grep -c .)"
rm -rf "$WORK_SEC"

# --- the release tag survives the step boundary -----------------------------
#
# verify-debs.sh binds each .deb to the release it came from, and it takes that
# tag as an argument. The download step resolves it; the verification step runs
# in a different shell and cannot see the variable. An empty fourth argument
# means "do not check", which is right for the suite and would be a silently
# disabled gate here, so the workflow has to persist the tag and call the
# verifier with --require-tag, which refuses an empty one.
#
# Asserted on the workflow text because the failure is a shell-scope one that no
# amount of running verify-debs.sh in isolation can surface. That the refusal
# fires is asserted by running the step itself, with no tag on disk, in
# tests/publication/publish/publish-workflow-verify-debs.test.sh.
# shellcheck disable=SC2016  # these patterns are the literal shell text in the
# workflow, so `$p` and `$tag` must stay unexpanded; expanding them here would
# search for this test's own empty variables and match nothing, which is a
# search that always succeeds at finding no problem.
check "the download step records the pinned tag for the next step" "1" \
	"$(grep -c 'tags/\$p"$' "$WF")"
# shellcheck disable=SC2016  # same reason as above: literal workflow text.
check "the verification step reads that recorded tag back" "1" \
	"$(grep -c 'tag="\$(cat "tags/\$p"' "$WF")"
# shellcheck disable=SC2016  # same reason as above: literal workflow text.
check "the admission gate requires the tag, which it gets as its fourth argument" "1" \
	"$(grep -c 'verify-debs.sh --require-tag "debs/\$p" keyring/glyndor-release-ed25519.b64 "\$p" "\$tag"' "$WF")"

# --- the build step, as shipped, serves and signs the keyring package -------
WORK="$(mktemp -d)"
trap 'timeout 10 gpgconf --kill all 2>/dev/null || true; rm -rf "$WORK"' EXIT

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

mkkey() { # $1=uid -> prints the armored secret key
	local home="$WORK/gnupg-$1"
	mkdir -p "$home"; chmod 700 "$home"
	GNUPGHOME="$home" gpg --batch --quiet --passphrase '' \
		--quick-generate-key "$1 <$1@test.invalid>" default default never \
		>/dev/null 2>&1
	GNUPGHOME="$home" gpg --batch --armor --export-secret-keys "$1"
}
pubof() { GNUPGHOME="$WORK/gnupg-$1" gpg --batch --armor --export "$1"; }
verifies_with() { # $1=uid $2=asc $3=data -> 1 when the signature verifies against uid's key
	local home="$WORK/verify-$1"
	rm -rf "$home"; mkdir -p "$home"; chmod 700 "$home"
	pubof "$1" | GNUPGHOME="$home" gpg --batch --quiet --import 2>/dev/null
	GNUPGHOME="$home" gpg --batch --verify "$2" "$3" >/dev/null 2>&1 && echo 1 || echo 0
}

KEY_A="$(mkkey alpha)"
KEY_B="$(mkkey bravo)"

# reprepro is not what is under test and may not be installed, and the landing
# page reads the index reprepro would have written. Both are stubbed, nothing
# else is.
mkdir -p "$WORK/stubbin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/stubbin/reprepro"
chmod +x "$WORK/stubbin/reprepro"

sandbox() { # $1=name -> prints a tree laid out as the step sees it
	local d="$WORK/$1"
	mkdir -p "$d/scripts/build" "$d/keyring" "$d/debs"
	cp "$HERE/scripts/build/build-repo.sh" "$d/scripts/build/"
	printf '#!/bin/sh\nexit 0\n' > "$d/scripts/build/build-index-page.sh"
	chmod +x "$d/scripts/build/build-index-page.sh"
	pubof alpha > "$d/keyring/glyndor-apt-key.asc"
	mkdir -p "$d/pkg/DEBIAN"
	printf 'Package: glyndor-archive-keyring\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@test.invalid>\nDescription: fixture\n' > "$d/pkg/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$d/pkg" "$d/debs/glyndor-archive-keyring.deb" >/dev/null 2>&1
	printf 'product package body\n' > "$d/debs/podup_1.0.0_amd64.deb"
	echo "$d"
}

run_step() { # $1=sandbox $2=step file $3=secret -> rc
	(cd "$1" && PATH="$WORK/stubbin:$PATH" GLYNDOR_APT_GPG_PRIVATE_KEY="$3" \
		bash "$2" >"$WORK/out" 2>&1)
}

extract "$WF" > "$WORK/step.sh"
check "the step was extracted from the workflow" "1" \
	"$(grep -v '^[[:space:]]*#' "$WORK/step.sh" | grep -c 'build-repo.sh --bootstrap debs/glyndor-archive-keyring.deb public ')"

D="$(sandbox good)"; rc=0; run_step "$D" "$WORK/step.sh" "$KEY_A" || rc=$?
check "the build step succeeds with one archive key" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$WORK/out"
check "and serves the keyring package at the root of public/, byte for byte" "1" \
	"$(cmp -s "$D/debs/glyndor-archive-keyring.deb" "$D/public/glyndor-archive-keyring.deb" && echo 1 || echo 0)"
check "and its .asc verifies against the archive key" "1" \
	"$(verifies_with alpha "$D/public/glyndor-archive-keyring.deb.asc" "$D/public/glyndor-archive-keyring.deb")"
check "and not against another key" "0" \
	"$(verifies_with bravo "$D/public/glyndor-archive-keyring.deb.asc" "$D/public/glyndor-archive-keyring.deb")"
check "and the .asc is an armoured detached signature" "1" \
	"$(head -1 "$D/public/glyndor-archive-keyring.deb.asc" 2>/dev/null | grep -c -- '-----BEGIN PGP SIGNATURE-----')"

D="$(sandbox twokeys)"; rc=0
run_step "$D" "$WORK/step.sh" "$(printf '%s\n%s' "$KEY_A" "$KEY_B")" || rc=$?
check "a secret carrying two keys stops the step" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and says it found more than one secret key" "1" "$(grep -c 'expected exactly one secret key' "$WORK/out")"
check "and nothing is signed for the bootstrap" "0" \
	"$([ -e "$D/public/glyndor-archive-keyring.deb.asc" ] && echo 1 || echo 0)"

# The secret is one key, but not one clients were told to trust: the keyring
# file holds bravo and the secret is alpha.
D="$(sandbox stranger)"; pubof bravo > "$D/keyring/glyndor-apt-key.asc"; rc=0
run_step "$D" "$WORK/step.sh" "$KEY_A" || rc=$?
check "a key absent from keyring/glyndor-apt-key.asc stops the step" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and says the signing key is not in the keyring" "1" "$(grep -c 'is not present in' "$WORK/out")"
check "and nothing is signed for the bootstrap with it" "0" \
	"$([ -e "$D/public/glyndor-archive-keyring.deb.asc" ] && echo 1 || echo 0)"

# --- the control: without --bootstrap, no signature is served ---------------
sed 's|build-repo\.sh --bootstrap debs/glyndor-archive-keyring\.deb |build-repo.sh |' "$WF" > "$WORK/publish-cut.yml"
check "the sabotage changed the workflow" "1" "$(cmp -s "$WF" "$WORK/publish-cut.yml" && echo 0 || echo 1)"
extract "$WORK/publish-cut.yml" > "$WORK/step-cut.sh"
D="$(sandbox cut)"; rc=0; run_step "$D" "$WORK/step-cut.sh" "$KEY_A" || rc=$?
check "without --bootstrap the build still succeeds" "0" "$rc"
check "and no keyring signature is served (the .asc is that call's)" "0" \
	"$([ -e "$D/public/glyndor-archive-keyring.deb.asc" ] && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
