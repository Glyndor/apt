#!/usr/bin/env bash
#
# The map in scripts/quality/scope/suite-scope.txt is a claim: "a change outside these
# paths cannot change this suite's verdict". A claim nobody checks rots in three
# ways, and each one is a way to skip a suite that should have run:
#
#   * a suite the workflow runs has no entry (it then always runs, which is safe
#     but means the map no longer says what it was written to say) -- or an entry
#     names a suite the workflow no longer runs;
#   * an entry cites a path that does not exist, so a rename left a pattern that
#     matches nothing and the suite is silently skipped for the files that moved;
#   * an entry has no pattern at all;
#   * a suite that only a job of its own runs, such as the ML-DSA-65 verifier,
#     is named in no test-command, so the first rule cannot see it. That job
#     decides from this map whether to run, and a suite with no entry always
#     runs: safe, but the map has stopped saying what it was written to say.
#     A suite a step hands to the suite runner is held to the same two rules;
#   * a suite reads a workflow its entry does not name. A suite that copies the
#     workflows of the repository, or opens one of them, is judging them, so a
#     change to a workflow that no pattern of its entry covers merges without
#     that suite running. The reads are the ones a suite spells from the root of
#     the repository (`$HERE/.github/workflows/<file>`, a glob of them or the
#     folder); a file it writes into a copy is not one.
#
# This reads the workflow's suite list and the map from the working tree and
# requires them to agree, with planted copies of each defect so the checker can
# be seen to fail.
#
# Requires: bash, python3.
# The fixtures are suites written as text, with `$HERE` meant to reach them
# unexpanded.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

# problems <repo-root>: prints one line per problem, nothing when the map is sound.
problems() {
	python3 -I - "$1" <<'PY'
import fnmatch, glob, os, re, sys
root = sys.argv[1]
wf = open(os.path.join(root, ".github/workflows/tests.yml")).read()
block = re.search(r"test-command: >-\n(.*?)(\n      #|\n\n|\Z)", wf, re.S).group(1)
suites = [l.strip()[2:] for l in block.splitlines() if l.strip().startswith("./tests/")]
# The suites a step of any job hands to the runner, outside the test-command.
alone = re.findall(r"check-suite-completeness\.test\.sh((?:[ \t]+\./tests/[A-Za-z0-9_./-]+\.test\.sh)+)", wf)
for chunk in alone:
    suites += [token[2:] for token in chunk.split() if token[2:] not in suites]
scope, current = {}, None
# The map is the file and the `.txt` files of the folder beside it, as the resolver reads them.
lines = open(os.path.join(root, "scripts/quality/scope/suite-scope.txt")).read().splitlines()
for extra in sorted(glob.glob(os.path.join(root, "scripts/quality/scope/suite-scope.d/*.txt"))):
    lines += open(extra).read().splitlines()
for raw in lines:
    line = raw.rstrip()
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if not line[:1].isspace():
        current = line.strip()
        if current in scope:
            print("listed twice: " + current)
        scope.setdefault(current, [])
    elif current is None:
        print("pattern before any suite: " + line.strip())
    else:
        scope[current].append(line.strip())
# A directory a tool reads when it exists and the repository does not have yet.
PENDING = (".github/actions",)


def covers(pattern, path):
    if path == ".github/workflows/*" and not pattern.endswith("*"):
        return pattern.startswith(".github/workflows/")  # the folder: some workflow
    if pattern.endswith("/**"):
        return path.startswith(pattern[:-2])
    return pattern == path or fnmatch.fnmatchcase(path, pattern)


reads = re.compile(r'\$\{?HERE\}?"?/(\.github/workflows(?:/[A-Za-z0-9_.*?-]+)?)')
for s, patterns in scope.items():
    if not os.path.isfile(os.path.join(root, s)):
        continue
    text = open(os.path.join(root, s), errors="replace").read()
    for ref in sorted(set(r.rstrip(".") for r in reads.findall(text))):
        # The folder alone is every workflow in it.
        wanted = ref + "/*" if ref == ".github/workflows" else ref
        if glob.glob(os.path.join(root, wanted)) and not any(covers(p, wanted) for p in patterns):
            print("reads a workflow its entry does not name: %s (%s)" % (ref, s))
for s in suites:
    if s not in scope:
        print("no entry: " + s)
for s, patterns in scope.items():
    if s not in suites:
        print("not run by the workflow: " + s)
    if not patterns:
        print("no pattern: " + s)
    for p in patterns:
        base = p[:-3] if p.endswith("/**") else p
        if "*" in base or base in PENDING:
            continue  # a glob inside a segment names no single path to test
        if not os.path.exists(os.path.join(root, base)):
            print("cites a path that does not exist: %s (%s)" % (p, s))
PY
}

