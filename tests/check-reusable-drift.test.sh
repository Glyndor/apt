#!/usr/bin/env bash
# Behaviour tests for scripts/check-reusable-drift.sh.
#
# The script is the only thing standing between three deliberately duplicated
# copies of seven reusable workflows and a silent divergence between them. Its
# failure mode is not a crash: it is passing. A drift checker that fetches
# nothing, or that compares a file against itself, prints the same green line as
# one that did the work -- and that exact failure has already shipped in this
# repository, where line-limit reported every file within its limit on every
# pull request while never opening a workflow.
#
# So most of the cases below plant a condition and require red: a changed `run:`
# block, a failing fetch, an empty body, an absent local copy. The green cases
# only mean something because the red ones prove the script can tell.
#
# The script's one dependency on the outside world is `curl`. A fake `curl` on
# PATH serves prepared file contents out of a directory keyed by sibling
# repository and file name, and honours a configurable exit code, so the real
# shell runs against a deterministic GitHub. No case touches the network.
#
# Requires: bash, diff, sed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/scripts/check-reusable-drift.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# The seven files the script expects to find in every repository, and the two
# siblings it reads over HTTPS. Kept here so a change to either list in the
# script shows up as a failing test rather than as a silently smaller test run.
FILES=(
	reusable-dco.yml
	reusable-dependabot-freshness.yml
	reusable-empty-diff.yml
	reusable-line-limit.yml
	reusable-schedule-freshness.yml
	reusable-shell-ci.yml
	reusable-workflow-lint.yml
)
# Read out of the script under test rather than restated here. Each channel
# repository names the other two, so a hardcoded pair is correct in exactly one
# of the three and silently wrong in the others: the stub would serve paths the
# script never asks for, and every case would fail for a reason that has
# nothing to do with drift. Deriving it also means this list cannot fall out of
# step with the one the script actually uses.
mapfile -t SIBLINGS < <(
	awk '/^SIBLINGS=\(/{inside=1;next} inside && /^\)/{exit} inside{gsub(/[[:space:]]/,"");sub(/^Glyndor\//,"");if($0!="")print}' "$SCRIPT"
)
[ "${#SIBLINGS[@]}" -eq 2 ] || {
	echo "FAIL - could not read SIBLINGS out of $SCRIPT (got ${#SIBLINGS[@]})" >&2
	exit 1
}

# Fake `curl`. Picks the URL out of its argv, records it, and serves
# $STUB_DIR/<sibling>/<file> -- the same path shape the real URL carries, so a
# malformed URL in the script shows up here as a missing file rather than as a
# quietly passing case. An absent file exits 22, which is what `curl -f` does
# for a 404; a present but empty file serves nothing successfully, which is the
# case an ordinary checker mistakes for agreement.
write_stub() {
	mkdir -p "$WORK/bin"
	cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
DIR="${STUB_DIR:?stub content directory required}"
url=""
for arg in "$@"; do
	case "$arg" in https://*) url="$arg" ;; esac
done
printf '%s\n' "$url" >> "${STUB_LOG:-/dev/null}"
code="${STUB_EXIT_CODE:-0}"
if [ "$code" -ne 0 ]; then
	echo "stub curl: forced failure" >&2
	exit "$code"
fi
sibling="$(printf '%s' "$url" | awk -F/ '{print $5}')"
file="$(printf '%s' "$url" | awk -F/ '{print $NF}')"
path="$DIR/$sibling/$file"
[ -f "$path" ] || exit 22
cat "$path"
STUB
	chmod +x "$WORK/bin/curl"
}
write_stub

# A representative reusable: a comment block that describes its own repository,
# then the logic. Both halves matter -- the comment is what must be allowed to
# differ, the `run:` body is what must not.
body() { # $1=comment text  $2=run command
	cat <<YML
name: Example (reusable)

# $1

on:
  workflow_call:
    inputs:
      limit:
        type: number
        default: 500

jobs:
  example:
    runs-on: ubuntu-latest
    steps:
      - name: Do the thing
        run: |
          set -euo pipefail
          $2
YML
}

# Lay down a local tree and two sibling trees, all seven files, all agreeing.
seed() {
	rm -rf "$WORK/repo" "$WORK/remote"
	mkdir -p "$WORK/repo/.github/workflows"
	for s in "${SIBLINGS[@]}"; do mkdir -p "$WORK/remote/$s"; done
	for f in "${FILES[@]}"; do
		body "written for this repository" "echo $f" > "$WORK/repo/.github/workflows/$f"
		for s in "${SIBLINGS[@]}"; do
			body "written for this repository" "echo $f" > "$WORK/remote/$s/$f"
		done
	done
}

# Run the script against the seeded tree with the stub on PATH. Combined
# stdout+stderr in `out`, exit code in `rc`.
run_check() {
	: > "$WORK/curl.log"
	STUB_DIR="$WORK/remote" STUB_LOG="$WORK/curl.log" \
		PATH="$WORK/bin:$PATH" \
		bash "$SCRIPT" "$WORK/repo" 2>&1
}

says() { # $1=output  $2=pattern
	printf '%s' "$1" | grep -q -- "$2" && echo 1 || echo 0
}
counts() { # $1=output  $2=pattern
	printf '%s' "$1" | grep -c -- "$2"
}

# --- identical copies pass, and the script says how many it compared ------

