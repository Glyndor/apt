#!/usr/bin/env bash
# The producer decides with code of the base commit: one that runs a script
# of the repository from the checkout of a pull request is refused.
#
# A producer that writes an output a condition reads and runs a script from the
# checkout of a pull request lets the pull request write what the script prints.
# It reads the script from the base commit with `git show HEAD^1:<path>`, into
# a temporary file, and runs that. The rule needs no base commit for this; it
# looks at the workflows a pull request can run.
#
# Every refusal asserts which refusal, and every refusal is paired with the
# acceptance of the same tree before the switch was planted.
#
# Requires: python3 with PyYAML.
# The fixtures are printf templates and carry backticks the assertions read.
# shellcheck disable=SC2016,SC2059
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC1091 # the fixture of the suites of this rule
. "$HERE/tests/fixtures/ci/switchable-rule.sh"

# --- the producer decides with code of the base commit -----------------------
nobase() { out="$(cd "$G" && env -u BASE_SHA bash "$SCRIPT" 2>&1)"; rc=$?; check "$1" "$2" "$rc"; }
base_repo
nobase "the scope step that reads its script from the base commit is accepted with no base named" 0
change freshness.yml "doc['jobs']['scope']['steps'][1]['run'] = 'git show HEAD^1:scripts/s.sh > \"\$RUNNER_TEMP/s\"; bash \"\$RUNNER_TEMP/s\" >> \"\$GITHUB_OUTPUT\"'"
nobase "and so is one that runs what it took from the base with git show" 0
change freshness.yml "doc['jobs']['scope']['steps'][1]['run'] = 'bash ./scripts/scope.sh >> \"\$GITHUB_OUTPUT\"'"
nobase "a scope step that runs a script of the repository from the checkout is refused with no base named" 1
check "and the refusal says the pull request writes it, naming the job and the file" "1" \
	"$(said "$out" 'job `scope` in .github/workflows/freshness.yml writes outputs a condition reads and runs a script of the repository from the checkout')"
change freshness.yml "doc['jobs']['scope']['steps'][1]['run'] = './scripts/scope.sh >> \"\$GITHUB_OUTPUT\"'"
nobase "the same script run by its path is refused" 1
change freshness.yml "doc['jobs']['scope']['steps'][1]['run'] = 'case \"\$p\" in\n  scripts/scope.sh) echo suite=true >> \"\$GITHUB_OUTPUT\" ;;\nesac'"
nobase "a path that is only a pattern of a case is not a script it runs" 0
for event in pull_request_target workflow_call; do
	change freshness.yml "doc.pop(True, None); doc['on'] = {'$event': None}; doc['jobs']['scope']['steps'][1]['run'] = 'bash ./scripts/scope.sh >> \"\$GITHUB_OUTPUT\"'"
	nobase "a scope step that runs the checkout's script in a workflow run by $event is refused" 1
done
change freshness.yml "doc['on'] = {'schedule': [{'cron': '0 0 * * *'}]}; doc['jobs']['scope']['steps'][1]['run'] = 'bash ./scripts/scope.sh >> \"\$GITHUB_OUTPUT\"'; doc.pop(True, None)"
nobase "a workflow no pull request can run may run the script of its own checkout" 0
# The readiness probe of scoop-bucket: what the producer prints decides whether
# the watcher runs, so in a pull request it runs the copy of the script in the
# base commit. There is one invocation, `bash "$script"`, and only the source of
# `$script` changes; the older form ran the checkout's script by its path.
bytes_workflow() { # $1=the line that runs the script
	cat > "$G/.github/workflows/freshness.yml" <<EOF
name: Freshness
on: pull_request
jobs:
  published-bytes-ready:
    runs-on: ubuntu-latest
    outputs:
      ready: \${{ steps.check.outputs.ready }}
    steps:
      - id: check
        env:
          EVENT: \${{ github.event_name }}
        run: |
          set -euo pipefail
          path=scripts/monitoring/check-schedule-history-ready.sh
          script="\$path"
          if [ "\$EVENT" = pull_request ]; then
            copy="\$(mktemp "\$RUNNER_TEMP/history-ready.XXXXXX")"
            trap 'rm -f "\$copy"' EXIT
            if git show "HEAD^1:\$path" > "\$copy" 2>/dev/null; then script="\$copy"; else script=""; fi
          fi
          ready=ready=true
          if [ -n "\$script" ]; then
            $1
          fi
          echo "\$ready" >> "\$GITHUB_OUTPUT"
  freshness-published-bytes:
    needs: published-bytes-ready
    if: needs.published-bytes-ready.outputs.ready == 'true'
    uses: ./.github/workflows/reusable-schedule-freshness.yml
EOF
}
bytes_workflow 'printed="$(bash "$script" published-bytes.yml 3)"'
nobase "the readiness probe that runs the base's copy through one invocation is accepted" 0
bytes_workflow 'printed="$(bash ./scripts/monitoring/check-schedule-history-ready.sh published-bytes.yml 3)"'
nobase "the readiness probe that runs the script of the checkout by its path is refused" 1
check "and the refusal names the job and the file" "1" \
	"$(said "$out" 'job `published-bytes-ready` in .github/workflows/freshness.yml writes outputs a condition reads and runs a script of the repository from the checkout')"
sed -i 's/published-bytes-ready:$/ready-too:/; s/needs: published-bytes-ready/needs: ready-too/; s/needs\.published-bytes-ready/needs.ready-too/' "$G/.github/workflows/freshness.yml"
nobase "the same probe under another job id is refused as well" 1


finish
