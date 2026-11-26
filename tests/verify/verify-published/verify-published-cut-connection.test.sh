#!/usr/bin/env bash
#
# What the read-back does when the connection to the archive breaks half way through a transfer.
#
# The other suites of scripts/verify/verify-published.sh serve the archive with a plain static server, so every transfer
# either finishes or is a clean HTTP error. A real edge or bucket does neither: it cuts a body at the half, closes a
# connection without an answer, serves an empty 200 for an object that is not there yet, or goes quiet. The read-back is
# the gate that says the publish took, so each of those has to end in a refusal that names the file, within the time it
# was given, and a cut that does not repeat has to be absorbed by the retries instead of failing a good archive.
#
# The server is the fixture's archive behind a small python server on its own port, which injects one fault for the
# first K requests whose path holds a text, from a control file the cases rewrite. No network: 127.0.0.1 only.
#
# Requires: gpg, curl, python3, sha256sum.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/fixtures/verify/verify-published-fixture.sh
. "$HERE/tests/fixtures/verify/verify-published-fixture.sh"

pass=0
fail=0

JUMP="$WORK/clock-jump"
CONTROL="$WORK/faults.json"
echo '[]' > "$CONTROL"
cat > "$WORK/faulty-server.py" <<'PY'
import http.server, json, socket, sys, threading, time

