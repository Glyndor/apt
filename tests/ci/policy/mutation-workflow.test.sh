#!/usr/bin/env bash
#
# .github/workflows/mutation.yml runs the mutation sweep on a pull request only
# when the change can affect a catalogued guard. Two of its steps carry the
# decisions that matter, and both are run here as shipped, extracted from the
# workflow:
#
#   - the decide step takes the decision from the copy of
#     scripts/quality/scope/mutation-scope.sh in the BASE commit, and runs every entry
#     when there is no such copy, when it fails or when it prints something that
#     is not an id;
#   - the gate passes only for "not needed and skipped" and "needed and
#     passed". A skipped job reports success whether the decision said skip or
#     the decision itself failed, and the gate is what tells the two apart.
#
# Each refusal of the gate is then removed in a copy of the workflow and the
# case it decides must pass there, so the refusal is shown to be that line's.
#
# Requires: bash, git, python3 with PyYAML.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WF="$HERE/.github/workflows/mutation.yml"
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

step() { # <workflow> <job> <step name> -> the run: body of that step
	python3 -I - "$@" <<'PY'
import sys
import yaml
spec = yaml.safe_load(open(sys.argv[1]))
for step in spec["jobs"][sys.argv[2]]["steps"]:
    if step.get("name") == sys.argv[3]:
        print(step["run"])
        break
else:
    raise SystemExit(f"no step {sys.argv[3]!r} in job {sys.argv[2]!r}")
PY
}
job() { # <job> <key> -> a key of the job, as YAML
	python3 -I - "$WF" "$@" <<'PY'
import sys
import yaml
spec = yaml.safe_load(open(sys.argv[1]))
print(spec["jobs"][sys.argv[2]].get(sys.argv[3]))
PY
}

# --- the shape the two steps rely on ----------------------------------------------
on="$(python3 -I -c 'import sys,yaml; s=yaml.safe_load(open(sys.argv[1])); print(sorted((s.get("on") or s.get(True)).keys()))' "$WF")"
check "the workflow runs on pull requests, the schedule and on demand" \
	"['pull_request', 'schedule', 'workflow_dispatch']" "$on"
check "the sweep is skipped only on an explicit false, and starts when the decision failed" "\${{ !cancelled() && needs.decide.outputs.run != 'false' }}" "$(job mutations if)"
check "the gate runs whatever happened before it" "always()" "$(job gate if)"
check "and it waits on the decision and the sweep" "['decide', 'mutations']" "$(job gate needs)"

# --- the decide step ----------------------------------------------------------------
DECIDE="Decide from the base commit"
step "$WF" decide "$DECIDE" > "$WORK/decide.sh"

# repo <decider body or ->: a base commit that carries the decider (or none), and
# a second commit on top, so HEAD^1 is the base.
repo() {
	R="$WORK/repo-$RANDOM"; mkdir -p "$R/scripts/quality/scope"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	if [ "$1" != - ]; then printf '%s\n' "$1" > "$R/scripts/quality/scope/mutation-scope.sh"; fi
	printf 'x\n' > "$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm base
	printf 'y\n' >> "$R/README.md"; git -C "$R" commit -qam change
}
decide() { # <event> -> "run=<..> ids=<..>"
	: > "$WORK/output"; : > "$WORK/summary"
	( cd "$R" && EVENT="$1" RUNNER_TEMP="$WORK" GITHUB_OUTPUT="$WORK/output" GITHUB_STEP_SUMMARY="$WORK/summary" \
		bash "$WORK/decide.sh" >/dev/null 2>&1 ) || { echo "step failed"; return; }
	printf '%s %s' "$(grep '^run=' "$WORK/output")" "$(grep '^ids=' "$WORK/output")"
}

repo $'#!/usr/bin/env bash\nprintf "%s\\n" one-entry two-entry'
check "the base decision names the entries to run" "run=true ids=one-entry two-entry" "$(decide pull_request)"
check "a push runs every entry whatever the decider says" "run=true ids=all" "$(decide push)"
repo $'#!/usr/bin/env bash\nexit 0'
check "a decision that names nothing skips the sweep" "run=false ids=" "$(decide pull_request)"
check "and says so in the summary" "1" "$(grep -c 'the sweep is not needed' "$WORK/summary")"
repo -
check "a base without the decider runs every entry" "run=true ids=all" "$(decide pull_request)"
repo $'#!/usr/bin/env bash\necho one-entry; exit 3'
check "a decider that fails runs every entry" "run=true ids=all" "$(decide pull_request)"
repo $'#!/usr/bin/env bash\necho "one-entry; rm -rf /"'
check "a decision that is not a list of ids runs every entry" "run=true ids=all" "$(decide pull_request)"

