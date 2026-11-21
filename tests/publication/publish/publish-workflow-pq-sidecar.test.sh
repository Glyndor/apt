#!/usr/bin/env bash
#
# The download step of publish.yml and the second release signature,
# <deb>.mldsa65.sig, exercised against a stubbed `gh`.
#
# The step has to fetch the ML-DSA-65 signature when a release carries one, so
# verify-debs.sh can check it, and must not fail when a release does not, which
# is every release today. It bounds the new asset the way it bounds the .sig:
# at most one per architecture, under the same size cap before and after the
# transfer, and never a name that is a glob or a path. The selection and the
# caps for the .deb and the .sig are in publish-workflow-assets.test.sh.
#
# The last case runs a copy of the workflow with the line that adds the ML-DSA-65
# signature to the download removed, and requires the first case to notice.
#
# Requires: nothing beyond coreutils, grep and python3.
set -u

cd "$(dirname "$0")/../../.." || exit 1
WF=".github/workflows/publish.yml"
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

extract() { # $1=workflow file -> the run: body of the download step, dedented
	python3 -I - "$1" "Download the latest .deb of each product" <<'PY'
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

# A stub `gh`: serves a canned tag and listing, records every call, and on
# `release download` writes each asset a --pattern selects into --dir. A
# .mldsa65.sig is written STUB_PQ_DELIVERED bytes long, anything else empty.
cat > "$WORK/gh" <<'GH'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
printf 'call %s\n' "$*" >> "$here/calls"
case "$1 $2" in
	"release view")
		case "$*" in
			*"--json tagName"*) cat "$here/tag" ;;
			*"--json assets"*) cat "$here/assets" ;;
			*) exit 1 ;;
		esac
		exit 0
		;;
	"release download")
		shift 2
		dir="" patterns=()
		while [ $# -gt 0 ]; do
			case "$1" in
				--dir) dir="$2"; shift 2 ;;
				--pattern) patterns+=("$2"); shift 2 ;;
				*) shift ;;
			esac
		done
		mkdir -p "$dir"
		while IFS=' ' read -r _ asset; do
			for pat in "${patterns[@]}"; do
				# shellcheck disable=SC2254 # gh treats --pattern as a glob
				case "$asset" in
					$pat)
						case "$asset" in
							*.mldsa65.sig) head -c "${STUB_PQ_DELIVERED:-0}" /dev/zero > "$dir/$asset" ;;
							*) : > "$dir/$asset" ;;
						esac
						;;
				esac
			done
		done < "$here/assets"
		exit 0
		;;
esac
exit 1
GH
chmod +x "$WORK/gh"

run_step() { # $1=step file $2=assets text -> stdout+stderr; the tree is left in $WORK/run
	printf 'v1.0.0\n' > "$WORK/tag"
	printf '%s\n' "$2" > "$WORK/assets"
	: > "$WORK/calls"
	rm -rf "$WORK/run"; mkdir -p "$WORK/run"
	(cd "$WORK/run" && PRODUCTS=podup ARCHITECTURES="amd64 arm64" GH_TOKEN=x PATH="$WORK:$PATH" bash "$1" 2>&1)
}
downloads() { grep -c '^call release download' "$WORK/calls" || true; }
asked_for() { grep '^call release download' "$WORK/calls" | grep -cF -- "--pattern $1" || true; }
landed() { [ -f "$WORK/run/debs/podup/$1" ] && echo 1 || echo 0; }

extract "$WF" > "$WORK/step.sh"
check "the download step was extracted from the workflow" "1" \
	"$(grep -v '^[[:space:]]*#' "$WORK/step.sh" | grep -c 'gh release download')"

BASE="1000 podup_1.0.0_amd64.deb
64 podup_1.0.0_amd64.deb.sig
1000 podup_1.0.0_arm64.deb
64 podup_1.0.0_arm64.deb.sig"

# --- a release with a second signature for each architecture ----------------
WITH="$BASE
3309 podup_1.0.0_amd64.deb.mldsa65.sig
3309 podup_1.0.0_arm64.deb.mldsa65.sig"
out="$(STUB_PQ_DELIVERED=3309 run_step "$WORK/step.sh" "$WITH")"; rc=$?
check "a release with ML-DSA-65 signatures publishes" "0" "$rc"
check "and the amd64 download asks for its ML-DSA-65 signature" "1" "$(asked_for podup_1.0.0_amd64.deb.mldsa65.sig)"
check "and the arm64 one for its own" "1" "$(asked_for podup_1.0.0_arm64.deb.mldsa65.sig)"
check "and both land beside their .deb" "1 1" \
	"$(landed podup_1.0.0_amd64.deb.mldsa65.sig) $(landed podup_1.0.0_arm64.deb.mldsa65.sig)"