root, port, control, flag = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
counts, lock = {}, threading.Lock()


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)

    def log_message(self, *a):
        pass

    def do_GET(self):
        rules = json.load(open(control))
        for i, rule in enumerate(rules):
            if rule["match"] in self.path:
                with lock:
                    n = counts.get(i, 0)
                    counts[i] = n + 1
                if n < rule["times"]:
                    return self.fault(rule["mode"])
        return super().do_GET()

    def fault(self, mode):
        try:
            data = open(self.translate_path(self.path), "rb").read()
        except OSError:
            data = b"x" * 64
        if mode == "cut":  # the headers promise the whole body, half of it arrives, then the connection closes
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data[: max(1, len(data) // 2)])
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
        elif mode == "empty":  # a 200 with nothing in it: the object is not there yet
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif mode == "reset":  # the connection closes with no answer at all
            self.connection.shutdown(socket.SHUT_RDWR)
        elif mode == "flag":  # the object is served whole, and the clock of the run is told to jump
            http.server.SimpleHTTPRequestHandler.do_GET(self)
            open(flag, "w").close()
            return
        elif mode == "hang":  # the peer accepts and never answers
            time.sleep(120)
        self.close_connection = True


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
FPORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
python3 "$WORK/faulty-server.py" "$SITE" "$FPORT" "$CONTROL" "$JUMP" &
FAULTY_PID=$!
trap 'kill "$FAULTY_PID" 2>/dev/null || true; cleanup' EXIT
FBASE="http://127.0.0.1:$FPORT"
for _ in $(seq 1 50); do
	curl -fsS --max-time 2 "$FBASE/dists/stable/Release" -o /dev/null 2>/dev/null && break
	sleep 0.2
done
curl -fsS --max-time 2 "$FBASE/dists/stable/Release" -o /dev/null || { echo "faulty server never came up" >&2; exit 1; }

# faults <match> <mode> <times> ... : the control file, as a list of rules. Counting starts again with each server restart,
# so each case restarts the server by rewriting the control file under a fresh path.
faults() {
	local json="[" sep=""
	while [ $# -gt 0 ]; do
		json="$json$sep{\"match\":\"$1\",\"mode\":\"$2\",\"times\":$3}"; sep=","
		shift 3
	done
	echo "$json]" > "$CONTROL"
	kill "$FAULTY_PID" 2>/dev/null || true
	wait "$FAULTY_PID" 2>/dev/null || true
	python3 "$WORK/faulty-server.py" "$SITE" "$FPORT" "$CONTROL" "$JUMP" &
	FAULTY_PID=$!
	for _ in $(seq 1 50); do
		curl -fsS --max-time 2 "$FBASE/dists/stable/Release" -o /dev/null 2>/dev/null && return 0
		sleep 0.2
	done
	return 1
}
# read_back <attempts> <delay> <budget>: the script against the faulty server, with the exit status and the seconds it took.
read_back() {
	local start end rc=0
	start="$(date +%s)"
	out="$(timeout 90 "$VERIFY" "$FBASE" "$TRUSTED_ASC" "$1" "$2" "$3" 2>&1)" || rc=$?
	end="$(date +%s)"
	secs=$((end - start))
	return "$rc"
}
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok   - $1"; pass=$((pass + 1))
	else
		echo "FAIL - $1 (expected '$2', got '$3')"; printf '%s\n' "$out" | sed 's/^/       /'; fail=$((fail + 1))
	fi
}
said() { if printf '%s\n' "$out" | grep -qF -- "$1"; then echo 1; else echo 0; fi; }

faults
rc=0; read_back 3 0 60 || rc=$?
check "control: the archive behind the faulty server, with no fault, is accepted" "0" "$rc"

# --- a cut that does not repeat is absorbed -------------------------------------------------------
faults "binary-arm64/Packages" cut 1
rc=0; read_back 4 0 60 || rc=$?
check "an index cut at the half once, then served whole, is accepted by the retries" "0" "$rc"
faults ".deb" cut 1
rc=0; read_back 4 0 60 || rc=$?
check "a package cut at the half once, then served whole, is accepted by the retries" "0" "$rc"

# --- a cut that repeats is a refusal that names the file -----------------------------------------
faults "binary-arm64/Packages" cut 99
rc=0; read_back 3 0 60 || rc=$?
check "an index that is always cut at the half is refused" "1" "$rc"
check "and the refusal names the file" "1" "$(said 'binary-arm64/Packages')"
check "and the run ended well inside the time it was given" "1" "$([ "$secs" -lt 60 ] && echo 1 || echo 0)"
faults ".deb" cut 99
rc=0; read_back 3 0 60 || rc=$?
check "a package that is always cut at the half is refused" "1" "$rc"
check "and the refusal names the package" "1" "$(said '.deb')"

# --- an empty answer for an object that is not there yet ------------------------------------------
faults ".deb" empty 99
rc=0; read_back 3 0 60 || rc=$?
check "an empty 200 for a package is refused" "1" "$rc"
check "and the refusal is a size that does not match" "1" "$(said 'size mismatch')"
faults ".deb" empty 1
rc=0; read_back 4 0 60 || rc=$?
check "an empty 200 that is served whole on the next try is accepted" "0" "$rc"

# --- a connection that closes with no answer --------------------------------------------------------
faults "dists/stable/InRelease" reset 99
rc=0; read_back 3 0 60 || rc=$?
check "an InRelease that is never answered is refused" "1" "$rc"
check "and the refusal names it" "1" "$(said 'InRelease')"
faults "dists/stable/InRelease" cut 1
rc=0; read_back 4 0 60 || rc=$?
check "an InRelease cut at the half once is accepted on the next try" "0" "$rc"
faults "dists/stable/InRelease" cut 99
rc=0; read_back 3 0 60 || rc=$?
check "an InRelease that is always cut at the half is refused, not read as signed" "1" "$rc"

# --- a peer that accepts and never answers: the budget ends it --------------------------------------
faults "binary-arm64/Packages" hang 99
rc=0; read_back 6 1 8 || rc=$?
check "a peer that never answers is refused" "1" "$rc"
check "and the run ended by the budget, long before the peer would have answered" "1" "$([ "$secs" -lt 45 ] && echo 1 || echo 0)"

# --- the budget ends the loops that the cases above do not reach --------------------------------------------
# The clock of the run is the date it reads. A stub of date answers the real time to the first call, which is where the run
# starts counting, and a time a day later to every call after it once the flag file exists: the flag is there from the
# start, or the server makes it when it has served the object a case names. What each loop says when it finds the budget
# gone is what the case reads, since the run goes on to the same refusal by another road otherwise.
mkdir -p "$WORK/clock"
REAL_DATE="$(command -v date)"
cat > "$WORK/clock/date" <<STUB
#!/usr/bin/env bash
if [ -e "$WORK/clock-started" ] && [ -e "$JUMP" ]; then
	echo \$(( \$("$REAL_DATE" "\$@") + 86400 ))
else
	: > "$WORK/clock-started"
	exec "$REAL_DATE" "\$@"
fi
STUB
chmod +x "$WORK/clock/date"
jumped() { # <flag set before the run: yes|no>
	rm -f "$JUMP" "$WORK/clock-started"
	[ "$1" = yes ] && : > "$JUMP"
	local rc=0
	out="$(PATH="$WORK/clock:$PATH" timeout 90 "$VERIFY" "$FBASE" "$TRUSTED_ASC" 3 0 60 2>&1)" || rc=$?
	return "$rc"
}
faults
rc=0; jumped yes || rc=$?
check "a clock that is past the budget before the first answer of the archive is refused" "1" "$rc"
check "by the loop of the InRelease, which says the budget ran out" "1" "$(said 'InRelease did not converge to the published build before the 60s budget ran out')"

faults "dists/stable/InRelease" flag 1
rc=0; jumped no || rc=$?
check "a clock that jumps once the InRelease has been served whole is refused" "1" "$rc"
check "by the check after it, which says the detached pair was not fetched" "1" "$(said 'the detached Release / Release.gpg pair was not fetched before the 60s budget ran out')"

faults "glyndor-archive-keyring.deb" flag 1
rc=0; jumped no || rc=$?
check "a clock that jumps once the bootstrap package has been served is refused" "1" "$rc"
check "by the loop of its signature, which says the budget ran out on the first attempt" "1" "$(said 'glyndor-archive-keyring.deb.asc did not verify and the 60s budget ran out on attempt 1')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
