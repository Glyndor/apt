#!/usr/bin/env bash
#
# Tests for the budget of scripts/publish/purge-cache.sh.
#
# The purge is the step that clears Cloudflare's cache after a publish, and it
# was the one step of that job with no bound of its own. Its curl carried
# `--max-time 300 --retry 3 --retry-all-errors --retry-delay 5` and no
# `--retry-max-time`, so a peer that accepted the connection and never
# answered cost four attempts of five minutes each: 1200s of transfer against
# a publish job allowed 900s, and then the read-back never ran either. The job
# was cancelled, so the operator read "cancelled after 15 minutes" instead of
# which group of URLs was not purged.
#
# So the purge takes a budget for the WHOLE run, every transfer and every
# retry inside it are limited to the time that is left, and the diagnosis
# names the group and the batch that were in flight.
#
# The peer here is a fake Cloudflare API that accepts the request and never
# answers, and one that answers slowly. The control is the same purge against
# the same fixture with room in the budget: it succeeds, so a red case is the
# budget and not the fixture.
#
# Requires: python3, curl, jq.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PURGE="$HERE/scripts/publish/purge-cache.sh"
WORK="$(mktemp -d)"
BUILT="$WORK/public"
REQUESTS="$WORK/requests"
READY="$WORK/ready"
OUT="$WORK/out"

SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

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

# Build a synthetic archive laid out the way build-repo.sh leaves it: one
# product on two architectures, the keyring, the installers and the files the
# publish puts at the root. Only the fields purge-cache.sh reads matter.
#
# The size is deliberate. It makes the purge exactly two requests -- the
# content group and then the index group -- so a case can hang on one group
# and not on the other.
build_archive() {
	rm -rf "$BUILT"
	mkdir -p "$BUILT/dists/stable/main/binary-amd64" \
		"$BUILT/dists/stable/main/binary-arm64" "$BUILT/install"

	{
		echo "Origin: Glyndor"
		echo "SHA256:"
		for arch in amd64 arm64; do
			printf ' deadbeef 100 main/binary-%s/Packages\n' "$arch"
			printf ' deadbeef 100 main/binary-%s/Packages.gz\n' "$arch"
			printf ' deadbeef 100 main/binary-%s/Release\n' "$arch"
		done
		echo "Description: synthetic"
	} > "$BUILT/dists/stable/Release"

	for arch in amd64 arm64; do
		{
			printf 'Package: prod1\nFilename: pool/main/p/prod1/prod1_1.0.0_%s.deb\n\n' "$arch"
			# The keyring is architecture-independent and every architecture's
			# index declares it, the way reprepro lays the archive out.
			printf 'Package: glyndor-archive-keyring\nFilename: pool/main/g/glyndor-archive-keyring/glyndor-archive-keyring_1.0.0_all.deb\n\n'
		} > "$BUILT/dists/stable/main/binary-$arch/Packages"
	done

	printf '#!/bin/sh\n' > "$BUILT/install/prod1"
	printf '<!doctype html>\n' > "$BUILT/index.html"
	printf 'not a real package\n' > "$BUILT/glyndor-archive-keyring.deb"
	printf -- '-----BEGIN PGP SIGNATURE-----\n' > "$BUILT/glyndor-archive-keyring.deb.asc"
}

# A fake Cloudflare purge endpoint. It counts the requests it receives and
# answers according to the mode:
#
#   ok          answer at once
#   slow        answer after SLOW_SECONDS
#   hang        accept the request and never answer
#   hang-second answer the first request, hang on the second
#
# The hang is what the budget exists for: the request is received and the
# connection stays open with nothing on it, which is what a peer that accepts
# and stalls looks like from here.
#
# It is threaded on purpose. A single-threaded server would still be busy
# inside the first hanging handler when the retry came in, so the retry would
# never be counted and the case would measure the wrong thing.
mkdir -p "$WORK/srv"
cat > "$WORK/srv/api.py" <<'PY'
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ["REQUESTS"]
READY = os.environ["READY"]
MODE = os.environ.get("MODE", "ok")
SLOW = float(os.environ.get("SLOW_SECONDS", "1"))

count_lock = threading.Lock()
count = 0

