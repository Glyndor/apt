#!/usr/bin/env bash
#
# The helpers of the suites of scripts/quality/lint/check-test-job-not-switchable.sh
# that read every job and step of every workflow. Sourced, never run, and not
# named *.test.sh because it is not a suite. The suite that sources it names
# HERE, the root of the repository.
#
# What it gives: the counters and `check`, a scratch directory, a tree builder
# and a runner of the rule (`new`, `run_in`, `said`), `plant`, which plants a
# switch in the real workflows and runs the rule on the copy, and the helpers of
# the cases that need a base commit (`base_repo`, `change`, `verdict`).
#
# The suites are split by what they hold, each small enough to run in a few
# seconds, because the mutation sweep runs the suite an entry names once per
# entry: a slow suite with many entries is what sinks the sweep.
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2034 # the suites that source this read what it sets

SCRIPT="$HERE/scripts/quality/lint/check-test-job-not-switchable.sh"
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

finish() {
	echo "$pass passed, $fail failed"
	printf 'DONE %s %d %d\n' "${BASH_SOURCE[1]##*/}" "$pass" "$fail"
	[ "$fail" -eq 0 ]
}

new() { rm -rf "$WORK/t"; mkdir -p "$WORK/t/.github/workflows"; printf '%s' "$WORK/t"; }
run_in() { ( cd "$1" && bash "$SCRIPT" 2>&1 ); }
said() { printf '%s' "$1" | grep -q -F -- "$2" && echo 1 || echo 0; }

# A workflow written into a tree built by `new`, and the sound caller of
# reusable-shell-ci every such tree carries so that the one defect in it is the
# one the case plants.
workflow() { # $1=dir $2=file $3=body
	printf '%s\n' "$3" > "$1/.github/workflows/$2"
}
sound() { cp "$HERE/.github/workflows/tests.yml" "$1/.github/workflows/"; }

# The planter. It copies the workflows of this repository, changes the ones the
# case names, runs the rule on the copy and prints one line per assertion:
# description, expected value, actual value, separated by TAB.
#   plant <file|all> <kind> [job] [step]
# kinds: if, needs, coe (continue-on-error) on the job; step-if and step-coe on
# every step of the job. Without a job, every job of the file is planted at once.
plant() {
	python3 -I - "$HERE" "$SCRIPT" "$WORK" "$@" <<'PY'
import os, shutil, subprocess, sys, yaml

LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
DUMPER = getattr(yaml, "CSafeDumper", yaml.SafeDumper)

here, script, work, which, kind = sys.argv[1:6]
only_job = sys.argv[6] if len(sys.argv) > 6 else ""
only_step = sys.argv[7] if len(sys.argv) > 7 else ""
source = os.path.join(here, ".github/workflows")
names = sorted(n for n in os.listdir(source) if n.endswith((".yml", ".yaml")))
if which != "all":
    names = [which]
for name in names:
    # The rule needs one sound caller and the file under test, and reads nothing else.
    dest = os.path.join(work, "plant")
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(os.path.join(dest, ".github/workflows"))
    for keep in {name, "tests.yml"}:
        shutil.copy(os.path.join(source, keep), os.path.join(dest, ".github/workflows", keep))
    rel = ".github/workflows/" + name
    doc = yaml.load(open(os.path.join(source, name)), Loader=LOADER)
    expected = []
    for job_id, job in doc["jobs"].items():
        if only_job and job_id != only_job:
            continue
        uses = job.get("uses") or ""
        local = uses.rsplit("/", 1)[-1] if uses.startswith("./.github/workflows/reusable-") else ""
        who = f"job `{job_id}` in {rel}" + (f" calls `{local}` and" if local else "")
        if kind == "if":
            job["if"] = False
            expected.append((job_id, f"{who} carries a job-level `if:`"))
        elif kind == "needs":
            job["needs"] = "no-such-job"
            expected.append((job_id, f"{who} carries `needs:`"))
        elif kind == "coe":
            job["continue-on-error"] = True
            expected.append((job_id, f"{who} carries `continue-on-error:`"))
        else:
            for number, step in enumerate(job.get("steps") or [], 1):
                label = step.get("name") or step.get("id") or str(step.get("uses") or "").split("@")[0] or f"number {number}"
                if only_step and label != only_step:
                    continue
                key, text = ("if", "an `if:`") if kind == "step-if" else ("continue-on-error", "`continue-on-error:`")
                step[key] = False if key == "if" else True
                expected.append((job_id, f"step `{label}` of job `{job_id}` in {rel} carries {text}"))
    if not expected:
        continue
    with open(os.path.join(dest, rel), "w") as out:
        yaml.dump(doc, out, Dumper=DUMPER)
    done = subprocess.run(["bash", script], cwd=dest, capture_output=True, text=True)
    said = done.stdout + done.stderr
    print(f"{name}: planting {kind} is refused\t1\t{done.returncode}")
    for job_id, needle in expected:
        print(f"{name}: {job_id}: {needle}\t1\t{1 if needle in said else 0}")
PY
}

assert_planted() { # same arguments as plant
	local desc expected actual
	while IFS=$'\t' read -r desc expected actual; do
		check "$desc" "$expected" "$actual"
	done < <(plant "$@")
}

G="$WORK/g"
gitg() { git -C "$G" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
run_base() { ( cd "$1" && BASE_SHA="$2" bash "${3:-$SCRIPT}" 2>&1 ); }

# A job with a step that writes an output and a job that reads it, as
# freshness.yml has them: the lists name both.
SCOPE_FILE=$'name: Freshness\non: pull_request\njobs:\n  scope:\n    if: github.event_name == \'pull_request\'\n    runs-on: ubuntu-latest\n    outputs:\n      suite: ${{ steps.scope.outputs.suite }}\n    steps:\n      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1\n      - id: scope\n        run: echo "suite=true" >> "$GITHUB_OUTPUT"\n  suite-on-main:\n    needs: scope\n    if: ${{ !cancelled() && needs.scope.outputs.suite != \'false\' }}\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
base_repo() { # the real callers and reusables, and the file above, as the base commit
	rm -rf "$G"; mkdir -p "$G/.github/workflows"; gitg init -q -b main
	cp "$HERE"/.github/workflows/*.yml "$G/.github/workflows/"
	printf '%s' "$SCOPE_FILE" > "$G/.github/workflows/freshness.yml"
	gitg add -A; gitg commit -qm base; BASE="$(gitg rev-parse HEAD)"
}
# The pull request changes a step or a job of a workflow the way the expression says.
# `doc` is the parsed file, `job` the named job: change it in place.
change() { # $1=file $2=python statements acting on doc
	python3 -I - "$G/.github/workflows/$1" "$2" <<'PY'
import sys, yaml
doc = yaml.load(open(sys.argv[1]), Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader))
exec(sys.argv[2])
yaml.dump(doc, open(sys.argv[1], "w"), Dumper=getattr(yaml, "CSafeDumper", yaml.SafeDumper))
PY
}
verdict() { # $1=description $2=expected status
	out="$(run_base "$G" "$BASE")"; rc=$?
	check "$1" "$2" "$rc"
}
SHELL_CI=reusable-shell-ci.yml
SCOPE_STEP='[s for s in doc["jobs"]["test"]["steps"] if s.get("id") == "scope"][0]'
