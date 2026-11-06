#!/usr/bin/env bash
#
# The download and the asset selection of publish.yml, exercised against a
# stubbed `gh`.
#
# The download is the only step that consumes bytes from outside the repository,
# and the rest of the job trusts whatever it produced. Exercising it against a
# stub closes the gap where the asset selection silently picked up more than it
# should.
#
# The cases below extract the "Download the latest .deb of each product" step
# body and run it with `gh` pointed at a stub. The stub records every
# invocation to a log so a refusal that happens before any transfer can be
# told apart from one that fires afterwards -- which is the gap the wildcard
# download left open. A regression that puts the wildcard back turns the
# "no download happened" assertions red; the order-of-steps cases are
# unaffected, because the wildcard and the named download live on the same
# lines the document-order checks are looking at.
#
# Each case plants a release listing on the stub (a tag and an assets file)
# and asserts both which message fired and whether the stub recorded any
# download call. The post-download count check still runs in the extracted
# step, so the stub also writes empty files for each --pattern so that check
# has something to count.
#
# The order of the steps around the download is in
# tests/publish/publish-workflow.test.sh; the sync policy is in
# tests/publish/publish-workflow-sync.test.sh and the keyring signature in
# tests/publish/publish-workflow-bootstrap.test.sh.
#
# Requires: nothing beyond coreutils, grep and python3.
set -u

cd "$(dirname "$0")/../.." || exit 1
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

# === behaviour: the download step against a stubbed gh ==============

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extract the step body, dedented to the columning it would have inside a
# workflow. Same shape as the helper in tests/publish/health-check-workflow.test.sh:
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
						$pat)
							# STUB_SIG_DELIVERED: a signature that is bigger than the
							# size the listing advertised, which is how the
							# post-download cap is reached at all.
							case "$asset" in
								*.sig) head -c "${STUB_SIG_DELIVERED:-0}" /dev/zero > "$dir/$asset" ;;
								*) : > "$dir/$asset" ;;
							esac
							;;
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

# --- each count check is the one that refuses ---------------------------------
#
# The case above has two .debs AND two .sigs, so the signature count refuses it
# even without the .deb count, and its message ("carries 2 ... amd64") fits both.
# Here only one thing is wrong each time, and the message names which.
ASSETS_TWO_DEBS_ONE_SIG="1000 podup_1.0.0_amd64.deb
1000 podup_2.0.0_amd64.deb
100 podup_1.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(run_step v1.0.0 "$ASSETS_TWO_DEBS_ONE_SIG" podup 'amd64 arm64')"; rc=$?
check "two same-arch .debs with one signature fail the publish" "1" "$rc"
check "and it is the .deb count that refused" "1" \
	"$(printf '%s' "$out" | grep -c 'carries 2 amd64 .deb file(s)')"
check "and it refused before any download" "0" "$(download_calls)"

ASSETS_ONE_DEB_TWO_SIGS="1000 podup_1.0.0_amd64.deb
100 podup_1.0.0_amd64.deb.sig
100 podup_2.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(run_step v1.0.0 "$ASSETS_ONE_DEB_TWO_SIGS" podup 'amd64 arm64')"; rc=$?
check "one .deb with two signatures fails the publish" "1" "$rc"
check "and it is the signature count that refused" "1" \
	"$(printf '%s' "$out" | grep -c 'carries 2 amd64 .deb.sig file(s)')"
check "and it refused before any download" "0" "$(download_calls)"

# --- the advertised size is checked before any byte moves --------------------
ASSETS_BIG_SIG="1000 podup_1.0.0_amd64.deb
99999999 podup_1.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(run_step v1.0.0 "$ASSETS_BIG_SIG" podup 'amd64 arm64')"; rc=$?
check "an oversized signature fails the publish" "1" "$rc"
check "and the refusal is the .sig cap, naming the file" "1" \
	"$(printf '%s' "$out" | grep -c 'podup_1.0.0_amd64.deb.sig is 99999999 bytes, over the')"
check "and it refused before any download" "0" "$(download_calls)"

ASSETS_NAN="abc podup_1.0.0_amd64.deb
100 podup_1.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(run_step v1.0.0 "$ASSETS_NAN" podup 'amd64 arm64')"; rc=$?
check "a non-numeric advertised size fails the publish" "1" "$rc"
check "and the refusal says the size is not numeric" "1" \
	"$(printf '%s' "$out" | grep -c 'non-numeric size')"
check "and it refused before any download" "0" "$(download_calls)"

# --- the delivered bytes are checked too -------------------------------------
# The listing's size is the publisher's word. A signature that arrives bigger
# than advertised is caught by the check after the download.
ASSETS_LIES="1000 podup_1.0.0_amd64.deb
100 podup_1.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
100 podup_1.0.0_arm64.deb.sig"
out="$(STUB_SIG_DELIVERED=5000 run_step v1.0.0 "$ASSETS_LIES" podup 'amd64 arm64')"; rc=$?
check "a signature that arrives over the cap fails the publish" "1" "$rc"
check "and the refusal is the signature cap, naming the file" "1" \
	"$(printf '%s' "$out" | grep -c '\.deb\.sig is 5000 bytes, over the')"

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

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
