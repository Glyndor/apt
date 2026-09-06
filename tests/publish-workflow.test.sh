#!/usr/bin/env bash
#
# publish.yml assembles the signed archive and ships it to R2 daily. Nothing
# tested it, and several of its steps are only correct in one order. Reversing
# any of them produces a run that reports success while serving something wrong,
# which is the failure mode with no alarm attached.
#
# The first half reads the workflow rather than running it -- a real publish
# needs R2 and Cloudflare credentials -- and asserts the order in which the
# steps appear. The second half extracts the download step and runs it against
# a stubbed `gh`, the way tests/health-check-workflow.test.sh runs its steps
# against a local server. The download is the only step that consumes bytes
# from outside the repository, and the rest of the job trusts whatever it
# produced. Exercising it against a stub closes the gap where the asset
# selection silently picked up more than it should.
#
# It compares line numbers rather than parsing YAML, for two reasons. The shell
# test job does not install PyYAML, so a parser here would fail on the runner
# and pass on a developer machine. And the workflow has exactly one job, which
# the first case checks, so document order and execution order are the same
# thing. If a second job with steps is ever added, that case goes red and this
# reasoning has to be revisited rather than silently becoming wrong.
#
# Requires: nothing beyond coreutils, grep and python3.
set -u

cd "$(dirname "$0")/.." || exit 1
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

# --- the assumption this whole file rests on --------------------------------
#
# One job means document order is execution order. Two would not.
check "publish.yml declares exactly one job" "1" \
	"$(awk '/^jobs:/{j=1;next} j && /^  [a-zA-Z_-]+:/{c++} END{print c+0}' "$WF")"

# --- the steps exist --------------------------------------------------------
verify_sigs="$(step_line 'Verify product .deb release signatures')"
build_repo="$(step_line 'Build signed apt repository')"
sign_keyring="$(step_line 'Sign the keyring package')"
publish="$(step_line 'Publish to R2')"
purge="$(step_line 'Purge Cloudflare cache')"
verify_pub="$(step_line 'Verify the published archive')"

for pair in "verify_sigs:the release signatures are verified" \
            "build_repo:the signed repository is built" \
            "sign_keyring:the keyring package is signed" \
            "publish:the archive is published to R2" \
            "purge:the Cloudflare cache is purged" \
            "verify_pub:the published archive is read back"; do
	var="${pair%%:*}"; desc="${pair#*:}"
	eval "v=\$$var"
	check "there is a step where $desc" "1" "$([ -n "$v" ] && echo 1 || echo 0)"
done

# --- signatures are checked before anything is built ------------------------
#
# The archive's whole claim is that a package in it is the one its product
# released. Building first and verifying afterwards would put an unverified
# .deb into a signed index.
check "release signatures are verified before the repository is built" "1" \
	"$(before "$verify_sigs" "$build_repo")"

# --- the archive is uploaded before the cache is purged ---------------------
#
# Purging first re-caches the OLD objects, because the edge refetches on the
# next request and the new ones are not there yet.
check "the archive is uploaded before the cache is purged" "1" \
	"$(before "$publish" "$purge")"

# --- the cache is purged before the archive is read back --------------------
#
# This is the one the workflow explains at length: reading back while the edge
# still holds the previous metadata compares a fresh signature against stale
# bytes, and passes. A green run over a stale index is worse than a red one.
check "the cache is purged before the published archive is read back" "1" \
	"$(before "$purge" "$verify_pub")"

# --- the read-back is last --------------------------------------------------
check "nothing runs after the read-back" "1" \
	"$([ -n "$verify_pub" ] && \
	   [ "$(grep -c '^      - name:' "$WF")" \
	     -eq "$(grep -n '^      - name:' "$WF" | cut -d: -f1 | awk -v l="$verify_pub" '$1<=l' | wc -l)" ] \
	   && echo 1 || echo 0)"

