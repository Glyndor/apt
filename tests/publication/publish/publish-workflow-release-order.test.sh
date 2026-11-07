#!/usr/bin/env bash
#
# The step of publish.yml that refuses a release older than the one served: it
# has to call scripts/verify/check-release-order.sh with the product, the tag
# the download step pinned and the archive URL, a refusal has to stop the
# publish, and a missing pinned tag has to stop it too (issue #384).
#
# tests/verify/check-release-order.test.sh runs the script directly. Neither it
# nor the shape suite notices the call replaced by `true`, or followed by
# `|| true`: the step keeps its name, the script keeps passing its own suite and
# the archive moves backwards for every client. This suite extracts the step as
# shipped and runs it in a sandbox with a stand-in for the script that records
# its arguments and refuses one tag. Then the same refusal runs against copies of
# the workflow with the call replaced by `true` and with `|| true` after it, and
# the refusal has to pass there, so it is shown to come from the call.
#
# Requires: python3.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WF="$HERE/.github/workflows/publish.yml"
STEP="Refuse a release older than the one served"
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

extract() { # $1=workflow file -> the run: body of the step, dedented
	python3 -I - "$1" "$STEP" <<'PY'
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

# A sandbox: a stand-in for the script that records "product tag url" and
# refuses the tag v0.0.1, and the tag the download step would have pinned.
sandbox() { # $1=name $2=pinned tag or "-" for none -> prints the directory
	local d="$WORK/$1"
	mkdir -p "$d/scripts/verify" "$d/tags"
	cat > "$d/scripts/verify/check-release-order.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s %s %s\n' "$1" "$2" "$3" >> calls.log
[ "$2" != "v0.0.1" ]
STUB
	chmod +x "$d/scripts/verify/check-release-order.sh"
	[ "$2" = "-" ] || echo "$2" > "$d/tags/podup"
	echo "$d"
}

run_step() { # $1=sandbox $2=step file -> rc
	(cd "$1" && PRODUCTS="podup:x" ARCHIVE_URL="https://archive.example" bash "$2" >"$WORK/out" 2>&1)
}

extract "$WF" > "$WORK/step.sh"
check "the step was extracted from the workflow" "1" \
	"$(grep -v '^[[:space:]]*#' "$WORK/step.sh" | grep -c 'check-release-order.sh')"

D="$(sandbox newer v1.2.0)"; rc=0; run_step "$D" "$WORK/step.sh" || rc=$?
check "a release the script admits passes the step" "0" "$rc"
check "and the script got the product, the pinned tag and the archive URL" "podup v1.2.0 https://archive.example" "$(cat "$D/calls.log")"

D="$(sandbox older v0.0.1)"; rc=0; run_step "$D" "$WORK/step.sh" || rc=$?
check "a release the script refuses stops the step" "1" "$rc"

D="$(sandbox notag -)"; rc=0; run_step "$D" "$WORK/step.sh" || rc=$?
check "a missing pinned tag stops the step" "1" "$rc"
check "and says no release tag was pinned" "1" "$(grep -c 'no release tag was pinned for podup' "$WORK/out")"
check "and the script was never asked" "0" "$([ -e "$D/calls.log" ] && echo 1 || echo 0)"

# --- the controls: the same refusal, with the call neutralised ----------------
mutate() { # $1=name $2=sed expression
	sed "$2" "$WF" > "$WORK/publish-$1.yml"
	check "the $1 sabotage changed the workflow" "1" "$(cmp -s "$WF" "$WORK/publish-$1.yml" && echo 0 || echo 1)"
	extract "$WORK/publish-$1.yml" > "$WORK/step-$1.sh"
	D="$(sandbox "m-$1" v0.0.1)"; rc=0; run_step "$D" "$WORK/step-$1.sh" || rc=$?
	check "without the call ($1), the refused release is admitted (the refusal is the call's)" "0" "$rc"
}
mutate replaced 's|^\( *\)bash \./scripts/verify/check-release-order\.sh .*|\1true|'
mutate ignored 's|^\( *bash \./scripts/verify/check-release-order\.sh .*\)$|\1 \|\| true|'
mutate guarded 's|^\( *\)bash \./scripts/verify/check-release-order\.sh \(.*\)$|\1if false; then bash ./scripts/verify/check-release-order.sh \2; fi|'

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