# --- the gate -----------------------------------------------------------------------
GATE="Tell a sweep that was not needed from one that did not run"
gate() { # <workflow> <decide result> <run> <sweep result> -> rc
	step "$1" gate "$GATE" > "$WORK/gate.sh"
	DECIDE="$2" RUN="$3" SWEEP="$4" bash "$WORK/gate.sh" > "$WORK/gate.out" 2>&1
}
rc=0; gate "$WF" success false skipped || rc=$?
check "a sweep skipped by the decision passes the gate" "0" "$rc"
rc=0; gate "$WF" success true success || rc=$?
check "a sweep that ran and passed passes the gate" "0" "$rc"
rc=0; gate "$WF" success true failure || rc=$?
check "a sweep that found a survivor fails the gate" "1" "$rc"
rc=0; gate "$WF" success true skipped || rc=$?
check "a sweep that was needed and skipped fails the gate" "1" "$rc"
rc=0; gate "$WF" success true cancelled || rc=$?
check "a cancelled sweep fails the gate" "1" "$rc"
rc=0; gate "$WF" success false success || rc=$?
check "a sweep that ran though it was not needed is not read as a pass" "1" "$rc"
rc=0; gate "$WF" failure "" skipped || rc=$?
check "a failed decision fails the gate though the sweep reports skipped" "1" "$rc"
check "and says the decision did not succeed" "1" "$(grep -c 'the decision ended failure' "$WORK/gate.out")"
rc=0; gate "$WF" skipped "" skipped || rc=$?
check "a skipped decision fails the gate" "1" "$rc"

# --- the controls: each refusal of the gate is the line that refuses ------------------
python3 -I - "$WF" "$WORK/no-decide-check.yml" <<'PY'
import sys
text = open(sys.argv[1]).read()
old = '          if [ "$DECIDE" != success ]; then\n'
assert text.count(old) == 1
open(sys.argv[2], "w").write(text.replace(old, '          if false; then\n'))
PY
rc=0; gate "$WORK/no-decide-check.yml" failure false skipped || rc=$?
check "without the decision check, a failed decision that left run=false passes (that check is the refusal)" "0" "$rc"
python3 -I - "$WF" "$WORK/no-pairs.yml" <<'PY'
import sys
text = open(sys.argv[1]).read()
old = '            *)\n              echo "::error::the decision said run=$RUN and the sweep ended $SWEEP"\n              exit 1\n'
assert text.count(old) == 1
open(sys.argv[2], "w").write(text.replace(old, '            *)\n              :\n'))
PY
rc=0; gate "$WORK/no-pairs.yml" success true skipped || rc=$?
check "without the pairing, a needed sweep that was skipped passes (the pairing is the refusal)" "0" "$rc"


# --- the scheduled sweep is split by file of the catalogue, and each fragment is bound over what it costs ---
#
# a fragment, and each fragment has a time bound that covers what it measured.
#
# GitHub reports a job that exceeds its `timeout-minutes` as `cancelled`, and a cancelled run is not
# a success, so the freshness watcher of the sweep cannot count it. That is how the scheduled run of
# 2026-11-23 failed in two channels: the bound had been written for a catalogue a third of the size,
# and nothing said so until the cron had fired once and been cut. The grace period of a new cron ends
# with its first run, successful or not, so the failure cost the whole fortnight. This holds, in the
# pull request that causes it and not in the cron a week later:
#
#   * every file of the catalogue (catalog.txt and each catalog.d/*.txt) is one fragment of the
#     matrix of the sweep, once, and no fragment names a file that is not there, so no entry is left
#     outside every fragment, and the entries of the fragments add up to the whole catalogue;
#   * the matrix does not stop the other fragments when one fails, and the bound of each job is the
#     one its fragment names;
#   * the file tests/mutation/sweep-durations.txt has a line for each fragment, with the entries it
#     had when it was measured and the seconds it took on a runner, and the bound of the fragment is
#     at least that time, scaled to the entries the fragment has now, with a half on top. A catalogue
#     that grows past the bound fails here and names the bound it needs.
#
# Every case is planted first, so a checker that read nothing would not pass them.
# Requires: bash, python3 with PyYAML.
# What the checker printed and how it ended decide the verdict together: one that dies half way through
# prints some `ok` lines and no `FAIL`, so its status, its line about the live sweep and its summary count too.
sweep_failures() { # <status> <output> -> how many failures to count
	local status="$1" out="$2" bad
	bad="$(printf '%s\n' "$out" | grep -c '^FAIL')"
	if [ "$bad" -eq 0 ]; then
		[ "$status" -eq 0 ] || bad=1
		printf '%s\n' "$out" | grep -q '^ok    the live sweep is split' || bad=1
		printf '%s\n' "$out" | grep -qE '^[0-9]+ passed, [0-9]+ failed$' || bad=1
	fi
	printf '%s' "$bad"
}
check "a checker that dies after its first ok line is a failure" "1" "$(sweep_failures 1 'ok    the first case')"
check "one that ends well but never reached the live sweep is a failure" "1" "$(sweep_failures 0 $'ok    the first case\n1 passed, 0 failed')"
check "one that ends well and never printed its summary is a failure" "1" "$(sweep_failures 0 'ok    the live sweep is split, covers the catalogue and is bound over what it measured')"
check "one that ends well, reached the live sweep and printed its summary is none" "0" "$(sweep_failures 0 $'ok    the live sweep is split\n2 passed, 0 failed')"
check "a line that says FAIL is counted as it is, whatever the status" "1" "$(sweep_failures 0 $'FAIL  a case\n0 passed, 1 failed')"
rc=0
sweep="$(python3 -I - "$HERE" <<'PY'
import re
import sys
import tempfile
from pathlib import Path