# --- the three-pass sync ----------------------------------------------------
#
# Pass 1 uploads pool/ without deleting, pass 2 publishes the metadata, pass 3
# removes the pool entries the new metadata stopped referencing. The order is
# the invariant: deleting before the metadata is published leaves apt fetching
# a .deb that is already gone, and publishing metadata before the packages
# leaves it referencing files that have not arrived.
# Anchored to the command's own indentation. The comments in this workflow
# discuss `aws s3 sync` by name, and an unanchored grep counts those too -- it
# reported five passes where there are three.
sync_lines="$(grep -n '^          aws s3 sync' "$WF" | cut -d: -f1)"
check "the publish step syncs in three passes" "3" \
	"$(printf '%s\n' "$sync_lines" | grep -c .)"

p1="$(printf '%s\n' "$sync_lines" | sed -n 1p)"
p2="$(printf '%s\n' "$sync_lines" | sed -n 2p)"
p3="$(printf '%s\n' "$sync_lines" | sed -n 3p)"

# Read each pass's flags: from its own line up to the next pass (or the end of
# the step), so a flag cannot be attributed to the wrong invocation -- and with
# comment lines dropped. The comment introducing pass 2 says "Deliberately NOT
# --delete", which is enough to make an unfiltered range report that pass 1
# deletes. Every assertion in this file reads commands, never prose.
flags_of() { sed -n "${1},${2}p" "$WF" | grep -v '^[[:space:]]*#'; }

check "pass 1 uploads pool/ and deletes nothing" "1" \
	"$(flags_of "$p1" "$((p2 - 1))" | grep -q -- '--include "pool/\*"' && \
	   ! flags_of "$p1" "$((p2 - 1))" | grep -q -- '--delete' && echo 1 || echo 0)"

check "pass 2 publishes the metadata without --delete" "1" \
	"$(flags_of "$p2" "$((p3 - 1))" | grep -q -- '--exclude "pool/\*"' && \
	   ! flags_of "$p2" "$((p3 - 1))" | grep -q -- '--delete' && echo 1 || echo 0)"

check "pass 3 is the one that deletes, and only in pool/" "1" \
	"$(flags_of "$p3" "$((p3 + 6))" | grep -q -- '--delete' && \
	   flags_of "$p3" "$((p3 + 6))" | grep -q -- '--include "pool/\*"' && echo 1 || echo 0)"

# --- the purge is by URL, never the whole zone ------------------------------
#
# apt.glyndor.net is a subdomain of a shared zone, so purge_everything would
# flush glyndor.net as well. The behaviour lives in the script, not here: the
# workflow only mentions the term in the comment explaining why it is avoided,
# so asserting against the workflow would be asserting against prose.
check "the purge script never asks for purge_everything" "0" \
	"$(grep -v '^[[:space:]]*#' scripts/purge-cache.sh | grep -c 'purge_everything')"

check "and the workflow purges through that script" "1" \
	"$(grep -c '\./scripts/purge-cache\.sh' "$WF")"

#
# The cases below extract the "Download the latest .deb of each product" step
# body and run it with `gh` pointed at a stub. The stub records every
# invocation to a log so a refusal that happens before any transfer can be
# told apart from one that fires afterwards -- which is the gap the wildcard
# download left open. A regression that puts the wildcard back turns the
# "no download happened" assertions red; the rest of the file (the
# order-of-steps cases) is unaffected, because the wildcard and the named
# download live on the same lines the document-order checks are looking at.
#
# Each case plants a release listing on the stub (a tag and an assets file)
# and asserts both which message fired and whether the stub recorded any
# download call. The post-download count check still runs in the extracted
# step, so the stub also writes empty files for each --pattern so that check
# has something to count.

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extract the step body, dedented to the columning it would have inside a
# workflow. Same shape as the helper in tests/health-check-workflow.test.sh:
# read rather than restate, so the cases exercise the shell as it ships.
python3 - "$WF" "Download the latest .deb of each product" > "$WORK/step.sh" <<'PY'
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

# Sanity: an extraction that pulled the wrong step (or nothing) would let
# every behavioural case below pass for the wrong reason. The step issues
# exactly one `gh release download` call (the wildcard form is gone), and
# the comment lines that mention the same phrase are dropped by the grep
# below. A different step body, or no body at all, would return zero here.
check "the download step was extracted from the workflow" "1" \
	"$(grep -v '^[[:space:]]*#' "$WORK/step.sh" | grep -c 'gh release download')"

