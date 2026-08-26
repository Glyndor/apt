#!/usr/bin/env bash
#
# .github/workflows/health-check.yml is what notices that the published archive
# has gone stale, unreachable, or unsigned. Nothing tested it. A watcher whose
# own failure modes are unexercised is the shape standards/testing calls a cron
# hiding its failures: when it stops noticing, the silence is indistinguishable
# from all-clear.
#
# The `run:` block is extracted from the workflow and executed as it ships,
# rather than restated here -- a copy would pass while the workflow rotted. The
# archive is served over file://, which BASE_URL allows, so no network is
# involved and the fixtures are exact.
#
# The case worth having is the fourth: an UNSIGNED body carrying a fresh Date.
# The workflow's own comment says that is what the signature check is for, and
# until now nothing checked that the check works.
#
# Not covered, and not coverable without the Actions engine: the `schedule:`
# trigger and the job-level `if:` wiring.
#
# Requires: gpg, curl with the file:// protocol, python3.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$HERE/.github/workflows/health-check.yml"
WORK="$(mktemp -d)"
trap 'gpgconf --kill all 2>/dev/null || true; rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

for tool in gpg curl python3; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "NOTE  $tool is missing, so nothing below could run. Not a pass."
		exit 1
	}
done
curl --version | grep -q '\bfile\b' || {
	echo "NOTE  this curl has no file:// protocol. Not a pass."
	exit 1
}

# Extract a step's shell exactly as the workflow ships it. Plain text rather
# than a YAML parser: the shell test job does not install PyYAML, so a parser
# would pass here and fail on the runner.
step_script() { # $1=step name substring
	python3 - "$WORKFLOW" "$1" <<'PY'
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

FRESH="$WORK/fresh.sh"
step_script "Reachable and fresh InRelease" > "$FRESH"
check "the freshness step was extracted from the workflow" "1" \
	"$(grep -c 'InRelease signature verification failed' "$FRESH")"

# --- key material and a servable archive ------------------------------------

mkkey() { # $1=uid
	local home="$WORK/gnupg-$1"
	mkdir -p "$home"; chmod 700 "$home"
	GNUPGHOME="$home" gpg --batch --quiet --passphrase '' \
		--quick-generate-key "$1 <$1@test.invalid>" default default never \
		>/dev/null 2>&1
}
mkkey archive
mkkey impostor

# $1=archive dir  $2=signing uid or "-" for unsigned  $3=Date header value or
# "-" to omit it entirely
archive() {
	local dir="$1" signer="$2" datev="$3"
	rm -rf "$dir"; mkdir -p "$dir/dists/stable" "$dir/keyring"
	GNUPGHOME="$WORK/gnupg-archive" gpg --batch --armor --export archive \
		> "$dir/keyring/glyndor-apt-key.asc"
	{
		echo "Origin: Glyndor"
		[ "$datev" = "-" ] || echo "Date: $datev"
		echo "Suite: stable"
	} > "$dir/body"
	if [ "$signer" = "-" ]; then
		cp "$dir/body" "$dir/dists/stable/InRelease"
	else
		GNUPGHOME="$WORK/gnupg-$signer" gpg --batch --quiet --yes --clearsign \
			--output "$dir/dists/stable/InRelease" "$dir/body"
	fi
	echo "$dir"
}

# Run the extracted step against a served archive. MAX_AGE_HOURS is the
# workflow's own env; the step reads both from the environment as it does on a
# runner.
run_step() { # $1=archive dir  $2=max age hours  $3=base url override or "-"
	local dir="$1" maxage="$2" base="$3"
	[ "$base" = "-" ] && base="file://$dir"
	( cd "$dir" && BASE_URL="$base" MAX_AGE_HOURS="$maxage" \
		bash "$FRESH" ) >"$WORK/out" 2>&1
}
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }

NOW="$(date -u -R)"

# --- a healthy archive ------------------------------------------------------
#
# First, so every refusal below is not satisfied by a step that refuses
# everything.
A="$(archive "$WORK/ok" archive "$NOW")"
rc=0; run_step "$A" 48 - || rc=$?
check "a signed, fresh archive passes" "0" "$rc"
check "and it reports the age it read" "1" "$(said 'InRelease Date:')"

# --- unreachable ------------------------------------------------------------
rc=0; run_step "$A" 48 "file://$WORK/nowhere" || rc=$?
check "an unreachable archive fails" "1" "$rc"
check "and says it is unreachable" "1" "$(said 'is unreachable at')"

# --- signed by the wrong key ------------------------------------------------
A="$(archive "$WORK/impostor" impostor "$NOW")"
rc=0; run_step "$A" 48 - || rc=$?
check "an index signed by an untrusted key fails" "1" "$rc"
check "and names the signature, not the freshness" "1" \
	"$(said 'signature verification failed')"

# --- unsigned, with a fresh Date --------------------------------------------
#
# This is the attack the workflow's comment describes: a poisoned cache serving
# an unsigned body with a plausible Date, so that a freshness check reading the
# body without verifying it would report all-clear. Nothing exercised it.
A="$(archive "$WORK/unsigned" - "$NOW")"
rc=0; run_step "$A" 48 - || rc=$?
check "an unsigned body with a fresh Date fails" "1" "$rc"
check "and fails on the signature rather than passing on the Date" "1" \
	"$(said 'signature verification failed')"

# --- signed, but no Date field ----------------------------------------------
A="$(archive "$WORK/nodate" archive -)"
rc=0; run_step "$A" 48 - || rc=$?
check "a signed index with no Date field fails" "1" "$rc"
check "and says the index is malformed" "1" "$(said 'no Date field')"

# --- signed, but stale ------------------------------------------------------
A="$(archive "$WORK/stale" archive "$(date -u -R -d '5 days ago')")"
rc=0; run_step "$A" 48 - || rc=$?
check "an index older than the limit fails" "1" "$rc"
check "and says it is stale" "1" "$(said 'is stale')"

# The boundary, from the other side: the same age under a limit that admits it
# must pass, or the case above is satisfied by a step that calls everything
# stale.
rc=0; run_step "$A" 720 - || rc=$?
check "and the same index passes under a limit that admits it" "0" "$rc"

# --- signed, but the Date cannot be parsed ----------------------------------
#
# `date -u -d` fails on this. Before the guard, the assignment killed the step
# under `set -euo pipefail` with no ::error:: line: the run went red, which is
# the right outcome, but the alert named nothing and whoever opened it started
# from a bare exit code. This test is what found that.
A="$(archive "$WORK/baddate" archive "not a date at all")"
rc=0; run_step "$A" 48 - || rc=$?
check "an unparseable Date fails" "1" "$rc"
check "and says the Date could not be read" "1" \
	"$(said 'could not be read')"
check "and quotes the value it could not read" "1" \
	"$(said 'not a date at all')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