import yaml

root = Path(sys.argv[1])
passed = failed = 0
MARGIN = 1.5


def files_of(repo):
    found = [repo / "tests/mutation/catalog.txt"] if (repo / "tests/mutation/catalog.txt").exists() else []
    found += sorted((repo / "tests/mutation/catalog.d").glob("*.txt")) if (repo / "tests/mutation/catalog.d").is_dir() else []
    return [str(f.relative_to(repo)) for f in found]


def entries(repo, rel):
    return sum(1 for line in (repo / rel).read_text().splitlines() if line.strip() and not line.startswith("#"))


def problems(repo):
    found = []
    spec = yaml.safe_load((repo / ".github/workflows/mutation.yml").read_text()) or {}
    jobs = [(n, j) for n, j in (spec.get("jobs") or {}).items()
            if any("run-mutations.sh" in str(s.get("run", "")) for s in j.get("steps") or [])]
    if len(jobs) != 1:
        return [f"{len(jobs)} jobs of mutation.yml run run-mutations.sh, and the fragments can only be read from one"]
    name, job = jobs[0]
    strategy = job.get("strategy") or {}
    include = (strategy.get("matrix") or {}).get("include") or []
    if strategy.get("fail-fast") is not False:
        found.append(f"job `{name}` does not say `fail-fast: false`, so one fragment that fails would stop the others")
    if job.get("timeout-minutes") != "${{ matrix.minutes }}":
        found.append(f"job `{name}` is not bound by the minutes its fragment names")
    declared = [e.get("fragment") for e in include]
    live = files_of(repo)
    for rel in live:
        if declared.count(rel) == 0:
            found.append(f"{rel} is in no fragment of the sweep, so its entries are never run")
    for rel in sorted(set(declared)):
        if rel not in live:
            found.append(f"the sweep names the fragment {rel}, which is not a file of the catalogue")
        elif declared.count(rel) > 1:
            found.append(f"the fragment {rel} is listed {declared.count(rel)} times")
    measured = {}
    data = repo / "tests/mutation/sweep-durations.txt"
    for line in data.read_text().splitlines() if data.exists() else []:
        if line.strip() and not line.startswith("#"):
            cols = line.split("\t")
            if len(cols) != 4 or not re.fullmatch(r"[0-9]+", cols[1]) or not re.fullmatch(r"[0-9]+", cols[2]) or int(cols[1]) == 0:
                found.append(f"the line `{line}` of sweep-durations.txt is not <file>, <entries>, <seconds>, <source>")
            else:
                measured[cols[0]] = (int(cols[1]), int(cols[2]))
    total = 0
    counted = set()
    for e in include:
        rel = e.get("fragment")
        if rel not in live:
            continue
        now = entries(repo, rel)
        if rel not in counted:
            total += now
            counted.add(rel)
        if rel not in measured:
            found.append(f"{rel} has no measured duration in sweep-durations.txt")
            continue
        was, secs = measured[rel]
        need = secs * now / was * MARGIN / 60
        minutes = e.get("minutes")
        if not isinstance(minutes, int):
            found.append(f"the fragment {rel} names no minutes")
        elif minutes < need:
            found.append(f"the fragment {rel} is bound at {minutes} minutes and needs {int(need) + 1} for its {now} entries")
    for rel in sorted(set(measured) - set(live)):
        found.append(f"sweep-durations.txt measures {rel}, which is not a file of the catalogue")
    if declared and set(declared) >= set(live) and total != sum(entries(repo, r) for r in live):
        found.append("the entries of the fragments do not add up to the catalogue")
    return found