# --- the stubbed `gh` -------------------------------------------------------
#
# One binary on PATH: serves a canned tag and listing, records every call,
# and on `gh release download` creates empty files in --dir for each
# --pattern so the step's post-download count check has something to count.
cat >"$WORK/gh" <<'GH'
#!/usr/bin/env bash
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TAG_FILE="$SELF_DIR/tag"
ASSETS_FILE="$SELF_DIR/assets"
CALLS_FILE="$SELF_DIR/calls"
{
	printf 'call'
	for a in "$@"; do printf ' %s' "$a"; done
	printf '\n'
} >> "$CALLS_FILE"
case "$1 $2" in
	"release view")
		if printf '%s' "$*" | grep -q -- '--json tagName'; then
			cat "$TAG_FILE"
			exit 0
		fi
		if printf '%s' "$*" | grep -q -- '--json assets'; then
			cat "$ASSETS_FILE"
			exit 0
		fi
		echo "stub gh: view with no recognised --json: $*" >&2
		exit 1
		;;
	"release download")
		shift 2
		dir=""
		patterns=()
		while [ $# -gt 0 ]; do
			case "$1" in
				--dir) dir="$2"; shift 2 ;;
				--pattern) patterns+=("$2"); shift 2 ;;
				*) shift ;;
			esac
		done
		if [ -n "$dir" ]; then
			mkdir -p "$dir"
			# Expand each --pattern as a glob against the asset list, the
			# way gh does it: every matching asset name becomes a real
			# file in --dir, so the step's post-download count check has
			# the right number to count. Without this, the wildcard
			# `*_${arch}.deb` would create a file literally named
			# `*_amd64.deb` and the count check would pass on one bogus
			# file rather than the two real ones the wildcard actually
			# pulls. The assets file is `<size> <name>` per line; we want
			# just the name.
			while IFS=' ' read -r _sz asset; do
				[ -n "$asset" ] || continue
				for pat in "${patterns[@]}"; do
					case "$asset" in
						$pat) : > "$dir/$asset" ;;
					esac
				done
			done < "$ASSETS_FILE"
		fi
		exit 0
		;;
esac
echo "stub gh: unhandled invocation: $*" >&2
exit 1
GH
chmod +x "$WORK/gh"

# Plant a canned release on the stub, run the extracted step with `gh`
# pointed at the stub, and print stdout+stderr. The call log lives in
# $WORK/calls for the assertions below.
run_step() { # $1=tag  $2=assets text  $3=products  $4=archs
	local tag="$1" assets="$2" products="$3" archs="$4"
	printf '%s\n' "$tag"    > "$WORK/tag"
	printf '%s\n' "$assets" > "$WORK/assets"
	: > "$WORK/calls"
	local work
	work="$(mktemp -d "$WORK/run.XXXXXX")"
	(
		cd "$work" || exit 1
		PRODUCTS="$products" ARCHITECTURES="$archs" GH_TOKEN="x" \
			PATH="$WORK:$PATH" \
			bash "$WORK/step.sh"
	)
}

download_calls() { grep -c '^call .*release download' "$WORK/calls" || true; }

# --- two same-arch .deb files: refused before any download ------------------
#
# A release that attaches two same-arch .deb files (each under the byte cap)
# used to be fully transferred on every scheduled publish before the
# post-download count check refused it; the fifteen-minute job bound was
# the only ceiling on the waste. The new selection refuses it before any
# byte moves, naming the architecture and the candidates in the alert so
# whoever reads it does not have to go to the release page to work out
# which.
ASSETS_TWO="1000 podup_1.0.0_amd64.deb
100 podup_1.0.0_amd64.deb.sig
1000 podup_2.0.0_amd64.deb
100 podup_2.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(run_step v1.0.0 "$ASSETS_TWO" podup 'amd64 arm64')"; rc=$?
check "two same-arch .debs fail the publish" "1" "$rc"
check "and the refusal names the architecture" "1" \
	"$(printf '%s' "$out" | grep -qE 'carries 2 [^[:space:]]*amd64' && echo 1 || echo 0)"
