#!/usr/bin/env bash
#
# scripts/quality/mutation-scope.sh decides which entries of the mutation
# catalogue a pull request runs. A wrong skip lets a guard that no suite notices
# any more merge unseen, so most cases plant a way to slip through and require
# the entry, or every entry, to run; the cases that require a skip only mean
# something because those show the decision can tell. Every repository below is
# real git: a base commit, a branch, and the merge commit GitHub would build
# (HEAD with two parents). The decision is always run from the copy in the base
# commit, the way the workflow runs it.
#
# Requires: bash, git, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

MAP=$'tests/a/one.test.sh\n\tscripts/a/**\n\ttests/a/**\n\ttests/fixtures/a/**\n\ntests/b/two.test.sh\n\tscripts/b/**\n\ttests/b/**\n'
CATALOG=$'# a comment line\na-guard\tscripts/a/x.sh\texit 1\ttrue\ttests/a/one.test.sh\nb-guard\tscripts/b/y.sh\texit 1\ttrue\ttests/b/two.test.sh\n'

# repo <name> [<decider>]: a base commit with the catalogue, the map, the
# resolver and the decider, and the checkout on a branch for the change.
repo() {
	R="$WORK/$1"; rm -rf "$R"
	mkdir -p "$R/scripts/quality" "$R/scripts/a" "$R/scripts/b" "$R/tests/a" "$R/tests/b" \
		"$R/tests/fixtures/a" "$R/tests/mutation" "$R/tests/ci/suites" "$R/.github/workflows"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "${2:-$HERE/scripts/quality/mutation-scope.sh}" "$R/scripts/quality/mutation-scope.sh"
	cp "$HERE/scripts/quality/ci-job-scope.sh" "$R/scripts/quality/ci-job-scope.sh"
	printf '%s' "$MAP" > "$R/scripts/quality/suite-scope.txt"
	printf '%s' "$CATALOG" > "$R/tests/mutation/catalog.txt"
	printf 'runner\n' > "$R/tests/mutation/run-mutations.sh"
	printf 'runner\n' > "$R/tests/ci/suites/check-suite-completeness.test.sh"
	printf 'on: pull_request\n' > "$R/.github/workflows/mutation.yml"
	printf 'exit 1\n' > "$R/scripts/a/x.sh"; printf 'exit 1\n' > "$R/scripts/b/y.sh"
	printf 'x\n' > "$R/tests/a/one.test.sh"; printf 'x\n' > "$R/tests/b/two.test.sh"
	printf 'x\n' > "$R/tests/fixtures/a/data"; printf 'readme\n' > "$R/README.md"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
}
# merge: commit the pending change on the branch and build the merge commit.
merge() {
	git -C "$R" add -A; git -C "$R" commit -qm change
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# decide [event]: the decision of the BASE copy, one line, ids space-separated.
decide() {
	git -C "$R" show HEAD^1:scripts/quality/mutation-scope.sh > "$WORK/decider.sh" 2>/dev/null \
		|| { echo "no decider in the base"; return; }
	( cd "$R" && EVENT="${1:-pull_request}" bash "$WORK/decider.sh" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' )
}

# --- a skip, and the selections that show the decision can tell -----------------
repo skip; echo more >> "$R/README.md"; merge
check "a change no entry can see runs nothing" "" "$(decide)"

repo script; echo more >> "$R/scripts/a/x.sh"; merge
check "a change to a mutated script runs that script's entries" "a-guard" "$(decide)"

repo suite; echo more >> "$R/tests/a/one.test.sh"; merge
check "a change to a suite an entry names runs that entry" "a-guard" "$(decide)"

repo fixture; echo more >> "$R/tests/fixtures/a/data"; merge
check "a change to what a named suite reads runs that entry" "a-guard" "$(decide)"

repo line; sed -i 's|^b-guard\t\(.*\)\ttests/b/two.test.sh$|b-guard\t\1\ttests/b/two.test.sh,tests/a/one.test.sh|' "$R/tests/mutation/catalog.txt"; merge
check "a changed catalogue line runs that entry, and only it" "b-guard" "$(decide)"

repo added; printf 'c-guard\tscripts/b/y.sh\texit 1\tfalse\ttests/b/two.test.sh\n' >> "$R/tests/mutation/catalog.txt"; merge
check "a new catalogue entry runs, and only it" "c-guard" "$(decide)"

repo both; echo more >> "$R/scripts/a/x.sh"; echo more >> "$R/scripts/b/y.sh"; merge
check "when every entry is selected the decision says all" "all" "$(decide)"

# --- every way the decision cannot be trusted runs every entry -------------------
for global in tests/mutation/run-mutations.sh .github/workflows/mutation.yml scripts/quality/suite-scope.txt; do
	repo "global-$(basename "$global")"; echo more >> "$R/$global"; merge
	check "a change to $global runs every entry" "all" "$(decide)"
done

# A pull request that rewrites the decider to select nothing still gets the
# decision of the base copy.
repo rewrite
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/scripts/quality/mutation-scope.sh"
echo more >> "$R/scripts/a/x.sh"; merge
check "a pull request that rewrites the decider gets the base decision" "all" "$(decide)"

repo push; echo more >> "$R/README.md"; merge
check "a push runs every entry" "all" "$(decide push)"
check "and so does a schedule" "all" "$(decide schedule)"

repo notmerge; echo more >> "$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm change
check "a checkout that is not the merge commit runs every entry" "all" "$(decide)"

repo rename; git -C "$R" mv README.md READ.md; merge
check "a rename runs every entry" "all" "$(decide)"

repo badline; printf 'broken line without tabs\n' >> "$R/tests/mutation/catalog.txt"; merge
check "a catalogue that cannot be read runs every entry" "all" "$(decide)"

repo badbase
git -C "$R" checkout -q main; git -C "$R" rm -q tests/mutation/catalog.txt; git -C "$R" commit -qm "no catalogue"
git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
printf '%s' "$CATALOG" > "$R/tests/mutation/catalog.txt"; merge
check "a base without a catalogue runs every entry" "all" "$(decide)"

# --- the control: without the resolver, a fixture change selects nothing ----------
# The fixture case above passes only because the suite map is consulted. A
# decider that skips it would miss a weakened fixture, and this shows that the
# case can tell the two apart.
python3 -I - "$HERE/scripts/quality/mutation-scope.sh" "$WORK/no-resolver.sh" <<'PY'
import sys
text = open(sys.argv[1]).read()
old = "    affected = affected_suites(suites)\n"
assert text.count(old) == 1
open(sys.argv[2], "w").write(text.replace(old, "    affected = set()\n"))
PY
repo control "$WORK/no-resolver.sh"; echo more >> "$R/tests/fixtures/a/data"; merge
check "without the suite map, a fixture change selects nothing (the selection is the map's)" "" "$(decide)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