def plant(catalogs, workflow_include, durations, fail_fast=False, timeout="${{ matrix.minutes }}"):
    with tempfile.TemporaryDirectory() as d:
        repo = Path(d)
        (repo / "tests/mutation/catalog.d").mkdir(parents=True)
        (repo / ".github/workflows").mkdir(parents=True)
        for rel, n in catalogs.items():
            (repo / rel).write_text("# c\n\n" + "".join(f"{rel.replace('/', '-')}{i}\ta\tb\tc\td\n" for i in range(n)))
        incl = "".join(f"          - fragment: {f}\n            minutes: {m}\n" for f, m in workflow_include)
        ff = "" if fail_fast is None else f"      fail-fast: {str(fail_fast).lower()}\n"
        (repo / ".github/workflows/mutation.yml").write_text(
            "on:\n  schedule:\n    - cron: '0 0 * * 1'\njobs:\n  sweep:\n    runs-on: x\n"
            f"    timeout-minutes: {timeout}\n    strategy:\n{ff}      matrix:\n        include:\n{incl}"
            "    steps:\n      - run: bash ./tests/mutation/run-mutations.sh --catalog \"$FRAGMENT\"\n")
        (repo / "tests/mutation/sweep-durations.txt").write_text("# header\n" + "".join(f"{f}\t{n}\t{s}\tplanted\n" for f, n, s in durations))
        return problems(repo)


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        print(f"ok    {label}")
        passed += 1
    else:
        print(f"FAIL  {label}\n        expected: {expected}\n        actual:   {actual}")
        failed += 1


A, B = "tests/mutation/catalog.txt", "tests/mutation/catalog.d/x.txt"
cat = {A: 60, B: 20}
inc = [(A, 30), (B, 10)]
dur = [(A, 60, 600), (B, 20, 100)]
check("fragments that cover the catalogue, each with a bound over its measure, pass", [], plant(cat, inc, dur))
check("a file of the catalogue that no fragment names is refused", [f"{B} is in no fragment of the sweep, so its entries are never run"], plant(cat, [(A, 30)], dur))
check("a fragment that names a file that is not there is refused", [f"the sweep names the fragment tests/mutation/catalog.d/gone.txt, which is not a file of the catalogue"],
      [p for p in plant(cat, inc + [("tests/mutation/catalog.d/gone.txt", 10)], dur) if "not a file" in p and "names the fragment" in p])
check("a fragment listed twice is refused", [f"the fragment {A} is listed 2 times"], plant(cat, inc + [(A, 30)], dur))
check("a bound under the measure scaled to the entries is refused", [f"the fragment {A} is bound at 14 minutes and needs 16 for its 60 entries"],
      plant(cat, [(A, 14), (B, 10)], dur))
check("a catalogue that grew past its bound is refused naming the bound it needs", [f"the fragment {A} is bound at 30 minutes and needs 46 for its 180 entries"], plant({A: 180, B: 20}, inc, dur))
check("and the bound it names is enough", [], plant({A: 180, B: 20}, [(A, 46), (B, 10)], dur))
check("a fragment with no measured duration is refused", [f"{B} has no measured duration in sweep-durations.txt"], plant(cat, inc, dur[:1]))
check("a measured duration of a file that is gone is refused", [f"sweep-durations.txt measures tests/mutation/catalog.d/gone.txt, which is not a file of the catalogue"],
      plant(cat, inc, dur + [("tests/mutation/catalog.d/gone.txt", 5, 50)]))
check("a matrix that stops the others when one fails is refused", ["job `sweep` does not say `fail-fast: false`, so one fragment that fails would stop the others"],
      plant(cat, inc, dur, fail_fast=None))
check("a job bound by a fixed number and not by its fragment is refused", ["job `sweep` is not bound by the minutes its fragment names"],
      plant(cat, inc, dur, timeout="90"))
check("a line of the durations with no entries is refused", ["the line `x\t0\t5\tplanted` of sweep-durations.txt is not <file>, <entries>, <seconds>, <source>"], plant(cat, inc, dur + [("x", 0, 5)]))
check("the live sweep is split, covers the catalogue and is bound over what it measured", [], problems(root))
print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
)" || rc=$?
printf '%s\n' "$sweep" | grep -E '^(ok|FAIL|        )'
pass=$((pass + $(printf '%s\n' "$sweep" | grep -c '^ok')))
bad="$(sweep_failures "$rc" "$sweep")"
if [ "$bad" -gt 0 ] && ! printf '%s\n' "$sweep" | grep -q '^FAIL'; then
	echo "FAIL  the check of the sweep did not finish: status $rc, and it did not print what a finished one prints"
fi
fail=$((fail + bad))

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