check "and it names both candidates" "1" \
	"$(printf '%s' "$out" | grep -q 'podup_1.0.0_amd64.deb' && \
	   printf '%s' "$out" | grep -q 'podup_2.0.0_amd64.deb' && echo 1 || echo 0)"
check "and it refused before any download" "0" "$(download_calls)"

# --- an asset name that is itself a glob ------------------------------------
#
# `--pattern` is a glob and the name it is given comes from the release
# listing. A single asset literally named `*_amd64.deb` passes the count check
# above, because it is the only match, and would then re-open the wildcard the
# selection exists to close: gh would download every same-arch asset again.
# The names are refused rather than escaped, because no real asset carries a
# metacharacter.
ASSETS_GLOB="1000 *_amd64.deb
100 *_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(run_step v1.0.0 "$ASSETS_GLOB" podup 'amd64 arm64')"; rc=$?
check "an asset name carrying a glob metacharacter fails the publish" "1" "$rc"
check "and the refusal says what it found" "1" \
	"$(printf '%s' "$out" | grep -q 'glob metacharacter' && echo 1 || echo 0)"
check "and it refused before any download" "0" "$(download_calls)"

# --- an oversized asset: refused and named ----------------------------------
#
# The advertised size is attacker-controlled but checking it costs nothing
# and gives a precise name for the alert when something is too big. This is
# the existing pre-download size check; the new per-arch selection sits
# below it and does not duplicate the work. 400 MiB > the 300 MiB cap.
ASSETS_BIG="419430400 podup_1.0.0_amd64.deb
100 podup_1.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(run_step v1.0.0 "$ASSETS_BIG" podup 'amd64 arm64')"; rc=$?
check "an oversized asset fails the publish" "1" "$rc"
check "and the refusal names the oversized asset" "1" \
	"$(printf '%s' "$out" | grep -q 'podup_1.0.0_amd64.deb' && echo 1 || echo 0)"
check "and it refused before any download" "0" "$(download_calls)"

# --- happy path: downloads exactly the assets selected, and no others ------
#
# The wildcard `*_${arch}.deb` would also match every other asset whose
# name ends in `_${arch}.deb`. With the new code, each download call asks
# for the exact asset picked for its arch, and the post-download count
# check (kept as is) confirms the right number landed on disk.
ASSETS_OK="1000 podup_1.0.0_amd64.deb
100 podup_1.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(run_step v1.0.0 "$ASSETS_OK" podup 'amd64 arm64')"; rc=$?
check "a clean release publishes" "0" "$rc"
check "and downloads once per arch" "2" "$(download_calls)"
check "and the amd64 call asked for the amd64 .deb and .sig" "1" \
	"$(grep '^call .*release download' "$WORK/calls" | \
	   grep -qF -- '--pattern podup_1.0.0_amd64.deb' && \
	   grep '^call .*release download' "$WORK/calls" | \
	   grep -qF -- '--pattern podup_1.0.0_amd64.deb.sig' && echo 1 || echo 0)"
check "and the arm64 call asked for the arm64 .deb and .sig" "1" \
	"$(grep '^call .*release download' "$WORK/calls" | \
	   grep -qF -- '--pattern podup_1.0.0_arm64.deb' && \
	   grep '^call .*release download' "$WORK/calls" | \
	   grep -qF -- '--pattern podup_1.0.0_arm64.deb.sig' && echo 1 || echo 0)"

# --- a missing .sig for a present .deb: refused -----------------------------
#
# The signature is what binds a verified .deb to the product that released
# it. A .deb without its .sig would fail verify-debs.sh a few steps later,
# but by then the bytes are already on disk and the post-download count
# check has nothing to complain about -- a publish that fails later for a
# reason the download step could have caught earlier.
ASSETS_NOSIG="1000 podup_1.0.0_amd64.deb
100 podup_1.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb"
out="$(run_step v1.0.0 "$ASSETS_NOSIG" podup 'amd64 arm64')"; rc=$?
check "a missing .sig fails the publish" "1" "$rc"
check "and names the arch without a .sig" "1" \
	"$(printf '%s' "$out" | grep -qE 'carries 0 [^[:space:]]*arm64' && echo 1 || echo 0)"