# A tiny repository that has the workflow and the map, so a defect can be planted.
tree() {
	local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/.github/workflows" "$d/scripts/quality/scope" "$d/scripts/a" "$d/tests/a"
	printf 'jobs:\n  s:\n    with:\n      test-command: >-\n        ./tests/ci/suites/check-suite-completeness.test.sh\n        ./tests/a/one.test.sh\n        ./tests/a/two.test.sh\n' > "$d/.github/workflows/tests.yml"
	printf 'x\n' > "$d/scripts/a/x.sh"
	printf 'tests/ci/suites/check-suite-completeness.test.sh\n\ttests/ci/**\n\ntests/a/one.test.sh\n\tscripts/a/**\n\ntests/a/two.test.sh\n\ttests/a/two.test.sh\n' > "$d/scripts/quality/scope/suite-scope.txt"
	mkdir -p "$d/tests/ci"; : > "$d/tests/a/two.test.sh"
	printf 'jobs: {}\n' > "$d/.github/workflows/other.yml"
	echo "$d"
}

D="$(tree sound)"; check "control: a sound map reports nothing" "" "$(problems "$D")"

# The map in a folder beside the file: a suite listed in either is listed, and in both is listed twice.
D="$(tree folder)"; mkdir -p "$D/scripts/quality/scope/suite-scope.d"
sed -i '/^tests\/a\/two.test.sh$/,$d' "$D/scripts/quality/scope/suite-scope.txt"
printf 'tests/a/two.test.sh\n\ttests/a/two.test.sh\n' > "$D/scripts/quality/scope/suite-scope.d/zone.txt"
check "a suite listed in a file of the folder has its entry" "" "$(problems "$D")"
printf 'tests/a/one.test.sh\n\tscripts/a/**\n' >> "$D/scripts/quality/scope/suite-scope.d/zone.txt"
check "a suite listed in the map file and in the folder is reported" "listed twice: tests/a/one.test.sh" "$(problems "$D")"
D="$(tree folder2)"; mkdir -p "$D/scripts/quality/scope/suite-scope.d"
printf 'tests/a/three.test.sh\n\tscripts/a/**\n' > "$D/scripts/quality/scope/suite-scope.d/zone.txt"
check "an entry for a suite the workflow does not run, in the folder, is reported" "not run by the workflow: tests/a/three.test.sh" "$(problems "$D")"
D="$(tree folder3)"; mkdir -p "$D/scripts/quality/scope/suite-scope.d"
printf 'tests/a/three.test.sh\n\tscripts/a/**\n' > "$D/scripts/quality/scope/suite-scope.d/zone.md"
check "a file of the folder that is not .txt is not part of the map" "" "$(problems "$D")"

D="$(tree missing)"; printf '\ntests/a/three.test.sh\n\tscripts/a/**\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "an entry for a suite the workflow does not run is reported" "not run by the workflow: tests/a/three.test.sh" "$(problems "$D")"

D="$(tree noentry)"; sed -i 's|^        ./tests/a/two.test.sh|&\n        ./tests/a/four.test.sh|' "$D/.github/workflows/tests.yml"
check "a suite the workflow runs with no entry is reported" "no entry: tests/a/four.test.sh" "$(problems "$D")"

D="$(tree moved)"; rm -rf "$D/scripts/a"
check "a pattern whose directory was renamed away is reported" "cites a path that does not exist: scripts/a/** (tests/a/one.test.sh)" "$(problems "$D")"

D="$(tree file)"; rm "$D/tests/a/two.test.sh"
check "an exact file entry whose file is gone is reported" "cites a path that does not exist: tests/a/two.test.sh (tests/a/two.test.sh)" "$(problems "$D")"

D="$(tree empty)"; printf 'tests/a/one.test.sh\n' > "$D/scripts/quality/scope/suite-scope.txt"
check "an entry with no pattern is reported" "no pattern: tests/a/one.test.sh" "$(problems "$D" | grep '^no pattern')"

D="$(tree twice)"; printf '\ntests/a/one.test.sh\n\tscripts/a/**\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "a suite listed twice is reported" "listed twice: tests/a/one.test.sh" "$(problems "$D")"

