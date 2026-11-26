#!/usr/bin/env bash
#
# Record the index a publication has just put in the bucket, for the next one to compare with what is served
# (read-publication-record.sh reads it, check-index-baseline.sh judges by it).
#
#   write-publication-record.sh <InRelease> <out-dir>
#
# <InRelease> is the one this run built and published. Writes <out-dir>/published-index: '<time> <sha256>'.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "::error::usage: write-publication-record.sh <InRelease> <out-dir>" >&2; exit 2; }
mkdir -p "$2"
line="$(python3 -I - "$1" <<'PY'
import datetime
import email.utils
import hashlib
import re
import sys

try:
    with open(sys.argv[1], "rb") as handle:
        raw = handle.read()
except OSError as error:
    sys.exit(f"cannot read {sys.argv[1]}: {error.strerror}")
found = re.findall(r"(?m)^Date:[ \t]*(.*?)[ \t]*$", raw.decode("utf-8", "replace"))
if len(found) != 1:
    sys.exit("the published index does not declare Date exactly once")
try:
    date = email.utils.parsedate_to_datetime(found[0])
except (TypeError, ValueError):
    date = None
if date is None or date.utcoffset() != datetime.timedelta(0):
    sys.exit(f"the Date of the published index is not a time in UTC: {found[0]!r}")
print(date.strftime("%Y-%m-%dT%H:%M:%SZ"), hashlib.sha256(raw).hexdigest())
PY
)" || { echo "::error::the index that was published cannot be recorded" >&2; exit 1; }
printf '%s\n' "$line" > "$2/published-index"
echo "published index recorded (Date and SHA256 of InRelease): $line"