class Handler(BaseHTTPRequestHandler):
	protocol_version = "HTTP/1.1"

	def do_POST(self):
		global count
		body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
		with count_lock:
			count += 1
			seen = count
		with open(LOG, "a") as fh:
			fh.write(body.decode() + "\n")
		if MODE == "hang" or (MODE == "hang-second" and seen > 1):
			# The connection is accepted and the body read, and then
			# nothing is ever written back. The client waits for its
			# own deadline to expire.
			time.sleep(3600)
			return
		if MODE == "slow":
			time.sleep(SLOW)
		out = json.dumps({"success": True, "errors": []}).encode()
		self.send_response(200)
		self.send_header("Content-Type", "application/json")
		self.send_header("Content-Length", str(len(out)))
		self.end_headers()
		self.wfile.write(out)

	def log_message(self, *args):
		pass

server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.daemon_threads = True
# The port is bound at this point. The readiness is announced by a file
# rather than by a request, because a request would be a request: in the
# hanging mode it would never be answered, and the probe would be the very
# stall the case is about.
with open(READY, "w") as fh:
	fh.write("ready\n")
server.serve_forever()
PY

PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

start_server() { # $1=mode [$2=slow seconds]
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	: > "$REQUESTS"
	rm -f "$READY"
	REQUESTS="$REQUESTS" READY="$READY" MODE="$1" SLOW_SECONDS="${2:-1}" \
		python3 "$WORK/srv/api.py" "$PORT" > "$WORK/srv.log" 2>&1 &
	SERVER_PID=$!
	# A server that never came up would make every case below fail for a
	# reason that has nothing to do with the budget, so the readiness is
	# checked rather than assumed.
	ready=0
	for _ in $(seq 1 50); do
		if [ -f "$READY" ]; then
			ready=1
			break
		fi
		sleep 0.1
	done
	[ "$ready" -eq 1 ] || {
		echo "FAIL  the fake Cloudflare API never came up on $PORT"
		sed 's/^/        /' "$WORK/srv.log"
		exit 1
	}
}

export CF_TOKEN="fake-token"
export CF_ZONE="fake-zone"
export CF_API_BASE="http://127.0.0.1:$PORT/client/v4"

# The per-attempt ceiling is lowered for the cases that hang, so they do not
# wait out a 30-second deadline to prove a 6-second budget. The cases that
# answer keep the production ceiling, so the control exercises the real one.

# A bound on the cases that hang, so a regression is reported in seconds
# instead of minutes. The point of the budget is that the purge stops BY
# ITSELF: a run that has to be killed here did not, and the assertions below
# say so.
#
# It is not a substitute for the budget. The budget is what the script
# enforces; this only keeps the suite from waiting out a purge that ignores
# it, which is exactly what a regression looks like.
CASE_TIMEOUT=25

# --- the control: room in the budget, a peer that answers ------------------
#
# Without this, every red case below could be a broken fixture rather than a
# budget that stopped something. Same script, same archive, same server, a
# budget that is not in the way.
start_server ok
build_archive
rc=0
"$PURGE" "https://apt.example" "$BUILT" 60 > "$OUT" 2>&1 || rc=$?
check "with room in the budget the purge succeeds" "0" "$rc"
check "and it purges every URL" "16" "$(jq -s -r '[.[].files[]] | length' < "$REQUESTS")"
check "and it sends the content and the index groups separately" \
	"2" "$(wc -l < "$REQUESTS")"

# The same control against a peer that is slow but finite. A purge that is
# merely slow has to finish; only a purge that is stuck may be cut short.
start_server slow 1
build_archive
rc=0
"$PURGE" "https://apt.example" "$BUILT" 60 > "$OUT" 2>&1 || rc=$?
check "a slow but answering peer is still purged" "0" "$rc"
check "and every URL is still purged" "16" "$(jq -s -r '[.[].files[]] | length' < "$REQUESTS")"

# --- the budget stops a peer that never answers ----------------------------
#
# The property under test: the purge does not spend more than its budget on a
# peer that accepts the request and never answers, and it says which group
# and which batch it was on when it gave up.
#
# The budget is 6s and each attempt is cut at 1s by PURGE_TRANSFER_MAX, with
# the production 5s wait between attempts. The retry sequence therefore fits
# two attempts inside the budget, where an unbounded one would make four.
start_server hang
build_archive
started="$(date +%s)"
rc=0
timeout "$CASE_TIMEOUT" env PURGE_TRANSFER_MAX=1 "$PURGE" "https://apt.example" "$BUILT" 6 > "$OUT" 2>&1 || rc=$?
took=$(( $(date +%s) - started ))
check "a peer that never answers fails the purge" "1" "$rc"
check "the failure names the group that was in flight" \
	"1" "$(grep -c 'content batch 1' "$OUT")"
check "the failure names the budget, not only the request" \
	"1" "$(grep -c 'purge budget ran out' "$OUT")"