D="$(tree alone)"; printf '  m:\n    steps:\n      - run: ./tests/ci/suites/check-suite-completeness.test.sh ./tests/a/five.test.sh\n' >> "$D/.github/workflows/tests.yml"
: > "$D/tests/a/five.test.sh"
check "a suite only a job of its own runs, with no entry, is reported" "no entry: tests/a/five.test.sh" "$(problems "$D")"
printf '\ntests/a/five.test.sh\n\ttests/a/five.test.sh\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "and is not once it has an entry" "" "$(problems "$D")"
sed -i 's|^      - run: .*five.test.sh|      - run: true|' "$D/.github/workflows/tests.yml"
check "an entry for a suite no job runs any more is reported" "not run by the workflow: tests/a/five.test.sh" "$(problems "$D")"

# The folder alone says the suite reads some workflow, and an entry that names
# one is the entry of a suite that reads the ones it names.
# --- a suite that reads the workflows of the repository --------------------
reader() { # $1=tree name, $2=the line the suite runs
	local d; d="$(tree "$1")"
	printf '#!/usr/bin/env bash\n%s\n' "$2" > "$d/tests/a/two.test.sh"
	printf '%s' "$d"
}

D="$(reader glob 'cp "$HERE"/.github/workflows/*.yml "$tmp"')"
check "a suite that copies every workflow, with an entry that names none, is reported" \
	"reads a workflow its entry does not name: .github/workflows/*.yml (tests/a/two.test.sh)" "$(problems "$D")"
printf '\t.github/workflows/tests.yml\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "and naming one workflow does not cover a glob of all of them" \
	"reads a workflow its entry does not name: .github/workflows/*.yml (tests/a/two.test.sh)" "$(problems "$D")"
printf '\t.github/workflows/**\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "and the folder pattern covers it" "" "$(problems "$D")"
D="$(reader glob2 'cp "$HERE"/.github/workflows/*.yml "$tmp"')"
printf '\tscripts/a/**\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "a folder pattern of another folder does not cover the workflows" \
	"reads a workflow its entry does not name: .github/workflows/*.yml (tests/a/two.test.sh)" "$(problems "$D")"

D="$(reader file 'cat "$HERE/.github/workflows/tests.yml"')"
printf '\t.github/workflows/other.yml\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "a suite that opens one workflow, with an entry that names another, is reported" \
	"reads a workflow its entry does not name: .github/workflows/tests.yml (tests/a/two.test.sh)" "$(problems "$D")"
printf '\t.github/workflows/tests.yml\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "and naming that workflow covers it" "" "$(problems "$D")"

D="$(reader folder 'ls "$HERE/.github/workflows"')"
check "a suite that lists the folder of workflows, with an entry that names none, is reported" \
	"reads a workflow its entry does not name: .github/workflows (tests/a/two.test.sh)" "$(problems "$D")"

D="$(reader folder2 'WORKFLOWS="$HERE/.github/workflows"')"
printf '\t.github/workflows/tests.yml\n' >> "$D/scripts/quality/scope/suite-scope.txt"
check "a folder of workflows with an entry that names one of them is not reported" "" "$(problems "$D")"

D="$(reader written 'cp x "$d/.github/workflows/tests.yml"')"
check "a workflow the suite writes into a copy is not a read" "" "$(problems "$D")"

D="$(reader gone 'cat "$HERE/.github/workflows/not-here.yml"')"
check "a workflow that does not exist is left to the check of cited paths" "" "$(problems "$D")"

check "the real map agrees with the real workflow and the real tree" "" "$(problems "$HERE")"

# Validate all real map entries against the caller, including suites that the
# install-step fixtures do not select. Unknown suites remain allowed to
# be absent: that is the intentional full-install default.
map_valid="$(python3 -I - "$HERE" <<'PYMAP'
from pathlib import Path
import sys
root = Path(sys.argv[1])
wf = (root / '.github/workflows/tests.yml').read_text()
allowed = set(wf.split('apt-packages: ', 1)[1].splitlines()[0].split())
seen = set()
for line in (root / 'scripts/quality/scope/suite-dependencies.txt').read_text().splitlines():
    fields = line.split()
    if not fields or fields[0].startswith('#'):
        continue
    suite, *deps = fields
    assert suite not in seen and './' + suite in wf and (root / suite).is_file(), line
    assert deps == ['-'] or (deps and set(deps) <= allowed), line
    seen.add(suite)
assert seen
print('ok')
PYMAP
)"
check "real dependency map names existing suites and supported packages without duplicates" "ok" "$map_valid"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
