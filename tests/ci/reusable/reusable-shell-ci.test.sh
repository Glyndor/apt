#!/usr/bin/env bash
# Behaviour tests for the shellcheck job in
# .github/workflows/reusable-shell-ci.yml.
#
# The collection step decides what gets linted, and everything it fails to
# collect is a file the gate reports success on without opening. That is the
# failure this repository already hit once, so the cases below are about what
# the collector finds rather than about shellcheck itself.
#
# Requires: python3, git, shellcheck.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

# Pull one step's `run:` body out of a workflow, dedented, so it can be run.
# Same helper as tests/publication/update/update-workflow.test.sh in the tap and the bucket: the point is to exercise the
# shell as it ships rather than a copy of it that can drift.
step_script() { # $1=workflow path  $2=step name substring
	python3 - "$1" "$2" <<'PY'
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

WORKFLOW="$HERE/.github/workflows/reusable-shell-ci.yml"
step_script "$WORKFLOW" "Collect shell scripts" > "$WORK/collect.sh"
step_script "$WORKFLOW" "Run shellcheck" > "$WORK/lint.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "FAIL  shellcheck is not on PATH; these tests cannot run" >&2
	exit 1
fi

# $RUNNER_TEMP is where the collector writes its file list on a runner.
run_both() { # $1=dir -> collector then linter, in that directory
	local tmp="$WORK/rt"
	rm -rf "$tmp"; mkdir -p "$tmp"
	( cd "$1" && RUNNER_TEMP="$tmp" bash "$WORK/collect.sh" \
		&& RUNNER_TEMP="$tmp" SEVERITY=style bash "$WORK/lint.sh" ) 2>&1
}

collected() { # $1=dir -> how many files the collector picked up
	local tmp="$WORK/rt2"
	rm -rf "$tmp"; mkdir -p "$tmp"
	( cd "$1" && RUNNER_TEMP="$tmp" bash "$WORK/collect.sh" ) >/dev/null 2>&1
	tr -cd '\0' < "$tmp/shell-files" | wc -c
}

new() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; printf '%s' "$WORK/t"; }

# --- a violation in a .sh must be reported -------------------------------

d="$(new)"
# The single quotes are the point: the fixture must contain a literal
# `$UNQUOTED` for shellcheck to complain about when it lints the file,
# not this test's expansion of it.
# shellcheck disable=SC2016
printf '#!/bin/sh\nrm -rf $UNQUOTED/*\n' > "$d/bad.sh"
# xargs reports 123 when a command it ran failed, so the job's exit is 123
# rather than shellcheck's own 1. What the gate promises is a red job, so
# that is what is asserted; pinning the exact number would make this test
# fail the day the runner is changed to loop instead of using xargs.
out="$(run_both "$d")"; rc=$?
check "a violation in a .sh fails" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and names the rule" "1" \
	"$(printf '%s' "$out" | grep -q 'SC2115' && echo 1 || echo 0)"

# --- an extensionless script is found by its shebang ---------------------
#
# This is the half of the collector that has no extension to go on, so a
# regression here is invisible: the file is simply never opened.

d="$(new)"
# The single quotes are the point: the fixture must contain a literal
# `$UNQUOTED` for shellcheck to complain about when it lints the file,
# not this test's expansion of it.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nrm -rf $UNQUOTED/*\n' > "$d/hook"
chmod +x "$d/hook"
check "an extensionless script with a shell shebang is collected" "1" "$(collected "$d")"
out="$(run_both "$d")"; rc=$?
check "and its violation fails the job" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# --- a shebang that is not a shell is left alone -------------------------

d="$(new)"
printf '#!/usr/bin/env python3\nimport os\n' > "$d/tool"
chmod +x "$d/tool"
check "a python shebang is not collected" "0" "$(collected "$d")"

# --- clean input passes --------------------------------------------------

d="$(new)"
printf '#!/bin/sh\nset -eu\necho "hello"\n' > "$d/good.sh"
out="$(run_both "$d")"; rc=$?
check "a clean script passes" "0" "$rc"
check "and it was actually collected, not skipped into a pass" "1" "$(collected "$d")"

# --- nothing to lint is not a failure, but must collect nothing ----------

d="$(new)"
printf 'plain text\n' > "$d/notes.txt"
check "a tree with no shell collects nothing" "0" "$(collected "$d")"

