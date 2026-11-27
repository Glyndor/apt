#!/usr/bin/env bash
#
# Refuse a served index that is older than what this archive is known to have served.
#
#   check-index-baseline.sh <verified-body> <InRelease>
#
# A signature says who wrote an index, not that it is the newest, and whoever can write the bucket can serve an earlier
# one again. The caller verifies the signature of <InRelease> with gpgv and hands over what gpgv wrote
# (<verified-body>), so what is judged here is what is compared afterwards.
#
# The index is refused when its Date is in the future or earlier than the one of index-floor.txt, a record kept in this
# repository. It is also refused when it has expired; when it is earlier than what the last publication recorded, or has
# that Date and other bytes; and, where no publication has recorded one, when it is more than three days old. These
# four can be set aside for one index, named by the SHA256 of its InRelease, by a run somebody started by hand.
#
# Every file it reads is bounded: one larger than the limit is refused, not read in part and hashed as if it were whole.
#
# Env: INDEX_RECORD (required), the file read-publication-record.sh wrote; ACCEPT_OLD_INDEX, empty or that SHA256;
# INDEX_FLOOR, the record of the repository (index-floor.txt beside this script); INDEX_NOW, an epoch, for the tests.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 2 ] || { echo "::error::usage: check-index-baseline.sh <verified-body> <InRelease>" >&2; exit 2; }
[ -n "${INDEX_RECORD:-}" ] || { echo "::error::INDEX_RECORD is not set; what the last publication served cannot be established" >&2; exit 1; }

python3 -I - "$1" "$2" "${INDEX_FLOOR:-$HERE/index-floor.txt}" "$INDEX_RECORD" "${ACCEPT_OLD_INDEX:-}" "${INDEX_NOW:-}" <<'PY'
import datetime
import email.utils
import hashlib
import os
import re
import sys

body_path, signed_path, floor_path, record_path, accept, now_text = sys.argv[1:]
UTC = datetime.timezone.utc
STAMP = "%Y-%m-%dT%H:%M:%SZ"
FUTURE = datetime.timedelta(minutes=10)
WINDOW = datetime.timedelta(days=3)
LIMIT = 1 << 22


def refuse(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def read(path):
    try:
        with open(path, "rb") as handle:
            data = handle.read(LIMIT + 1)
    except OSError as error:
        refuse(f"cannot read {path}: {error.strerror}")
    if len(data) > LIMIT:
        refuse(f"{path} is larger than {LIMIT} bytes, the most this script reads")
    return data


def record_lines(path):
    text = read(path).decode("ascii", "replace")
    return [line for line in text.split("\n") if line.strip() and not line.lstrip().startswith("#")]


def stamp(text, where):
    try:
        return datetime.datetime.strptime(text, STAMP).replace(tzinfo=UTC)
    except ValueError:
        refuse(f"{where} holds a time that is not {STAMP}: {text!r}")


def header(body, name):
    found = re.findall(rf"(?m)^{name}:[ \t]*(.*?)[ \t]*$", body)
    if len(found) != 1:
        refuse(f"the served index does not declare {name} exactly once")
    try:
        value = email.utils.parsedate_to_datetime(found[0])
    except (TypeError, ValueError):
        value = None
    if value is None or value.utcoffset() != datetime.timedelta(0):
        refuse(f"the {name} of the served index is not a time in UTC: {found[0]!r}")
    return value


floor = record_lines(floor_path)
if len(floor) != 1:
    refuse(f"{floor_path} does not hold exactly one line, 'none' or a time")
floor = None if floor[0] == "none" else stamp(floor[0], floor_path)

record = record_lines(record_path)
if record == ["none"]:
    record = None
else:
    parts = record[0].split(" ") if len(record) == 1 else []
    if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{64}", parts[1]):
        refuse(f"{record_path} does not hold exactly one line, 'none' or '<time> <sha256>'")
    record = (stamp(parts[0], record_path), parts[1])

if accept and not re.fullmatch(r"[0-9a-f]{64}", accept):
    refuse("accept_old_index takes the SHA256 of the InRelease to accept, 64 lowercase hexadecimal characters")
if now_text and not now_text.isdigit():
    refuse("INDEX_NOW is not an epoch")
now = datetime.datetime.fromtimestamp(int(now_text), UTC) if now_text else datetime.datetime.now(UTC)

body = read(body_path).decode("utf-8", "replace")
date, until = header(body, "Date"), header(body, "Valid-Until")
digest = hashlib.sha256(read(signed_path)).hexdigest()
served = f"the served index (Date {date.strftime(STAMP)}, SHA256 {digest})"

if accept and accept != digest:
    refuse(f"accept_old_index names the InRelease {accept} and {served} is another one")
# Never set aside: a date that has not come, and the record of the repository.
if date > now + FUTURE:
    refuse(f"{served} is dated in the future")
if floor is not None and date < floor:
    refuse(f"{served} is older than {floor.strftime(STAMP)}, the oldest {floor_path} accepts: an earlier signed index was put back")

reasons = []
if until <= now:
    reasons.append(f"it expired at {until.strftime(STAMP)}")
if record is None:
    if date < now - WINDOW:
        reasons.append(f"no publication has recorded what it served and the index is more than {WINDOW.days} days old")
elif date < record[0]:
    reasons.append(
        f"it is older than the one the last publication recorded, of {record[0].strftime(STAMP)}: "
        f"either the bucket was put back to an earlier signed index, or the edge still serves the copy of before "
        f"that publication, which can last a day; purge the cache and try again"
    )
elif date == record[0] and digest != record[1]:
    reasons.append(f"it has the Date the last publication recorded and other bytes (recorded SHA256 {record[1]})")

if accept:
    why = "; ".join(reasons) if reasons else "it needed no exception"
    message = f"accept_old_index: accepted {served}; {why}"
    print(f"::warning::{message}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(message + "\n")
    sys.exit(0)
if reasons:
    refuse(f"{served} is not accepted: {'; '.join(reasons)}. If it is the right one, start the publish by hand with accept_old_index set to its SHA256, as CONTRIBUTING.md says")
print(f"{served} is not older than what this archive is known to have served")
PY