check "and the second signature is not counted as a second .sig" "0" \
	"$(printf '%s' "$out" | grep -c 'carries 2')"

# --- a release without one, which is every release today --------------------
out="$(run_step "$WORK/step.sh" "$BASE")"; rc=$?
check "a release without ML-DSA-65 signatures still publishes" "0" "$rc"
check "and nothing asks for one" "0" "$(grep -c 'mldsa65' "$WORK/calls")"
check "and the .deb and .sig are downloaded as before" "1 1" \
	"$(asked_for podup_1.0.0_amd64.deb) $(asked_for podup_1.0.0_arm64.deb.sig)"

# --- only one architecture carries one ----------------------------------------
out="$(STUB_PQ_DELIVERED=3309 run_step "$WORK/step.sh" "$BASE
3309 podup_1.0.0_amd64.deb.mldsa65.sig")"; rc=$?
check "a second signature on one architecture only publishes" "0" "$rc"
check "and only that architecture asks for it" "1 0" \
	"$(asked_for podup_1.0.0_amd64.deb.mldsa65.sig) $(grep '^call release download' "$WORK/calls" | grep -F 'arm64.deb ' | grep -c mldsa65)"

# --- two for one architecture: refused before any download ----------------------
out="$(run_step "$WORK/step.sh" "$BASE
3309 podup_1.0.0_amd64.deb.mldsa65.sig
3309 podup_0.9.0_amd64.deb.mldsa65.sig")"; rc=$?
check "two amd64 ML-DSA-65 signatures fail the publish" "1" "$rc"
check "and the refusal says what it found" "1" \
	"$(printf '%s' "$out" | grep -c 'carries 2 amd64 .deb.mldsa65.sig files')"
check "and it refused before any download" "0" "$(downloads)"

# --- the size cap, advertised and delivered ------------------------------------
out="$(run_step "$WORK/step.sh" "$BASE
99999 podup_1.0.0_amd64.deb.mldsa65.sig")"; rc=$?
check "an ML-DSA-65 signature advertised over the cap fails the publish" "1" "$rc"
check "and the refusal is the .sig cap, naming it" "1" \
	"$(printf '%s' "$out" | grep -c 'podup_1.0.0_amd64.deb.mldsa65.sig is 99999 bytes, over the 4096-byte .sig cap')"
check "and it refused before any download" "0" "$(downloads)"

out="$(STUB_PQ_DELIVERED=5000 run_step "$WORK/step.sh" "$BASE
3309 podup_1.0.0_amd64.deb.mldsa65.sig")"; rc=$?
check "an ML-DSA-65 signature that arrives over the cap fails the publish" "1" "$rc"
check "and the refusal is the signature cap, naming it" "1" \
	"$(printf '%s' "$out" | grep -c 'podup_1.0.0_amd64.deb.mldsa65.sig is 5000 bytes, over the 4096-byte signature cap')"

# --- a name that is a glob ------------------------------------------------------
out="$(run_step "$WORK/step.sh" "$BASE
3309 *_amd64.deb.mldsa65.sig")"; rc=$?
check "an ML-DSA-65 signature named with a glob metacharacter fails the publish" "1" "$rc"
check "and the refusal names the metacharacter" "1" "$(printf '%s' "$out" | grep -c 'glob metacharacter')"
check "and it refused before any download" "0" "$(downloads)"

# --- the control: without the line that adds it, it is not downloaded -----------
# shellcheck disable=SC2016 # the workflow's own text, matched literally
sed 's|^\( *\)patterns+=(--pattern "${pq_sig_for_arch\[$arch\]}")|\1:|' "$WF" > "$WORK/publish-cut.yml"
check "the sabotage changed the workflow" "1" "$(cmp -s "$WF" "$WORK/publish-cut.yml" && echo 0 || echo 1)"
extract "$WORK/publish-cut.yml" > "$WORK/step-cut.sh"
out="$(STUB_PQ_DELIVERED=3309 run_step "$WORK/step-cut.sh" "$WITH")"
check "without that line the ML-DSA-65 signature is not fetched (the download is the line's)" "0" \
	"$(landed podup_1.0.0_amd64.deb.mldsa65.sig)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
