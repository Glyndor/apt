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

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