check "and it refused before any download" "0" "$(download_calls)"

# --- an asset whose name would match another arch's pattern is not selected
#
# A release with assets for both arches. The per-arch selection for amd64
# must not pick the arm64 .deb (and vice versa). Recorded call lines look
# like
#   call release download v1.0.0 --repo Glyndor/podup --pattern <name> ...
# so a line containing --pattern podup_1.0.0_amd64.deb is, by construction,
# the amd64 call; grepping that line for the arm64 filename is the
# cross-arch leak probe.
ASSETS_CROSS="1000 podup_1.0.0_amd64.deb
100 podup_1.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(run_step v1.0.0 "$ASSETS_CROSS" podup 'amd64 arm64')"; rc=$?
check "a multi-arch release publishes" "0" "$rc"
check "and the amd64 call did not select the arm64 asset" "0" \
	"$(grep '^call .*release download' "$WORK/calls" | \
	   grep -F -- '--pattern podup_1.0.0_amd64.deb' | \
	   grep -cF 'podup_1.0.0_arm64' || true)"
check "and the arm64 call did not select the amd64 asset" "0" \
	"$(grep '^call .*release download' "$WORK/calls" | \
	   grep -F -- '--pattern podup_1.0.0_arm64.deb' | \
	   grep -cF 'podup_1.0.0_amd64' || true)"
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
trap 'gpgconf --kill all 2>/dev/null || true; rm -rf "$WORK_PW"' EXIT

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

# Same sign command the workflow step runs.
GNUPGHOME="$SIGNHOME_PW" gpg --batch --local-user "$fpr_pw" --armor --detach-sign \
	--output "$DEB_PW.asc" "$DEB_PW"
check "the sign command produces a non-empty .asc" "1" \
	"$( [ -s "$DEB_PW.asc" ] && echo 1 || echo 0 )"

# Detached check: --armor + --detach-sign gives a standalone signature, not
# the data plus signature. A fixture whose first line appears in the .asc
# means the sign was made without --detach-sign.
check "the .asc is detached (does not embed the signed data)" "0" \
	"$( grep -q 'fake keyring package body' "$DEB_PW.asc" && echo 1 || echo 0 )"
check "and it carries the armoured PGP signature header" "1" \
	"$( head -1 "$DEB_PW.asc" | grep -q -- '-----BEGIN PGP SIGNATURE-----' && echo 1 || echo 0 )"

# Verify with the matching public key: must succeed. Use a separate GNUPGHOME
# so the signing keyring never leaks into the verifier and a passing check
# here is the verifier alone admitting the signature.
VRF_PW="$WORK_PW/vrf"
mkdir -p "$VRF_PW"; chmod 700 "$VRF_PW"
printf '%s' "$PUB_A_PW" | GNUPGHOME="$VRF_PW" gpg --batch --quiet --import
if GNUPGHOME="$VRF_PW" gpg --batch --verify "$DEB_PW.asc" "$DEB_PW" >/dev/null 2>&1; then
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
if GNUPGHOME="$VRF2_PW" gpg --batch --verify "$DEB_PW.asc" "$DEB_PW" >/dev/null 2>&1; then
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
cp "$DEB_PW" "$DEB_PW.tampered"
printf 'injected bytes\n' >> "$DEB_PW.tampered"
if GNUPGHOME="$VRF_PW" gpg --batch --verify "$DEB_PW.asc" "$DEB_PW.tampered" >/dev/null 2>&1; then
	echo "FAIL  the .asc verified against a tampered .deb"
	fail=$((fail + 1))
else
	echo "ok    the .asc does not verify against a tampered .deb"
	pass=$((pass + 1))
fi

# === behaviour: the download step against a stubbed gh ==============
echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