# ===========================================================================
# Scripts invoked by path must be executable in git
# ===========================================================================
#
# The mode that travels is git's, not the disk's. A script committed at
# 100644 dies on the runner with exit 126, and because the suite chains with
# `&&` the failure reads as "the tests fail". The step catches that before
# the push; it had no test of its own.
step_script "$WORKFLOW" "Scripts invoked by path must be executable" > "$WORK/exec.sh"
check "the exec-bit step was extracted from the workflow" "1" \
	"$(grep -c '100755' "$WORK/exec.sh" | awk '{print ($1>0)}')"

xrepo() { # -> a git repo whose workflow invokes ./scripts/x.sh, x.sh tracked at $1
	rm -rf "$WORK/x"; mkdir -p "$WORK/x/.github/workflows" "$WORK/x/scripts"
	git init -q "$WORK/x"
	git -C "$WORK/x" config user.email t@example.invalid
	git -C "$WORK/x" config user.name t
	printf 'jobs:\n  t:\n    steps:\n      - run: ./scripts/x.sh\n' > "$WORK/x/.github/workflows/w.yml"
	printf '#!/bin/sh\ntrue\n' > "$WORK/x/scripts/x.sh"
	git -C "$WORK/x" add -A
	[ "$1" = "100755" ] && git -C "$WORK/x" update-index --chmod=+x scripts/x.sh
	git -C "$WORK/x" commit -qm fixture
	printf '%s' "$WORK/x"
}
run_exec() { ( cd "$1" && bash "$WORK/exec.sh" 2>&1 ); }

d="$(xrepo 100644)"
out="$(run_exec "$d")"; rc=$?
check "a script invoked as ./path and tracked at 100644 fails" "1" "$rc"
check "and it is refused for the mode, with the fix" "1" \
	"$(printf '%s' "$out" | grep -q 'git update-index --chmod=+x scripts/x.sh' && echo 1 || echo 0)"

d="$(xrepo 100755)"
out="$(run_exec "$d")"; rc=$?
check "the same script tracked at 100755 passes" "0" "$rc"
check "and was actually checked, not skipped" "1" \
	"$(printf '%s' "$out" | grep -q 'Every script invoked by path is executable' && echo 1 || echo 0)"

d="$(xrepo 100755)"; git -C "$d" rm -q --cached scripts/x.sh; git -C "$d" commit -qm untrack
out="$(run_exec "$d")"; rc=$?
check "an untracked script is noted and skipped rather than failed" "0" "$rc"
check "and the note says so" "1" "$(printf '%s' "$out" | grep -q 'is not tracked; skipping' && echo 1 || echo 0)"

d="$(xrepo 100644)"; printf 'jobs:\n  t:\n    steps:\n      - run: bash scripts/x.sh\n' > "$d/.github/workflows/w.yml"
out="$(run_exec "$d")"; rc=$?
check "a script invoked through an interpreter is not held to the rule" "0" "$rc"
check "and the step says there was nothing to check" "1" \
	"$(printf '%s' "$out" | grep -q 'nothing to check' && echo 1 || echo 0)"

# ===========================================================================
# Run tests
# ===========================================================================
#
# The test job shells out to the caller's test-command. Without errexit in
# the child, the child's exit code is the LAST suite's, so an early failing
# suite leaves the required `shell / test` check green: the same failure
# the literal-block-scalar guard in workflow-lint exists to refuse. The
# child here passes `-e -o pipefail` to bash so the first failing statement
# exits the job even when a later statement would succeed.
step_script "$WORKFLOW" "Run tests" > "$WORK/run-tests.sh"
check "the run-tests step was extracted from the workflow" "1" \
	"$(grep -c 'TEST_COMMAND' "$WORK/run-tests.sh" | awk '{print ($1>0)}')"

# Two commands on two lines, the first `false`, the second `true`. The newlines
# match what a literal block scalar (`|`) in YAML hands bash, so the case
# exercises the same shell path the guard refuses at the workflow level.
# `false` writes nothing, so the only observable signal is the exit code.
out="$(TEST_COMMAND=$'false\ntrue' bash "$WORK/run-tests.sh" 2>&1)"; rc=$?
check "an early failing statement fails the test step even when a later one passes" "1" \
	"$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# A pull request that changes no lint inputs skips the shellcheck job's