check "the failure names the budget it was given" "1" "$(grep -c '6s purge budget' "$OUT")"
check "and it says the edge may still be serving the previous index" \
	"1" "$(grep -c '::warning::the indices were not purged' "$OUT")"

# The proof that the budget is what stopped it and not a slow machine: the
# retry sequence was cut short. An unbounded one makes four attempts of this
# request; the budget allows two.
#
# The exit code is part of the assertion on purpose. A case killed by the
# timeout above also made few attempts, and an assertion that counted
# attempts alone would pass on a purge that never stopped by itself.
attempts="$(wc -l < "$REQUESTS")"
if [ "$rc" -eq 1 ] && [ "$attempts" -le 2 ]; then
	echo "ok    the budget cut the retry sequence short ($attempts attempts of a possible 4)"
	pass=$((pass + 1))
else
	echo "FAIL  the budget did not cut the retry sequence short ($attempts attempts, exit $rc)"
	fail=$((fail + 1))
fi

# And the wall clock: the run has to end with the budget, not with the job's
# timeout. An unbounded run of this case takes 19s (four 1s attempts and three
# 5s waits); a budgeted one takes about 7.
if [ "$took" -lt 15 ]; then
	echo "ok    and the purge stopped within its budget (${took}s)"
	pass=$((pass + 1))
else
	echo "FAIL  the purge ran for ${took}s, past its budget"
	fail=$((fail + 1))
fi

# --- the attempt is cut at the time that is left ----------------------------
#
# The case above lowered the per-attempt ceiling to keep itself quick, which
# leaves the clamp untested: with a ceiling of 1s and a budget of 6s the
# ceiling is already the tighter of the two. This case uses the production
# ceiling of 30s against a 6s budget, so the deadline that has to bind is the
# time that is LEFT. Without that clamp one attempt would run to its own 30s
# ceiling and the purge would spend five times its budget on one request.
start_server hang
build_archive
started="$(date +%s)"
rc=0
timeout "$CASE_TIMEOUT" "$PURGE" "https://apt.example" "$BUILT" 6 > "$OUT" 2>&1 || rc=$?
took=$(( $(date +%s) - started ))
check "a hung peer with the production ceiling fails the purge" "1" "$rc"
check "and the failure still names the budget" \
	"1" "$(grep -c 'purge budget ran out' "$OUT")"
if [ "$took" -lt 15 ]; then
	echo "ok    and the single attempt was cut at the time that was left (${took}s)"
	pass=$((pass + 1))
else
	echo "FAIL  the attempt ran past the time that was left (${took}s)"
	fail=$((fail + 1))
fi

# --- the diagnosis names the group that was in flight ----------------------
#
# The same hang, but on the second request: the content group is purged and
# the index group is the one that stalls. The diagnosis has to name THAT
# group, or it is a message that names a constant rather than the state.
start_server hang-second
build_archive
rc=0
timeout "$CASE_TIMEOUT" env PURGE_TRANSFER_MAX=1 "$PURGE" "https://apt.example" "$BUILT" 6 > "$OUT" 2>&1 || rc=$?
check "a hang on the index group fails the purge" "1" "$rc"
check "the failure names the index group, not the content one" \
	"1" "$(grep -c 'index batch 2' "$OUT")"
check "and it does not blame the content group" \
	"0" "$(grep -c 'content batch' "$OUT")"
# The content group really was purged before the index group stalled, and the
# ordering still holds: no index in the first request, every index in the
# second.
check "the first request carried no index" \
	"0" "$(head -1 "$REQUESTS" | jq -r '[.files[] | select(contains("/dists/stable/"))] | length')"
check "and the second request carried them all" \
	"9" "$(sed -n '2p' "$REQUESTS" | jq -r '.files | length')"

# --- the budget is a number, not a word -------------------------------------
build_archive
rc=0
"$PURGE" "https://apt.example" "$BUILT" "sixty" > "$OUT" 2>&1 || rc=$?
check "a budget that is not a number fails the purge" "1" "$rc"
check "and says so" "1" "$(grep -c 'must be a positive integer' "$OUT")"

rc=0
"$PURGE" "https://apt.example" "$BUILT" 0 > "$OUT" 2>&1 || rc=$?
check "a budget of zero seconds fails the purge" "1" "$rc"

# The default budget is a number too, and it is the one production would use
# if the workflow ever stopped passing it.
start_server ok
build_archive
rc=0
"$PURGE" "https://apt.example" "$BUILT" > "$OUT" 2>&1 || rc=$?
check "the default budget purges normally" "0" "$rc"
check "and the run log says which budget it spent" \
	"1" "$(grep -c 's of the 120s budget' "$OUT")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