seed
out="$(run_check)"
rc=$?
check "seven identical files across two siblings pass" "0" "$rc"
check "and the success line reports a comparison count" "1" \
	"$(says "$out" 'compared 14 reusable workflow')"
compared="$(printf '%s' "$out" | sed -n 's/^compared \([0-9]*\) .*/\1/p')"
check "and that count is 7 files x 2 siblings, not zero" "14" "$compared"
check "and the count it printed is greater than zero" "1" \
	"$([ "${compared:-0}" -gt 0 ] && echo 1 || echo 0)"
check "and it made one request per file per sibling" "14" \
	"$(wc -l < "$WORK/curl.log" | tr -d ' ')"
check "and asked raw.githubusercontent.com for main" "14" \
	"$(grep -c 'raw.githubusercontent.com/Glyndor/.*/main/.github/workflows/' "$WORK/curl.log")"

# --- PLANTED: a changed `run:` block must fail, and be named --------------

seed
body "written for this repository" "echo TAMPERED" \
	> "$WORK/remote/${SIBLINGS[0]}/reusable-line-limit.yml"
out="$(run_check)"
rc=$?
check "a difference inside a run: block fails" "1" "$rc"
check "and the error names the file" "1" \
	"$(says "$out" 'reusable-line-limit.yml')"
check "and names the sibling it disagrees with" "1" \
	"$(says "$out" "Glyndor/${SIBLINGS[0]}")"
check "and shows the differing line, not just 'they differ'" "1" \
	"$(says "$out" 'TAMPERED')"
check "and does not blame the network" "0" \
	"$(counts "$out" 'fetch failure')"
check "and does not print the success line" "0" \
	"$(counts "$out" 'the logic agrees')"
check "and it named only the file that drifted" "0" \
	"$(counts "$out" 'reusable-dco.yml has drifted')"

# --- PLANTED: a comment-only difference is the legitimate case ------------

seed
for s in "${SIBLINGS[@]}"; do
	for f in "${FILES[@]}"; do
		body "written for the $s repository, in different words entirely" "echo $f" \
			> "$WORK/remote/$s/$f"
	done
done
out="$(run_check)"
rc=$?
check "comments that differ per repository still pass" "0" "$rc"
check "and nothing is reported as drift" "0" "$(counts "$out" 'has drifted')"
check "and all 14 copies were still compared" "1" \
	"$(says "$out" 'compared 14 reusable workflow')"

# --- PLANTED: an indented comment inside a run: body is still a comment ---

seed
sed 's|          set -euo pipefail|          set -euo pipefail\n          # a note that only makes sense here|' \
	"$WORK/repo/.github/workflows/reusable-dco.yml" > "$WORK/tmp.yml"
mv "$WORK/tmp.yml" "$WORK/repo/.github/workflows/reusable-dco.yml"
out="$(run_check)"
rc=$?
check "a comment added inside a run: block passes" "0" "$rc"

# --- PLANTED: a failing curl is a fetch failure, never drift --------------

seed
out="$(STUB_EXIT_CODE=6 run_check)"
rc=$?
check "a curl that cannot reach GitHub fails the check" "1" "$rc"
check "and says the request failed" "1" \
	"$(says "$out" 'the request to GitHub failed')"
check "and says explicitly that this is not drift" "1" \
	"$(says "$out" 'not drift')"
check "and never uses the drift wording" "0" "$(counts "$out" 'has drifted')"
check "and refuses to claim agreement" "0" "$(counts "$out" 'the logic agrees')"
check "and reports that it compared nothing" "1" \
	"$(says "$out" 'no reusable workflow was compared')"

# --- PLANTED: an empty body fails instead of comparing nothing ------------

seed
: > "$WORK/remote/${SIBLINGS[1]}/reusable-shell-ci.yml"
out="$(run_check)"
rc=$?
check "an empty response fails rather than passing" "1" "$rc"
check "and names the empty body" "1" \
	"$(says "$out" 'empty body')"
check "and names the file it could not read" "1" \
	"$(says "$out" 'reusable-shell-ci.yml')"
check "and is not reported as drift" "0" "$(counts "$out" 'has drifted')"
check "and does not print the success line even though 13 others agreed" "0" \
	"$(counts "$out" 'the logic agrees')"

# --- PLANTED: a 404 for one file is a fetch failure, not silence ----------

seed
rm "$WORK/remote/${SIBLINGS[1]}/reusable-empty-diff.yml"
out="$(run_check)"
rc=$?
check "a sibling missing the file fails the check" "1" "$rc"
check "and says the request failed" "1" \
	"$(says "$out" 'the request to GitHub failed')"

# --- PLANTED: a local copy that is absent must not be skipped quietly -----

seed
rm "$WORK/repo/.github/workflows/reusable-workflow-lint.yml"
out="$(run_check)"
rc=$?
check "an absent local copy fails the check" "1" "$rc"
check "and names the file this repository is missing" "1" \
	"$(says "$out" 'reusable-workflow-lint.yml is not present')"
check "and is not reported as drift" "0" "$(counts "$out" 'has drifted')"

# --- PLANTED: an empty local tree compares nothing, and must say so -------

seed
rm -f "$WORK/repo/.github/workflows/"*.yml
out="$(run_check)"
rc=$?
check "a repository with no reusables at all fails" "1" "$rc"
check "and says no reusable workflow was compared" "1" \
	"$(says "$out" 'no reusable workflow was compared')"
check "and made no request at all" "0" \
	"$(wc -l < "$WORK/curl.log" | tr -d ' ')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