# work, but the job and its check still report. Every step of that job after
# the decision carries the condition; one that does not would run (and bill)
# regardless, and the decision step itself must exist.
shellcheck_gate="$(python3 - "$WORKFLOW" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["shellcheck"]["steps"]
names = [s.get("name", "") for s in steps]
idx = next((i for i, s in enumerate(steps) if s.get("id") == "scope"), None)
if idx is None:
    print("no scope step"); sys.exit(0)
bare = [s.get("name") for s in steps[idx + 1:] if "steps.scope.outputs.needed" not in str(s.get("if", ""))]
print("ok" if not bare else "unguarded: " + ", ".join(bare))
PY
)"
check "the shellcheck job decides whether its work is needed and guards every later step" "ok" "$shellcheck_gate"
# Exercise the actual install body with a recording sudo, never the host's apt.
# The resolver, suite map and dependency map live in real BASE commit objects.
step_script "$WORKFLOW" "Install test dependencies" > "$WORK/install.sh"
mkdir -p "$WORK/bin" "$WORK/rt-packages"
cat > "$WORK/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APT_LOG"
STUB
chmod +x "$WORK/bin/sudo"
FULL_PACKAGES='python3-cryptography reprepro shellcheck python3-yaml'
RUNNER=tests/ci/suites/check-suite-completeness.test.sh
EDITOR=tests/quality/check-editorconfig.test.sh
BUILD=tests/build/build-repo.test.sh
OTHER=tests/quality/check-action-pins.test.sh
COMMAND="./$RUNNER ./$EDITOR ./$BUILD ./$OTHER"
package_repo() {
	R="$WORK/packages"
	rm -rf "$R"; mkdir -p "$R/scripts/quality" "$R/tests/ci/suites"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid
	git -C "$R" config commit.gpgsign false
	cp "$HERE/scripts/quality/ci-job-scope.sh" "$R/scripts/quality/"
	cp "$HERE/scripts/quality/suite-dependencies.txt" "$R/scripts/quality/"
	cp "$HERE/$RUNNER" "$R/$RUNNER"
	printf '%s\n\t**\n%s\n\tarchive.txt\n%s\n\tother.txt\n' \
		"$EDITOR" "$BUILD" "$OTHER" > "$R/scripts/quality/suite-scope.txt"
	if [ "${1:-}" = real ]; then
		cp "$HERE/scripts/quality/suite-scope.txt" "$R/scripts/quality/"
	fi
	printf 'base\n' > "$R/docs.md"; printf 'archive\n' > "$R/archive.txt"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -qb pr
}
package_merge() {
	git -C "$R" add -A; git -C "$R" commit -qm change
	git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff pr -m merge
}
install_packages() {
	: > "$WORK/apt.log"
	( cd "$R" && PATH="$WORK/bin:$PATH" APT_LOG="$WORK/apt.log" \
		RUNNER_TEMP="$WORK/rt-packages" EVENT="${1:-pull_request}" \
		TEST_COMMAND="${2:-$COMMAND}" APT_PACKAGES="$FULL_PACKAGES" \
		bash "$WORK/install.sh" ) > "$WORK/install.out" 2>&1
	local status=$?
	if [ "$status" -ne 0 ]; then
		cat "$WORK/install.out"; echo "install step failed: $status"
	else
		cat "$WORK/apt.log"
	fi
}
FULL_INSTALL=$(printf 'apt-get update -qq\napt-get install -y -qq %s' "$FULL_PACKAGES")
package_repo real; echo more >> "$R/docs.md"; package_merge
REAL_COMMAND="$(python3 - "$HERE/.github/workflows/tests.yml" <<'PYCOMMAND'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))['jobs']['shell']['with']['test-command'])
PYCOMMAND
)"
check "docs-only PR with the real suite list and scope map installs nothing" "" \
	"$(install_packages pull_request "$REAL_COMMAND")"
