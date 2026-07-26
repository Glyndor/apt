#!/usr/bin/env bash
#
# Tests for scripts/purge-cache.sh — the step that clears the mutable, fixed-name
# files from Cloudflare after a publish.
#
# The property under test is that the purge covers EVERY URL the run just
# published, in as many requests as Cloudflare's per-request limit needs. Before
# this script the step refused to send more than 30 and said the list "needs to
# be sent in batches" without ever doing so, which would have failed the publish
# after the sync had already landed — a fresh archive behind a stale edge cache.
#
# A fake Cloudflare API is served locally and records each request body, so the
# assertions are on what was actually sent rather than on the script's own log.
#
# Requires: python3, curl, jq.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PURGE="$HERE/scripts/purge-cache.sh"
WORK="$(mktemp -d)"
BUILT="$WORK/public"
REQUESTS="$WORK/requests"

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

# Build a synthetic archive: <products> × <arches>, plus the keyring, laid out
# the way build-repo.sh leaves it. Only the fields purge-cache.sh reads matter.
build_archive() { # $1=product count $2=arch list
	local products="$1" arches="$2" arch i path
	rm -rf "$BUILT"
	mkdir -p "$BUILT/dists/stable"

	{
		echo "Origin: Glyndor"
		echo "SHA256:"
		for arch in $arches; do
			printf ' %s %s main/binary-%s/Packages\n' "deadbeef" 100 "$arch"
			printf ' %s %s main/binary-%s/Packages.gz\n' "deadbeef" 100 "$arch"
			printf ' %s %s main/binary-%s/Release\n' "deadbeef" 100 "$arch"
		done
		echo "Description: synthetic"
	} > "$BUILT/dists/stable/Release"

	for arch in $arches; do
		mkdir -p "$BUILT/dists/stable/main/binary-$arch"
		: > "$BUILT/dists/stable/main/binary-$arch/Packages"
		for ((i = 1; i <= products; i++)); do
			path="pool/main/p/prod$i/prod${i}_1.0.0_${arch}.deb"
			printf 'Package: prod%s\nFilename: %s\n\n' "$i" "$path" \
				>> "$BUILT/dists/stable/main/binary-$arch/Packages"
		done
		printf 'Package: glyndor-archive-keyring\nFilename: %s\n\n' \
			"pool/main/g/glyndor-archive-keyring/glyndor-archive-keyring_1.0.0_all.deb" \
			>> "$BUILT/dists/stable/main/binary-$arch/Packages"
	done
}

# A fake Cloudflare purge endpoint. Appends each request body as one line to
# $REQUESTS and answers the shape the script parses.
mkdir -p "$WORK/srv"
cat > "$WORK/srv/api.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.environ["REQUESTS"]
MODE = os.environ.get("MODE", "ok")

class Handler(BaseHTTPRequestHandler):
	def do_POST(self):
		body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
		with open(LOG, "a") as fh:
			fh.write(body.decode() + "\n")
		if MODE == "fail-second" and sum(1 for _ in open(LOG)) == 2:
			payload = {"success": False, "errors": [{"message": "too many files"}]}
		else:
			payload = {"success": True, "errors": []}
		out = json.dumps(payload).encode()
		self.send_response(200)
		self.send_header("Content-Type", "application/json")
		self.send_header("Content-Length", str(len(out)))
		self.end_headers()
		self.wfile.write(out)

	def log_message(self, *args):
		pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

start_server() { # $1=mode
	# `wait` on a process we just killed reports its signal, which errexit would
	# take for a test failure.
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	: > "$REQUESTS"
	REQUESTS="$REQUESTS" MODE="$1" python3 "$WORK/srv/api.py" "$PORT" >/dev/null 2>&1 &
	SERVER_PID=$!
	for _ in $(seq 1 50); do
		curl -fsS -X POST -d '{}' "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 && break
		sleep 0.1
	done
	: > "$REQUESTS"
}

export CF_TOKEN="fake-token"
export CF_ZONE="fake-zone"
export CF_API_BASE="http://127.0.0.1:$PORT/client/v4"

# --- one product, two architectures: today's archive ------------------------
# 5 fixed + 6 index (3 per arch) + 3 pool (1 per arch, plus the keyring, which
# both indices declare and the list deduplicates) = 14, one request.
start_server ok
build_archive 1 "amd64 arm64"
"$PURGE" "https://apt.example" "$BUILT" > "$WORK/out" 2>&1 \
	|| { echo "FAIL  the one-product case exited non-zero"; cat "$WORK/out"; exit 1; }

check "one product on two arches sends a single request" \
	"1" "$(wc -l < "$REQUESTS")"
check "one product on two arches purges 14 URLs" \
	"14" "$(jq -r '.files | length' < "$REQUESTS")"
check "the pool object is deduplicated across the two indices" \
	"1" "$(jq -r '[.files[] | select(endswith("_all.deb"))] | length' < "$REQUESTS")"
check "the per-architecture Release files are purged" \
	"2" "$(jq -r '[.files[] | select(endswith("binary-amd64/Release") or endswith("binary-arm64/Release"))] | length' < "$REQUESTS")"

# --- the roster on three architectures: the case that used to fail ----------
# 5 fixed + 9 index + (7 products + keyring) × 3 arches deduplicated to 22 pool
# objects = 36 URLs. The old step refused this outright.
start_server ok
build_archive 7 "amd64 arm64 armhf"
"$PURGE" "https://apt.example" "$BUILT" > "$WORK/out" 2>&1 \
	|| { echo "FAIL  the seven-product case exited non-zero"; cat "$WORK/out"; exit 1; }

total="$(jq -rs '[.[].files[]] | length' < "$REQUESTS")"
check "seven products on three arches needs two requests" \
	"2" "$(wc -l < "$REQUESTS")"
check "seven products on three arches purges 36 URLs" \
	"36" "$total"
check "no request exceeds Cloudflare's 30-file limit" \
	"" "$(jq -rs '[.[] | select((.files | length) > 30)] | length | select(. > 0) | "\(.) oversized"' < "$REQUESTS")"
check "every URL is sent exactly once" \
	"$total" "$(jq -rs '[.[].files[]] | unique | length' < "$REQUESTS")"

# --- a failing batch fails the run ------------------------------------------
start_server fail-second
build_archive 7 "amd64 arm64 armhf"
rc=0
"$PURGE" "https://apt.example" "$BUILT" > "$WORK/out" 2>&1 || rc=$?
check "a rejected batch fails the purge" "1" "$rc"
check "the error names which batch was rejected" \
	"1" "$(grep -c 'failed on batch 2' "$WORK/out")"

# --- fail closed on missing inputs ------------------------------------------
start_server ok
rm -rf "$BUILT"
rc=0
"$PURGE" "https://apt.example" "$BUILT" >/dev/null 2>&1 || rc=$?
check "a missing Release fails rather than purging nothing" "1" "$rc"

rc=0
CF_TOKEN="" "$PURGE" "https://apt.example" "$BUILT" >/dev/null 2>&1 || rc=$?
check "an absent CF_TOKEN fails closed" "1" "$rc"

rc=0
"$PURGE" >/dev/null 2>&1 || rc=$?
check "no arguments is a usage error" "2" "$rc"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