package_repo; echo more >> "$R/docs.md"; package_merge
check "docs-only PR does not invoke apt at all (including reprepro)" "" "$(install_packages)"
check "push installs the complete caller list" "$FULL_INSTALL" "$(install_packages push)"
check "schedule installs the complete caller list" "$FULL_INSTALL" "$(install_packages schedule)"
check "unsupported command installs everything" "$FULL_INSTALL" "$(install_packages pull_request 'true')"
check "compound command installs everything" "$FULL_INSTALL" "$(install_packages pull_request "$COMMAND && true")"
check "multiline command installs everything" "$FULL_INSTALL" "$(install_packages pull_request "$COMMAND"$'\ntrue')"
# A PR cannot use its checkout's dependency map to override BASE.
printf '%s reprepro\n' "$EDITOR" > "$R/scripts/quality/suite-dependencies.txt"
check "checkout dependency map is ignored" "" "$(install_packages)"
git -C "$R" checkout -- scripts/quality/suite-dependencies.txt
echo '# changed' >> "$R/$RUNNER"
check "changed runner installs everything as it would run every suite" "$FULL_INSTALL" "$(install_packages)"

package_repo; echo more >> "$R/archive.txt"; package_merge
check "suite requiring reprepro installs exactly reprepro before running" \
	$'apt-get update -qq\napt-get install -y -qq reprepro' "$(install_packages)"

package_repo; echo '# changed in PR' >> "$R/scripts/quality/suite-dependencies.txt"; package_merge
check "committed dependency-policy change installs everything" "$FULL_INSTALL" "$(install_packages)"

# Each defect is in BASE: the workflow must keep the full list when the
# classifier fails, returns garbage/empty, or cannot supply the needed policy.
for defect in failed empty unknown old empty-suites unknown-suites missing-map malformed-map duplicate-map unknown-package unmapped-suite missing-scope bad-scope; do
	package_repo
	case "$defect" in
		failed) printf '#!/bin/bash\nexit 1\n' > "$R/scripts/quality/ci-job-scope.sh" ;;
		empty) printf '#!/bin/bash\nexit 0\n' > "$R/scripts/quality/ci-job-scope.sh" ;;
		unknown) printf '#!/bin/bash\necho garbage\n' > "$R/scripts/quality/ci-job-scope.sh" ;;
		old) printf '#!/bin/bash\necho true\n' > "$R/scripts/quality/ci-job-scope.sh" ;;
		empty-suites) sed -i 's/for name in suites(.*):/for name in []:/' "$R/scripts/quality/ci-job-scope.sh" ;;
		unknown-suites) sed -i 's/for name in suites(.*):/for name in ["tests\/unknown.test.sh"]:/' "$R/scripts/quality/ci-job-scope.sh" ;;
		missing-map) rm "$R/scripts/quality/suite-dependencies.txt" ;;
		malformed-map) printf '%s\n' "$EDITOR" > "$R/scripts/quality/suite-dependencies.txt" ;;
		duplicate-map) printf '%s -\n' "$EDITOR" >> "$R/scripts/quality/suite-dependencies.txt" ;;
		unknown-package) printf '%s imaginary-package\n' "$EDITOR" > "$R/scripts/quality/suite-dependencies.txt" ;;
		unmapped-suite) sed -i "\|^$EDITOR |d" "$R/scripts/quality/suite-dependencies.txt" ;;
		missing-scope) rm "$R/scripts/quality/suite-scope.txt" ;;
		bad-scope) printf '%s\n' "$EDITOR" > "$R/scripts/quality/suite-scope.txt" ;;
	esac
	git -C "$R" add -A; git -C "$R" commit -qm "$defect"
	git -C "$R" checkout -q main; git -C "$R" merge -q --ff-only pr
	git -C "$R" checkout -qb change
	echo more >> "$R/docs.md"; package_merge
	check "$defect decision installs every dependency" "$FULL_INSTALL" "$(install_packages)"
done

package_repo; echo more >> "$R/docs.md"
git -C "$R" add -A; git -C "$R" commit -qm 'branch head, not merge'
check "non-merge checkout installs everything" "$FULL_INSTALL" "$(install_packages)"
package_repo; git -C "$R" commit -qm empty --allow-empty
git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff pr -m merge
check "empty diff installs everything" "$FULL_INSTALL" "$(install_packages)"
package_repo; echo more >> "$R/docs.md"; package_merge
parent=$(git -C "$R" rev-parse HEAD^1)
rm "$R/.git/objects/${parent:0:2}/${parent:2}"
check "unreadable base installs everything" "$FULL_INSTALL" "$(install_packages)"
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
