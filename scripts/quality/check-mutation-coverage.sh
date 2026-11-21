#!/usr/bin/env bash
# Fail when a refusal in a script of this repository has neither an entry in the
# mutation catalogue nor a written exemption.
#
# The catalogue in tests/mutation/catalog.txt is what the mutation sweep runs,
# and the sweep only ever measures the guards it was told about. A guard nobody
# catalogued is invisible to the one instrument that would say whether a suite
# notices it gone, and an audit found four such guards that could be deleted
# with every suite green. This check closes the set from the other side: it
# reads the scripts, finds every refusal in them, and requires each one to be
# either mutated by an entry or exempted with a reason.
#
# WHAT IS A REFUSAL
#
# A line of code, comments and quoted text aside, that exits with a non-zero
# status: `exit N`, a call of `fail` where the file defines that helper,
# `sys.exit(N)` or `raise SystemExit(N)` in the Python a script carries. The
# refusal is the statement that leads to it: the condition on the same line
# (`[ ... ] || exit 1`) and the lines it continues, or else the block that
# holds it, from its header (`if`, `elif`, a `case` arm, `|| {`, a Python
# `if`/`except`) down to the refusal. A refusal with no enclosing block reaches
# back to the start of the statement before it.
#
# An entry covers a refusal when the text it replaces lies on one of those
# lines. So does an exemption, which names a file, a text in it, and the reason
# the refusals that text reaches have no entry, separated by TAB in
# tests/mutation/exemptions.txt; a text of `*` exempts the whole file. An entry's
# text occurs once, because the runner refuses anything else; an exemption's
# text may occur more than once, for two refusals written alike, and every
# occurrence has to reach a refusal.
#
# An entry whose text is not in its file exactly once, or whose replacement is
# the text itself, is a failure whatever file it names: the sweep cannot apply
# it, and it would say so only after running every entry before it, which is
# half an hour on a pull request and a week on the schedule.
#
# An exemption whose text is not in its file, one occurrence of which reaches no
# refusal, that has no reason, or that names a refusal an entry already covers
# is a failure: an exemption that outlived its premise keeps a hole open after
# the reason for it is gone.
#
# Only a literal non-zero status counts: `exit "$rc"` and `return 1` are not
# read, so a helper that refuses that way is invisible here.
#
# WHAT IS READ
#
# Every shell script under scripts/ and keyring/upgrade/ (by extension, or by
# shebang for a file with none) and .github/workflows/publish.yml, the workflow
# that touches production and that no pull request runs.
#
# Usage: check-mutation-coverage.sh [repo-root]   (default: the current directory)
set -euo pipefail
root="${1:-$PWD}"
python3 -I - "$root" <<'PY'
import os
import re
import sys

root = sys.argv[1]
CATALOG = "tests/mutation/catalog.txt"
EXEMPTIONS = "tests/mutation/exemptions.txt"
WATCHED_DIRS = ("scripts", "keyring/upgrade")
WATCHED_FILES = (".github/workflows/publish.yml",)
SHEBANG = re.compile(r"^#!.*(/| )(sh|bash|dash)(\s|$)")
EXIT = re.compile(r"(?<![\w$.-])exit\s+[1-9][0-9]*\b")
PY_EXIT = re.compile(r"\b(?:sys\.exit|raise\s+SystemExit)\(\s*[1-9][0-9]*\s*\)")
FAIL_CALL = re.compile(r"(?:^|[\s;&|{(])fail(?=\s|$)")
FAIL_DEF = re.compile(r"^\s*fail\s*\(\)\s*\{?")
# The first line of a block: a shell `if`, `elif`, `else`, loop, `case` arm or
# `{`, or a Python statement that ends with a colon. A line with less
# indentation that is none of these (a YAML key, a heredoc that starts the
# Python of a script) is not a block of this code, and a refusal under it is at
# the top level.
HEADER = re.compile(r"^(?:if|elif|else|while|until|for|case|except|try|with|def)\b"
                    r"|(?:\bthen|\bdo|\{|\)|:|\bin)$")
errors = []


def read(rel):
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def is_script(rel):
    name = os.path.basename(rel)
    if name.endswith((".sh", ".bash")):
        return True
    if "." in name:
        return False
    try:
        first = read(rel).split("\n", 1)[0]
    except (OSError, UnicodeDecodeError):
        return False
    return bool(SHEBANG.match(first))


def watched():
    found = []
    for top in WATCHED_DIRS:
        for dirpath, dirnames, names in os.walk(os.path.join(root, top)):
            dirnames.sort()
            for name in sorted(names):
                rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
                if is_script(rel):
                    found.append(rel)
    for rel in WATCHED_FILES:
        if os.path.isfile(os.path.join(root, rel)):
            found.append(rel)
        else:
            errors.append(f"{rel} is watched and does not exist")
    return found


def code_of(line):
    """The line with quoted text and a trailing comment removed."""
    out, quote, i = [], None, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "'\"":
            quote = c
            out.append(" ")
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def indent(line):
    expanded = line.expandtabs(8)
    return len(expanded) - len(expanded.lstrip())


def blank(line):
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def refusals(rel, lines):
    """(first line, refusal line) of every refusal, 0-based."""
    defines_fail = any(FAIL_DEF.match(line) for line in lines)
    found = []
    for n, line in enumerate(lines):
        if blank(line):
            continue
        code = code_of(line)
        if FAIL_DEF.match(line):
            continue
        hit = EXIT.search(code) or PY_EXIT.search(code) \
            or (defines_fail and FAIL_CALL.search(code))
        if not hit:
            continue
        start = statement_start(lines, n)
        before = " ".join(code_of(lines[i]) for i in range(start, n)) + code[:hit.start()]
        if "||" in before or "&&" in before:
            span = (start, n)
        else:
            header = enclosing(lines, start)
            if header is not None and FAIL_DEF.match(lines[header]):
                continue
            span = (header if header is not None else sibling(lines, start), n)
        found.append(span)
    return found


def statement_start(lines, n):
    i = n
    while i > 0:
        stripped = lines[i].strip()
        if stripped.startswith(("||", "&&", "|")) or lines[i - 1].rstrip().endswith("\\"):
            i -= 1
            continue
        break
    return i


def enclosing(lines, n):
    """The header of the block that holds line n, or None at the top level."""
    level = indent(lines[n])
    for i in range(n - 1, -1, -1):
        if blank(lines[i]):
            continue
        if indent(lines[i]) < level:
            head = statement_start(lines, i)
            code = code_of(lines[i]).strip()
            if not HEADER.search(code) and not HEADER.search(code_of(lines[head]).strip()):
                return None
            if code.startswith(("else", "elif")):
                return opening_if(lines, i) or head
            return head
    return None


def opening_if(lines, n):
    level = indent(lines[n])
    for i in range(n - 1, -1, -1):
        if blank(lines[i]) or indent(lines[i]) != level:
            continue
        if lines[i].strip().startswith("if"):
            return statement_start(lines, i)
    return None


def sibling(lines, n):
    level = indent(lines[n])
    for i in range(n - 1, -1, -1):
        if blank(lines[i]):
            continue
        if indent(lines[i]) <= level:
            return statement_start(lines, i)
    return n


def spans_of(text, needle):
    """Lines (first, last) of every occurrence of needle."""
    found, at = [], text.find(needle) if needle else -1
    while at >= 0:
        first = text.count("\n", 0, at)
        found.append((first, first + needle.count("\n")))
        at = text.find(needle, at + 1)
    return found


def span_of(text, needle):
    """Lines of the one occurrence of needle, or None."""
    found = spans_of(text, needle)
    return found[0] if len(found) == 1 else None


def entries():
    found = {}
    try:
        body = read(CATALOG)
    except OSError as exc:
        errors.append(f"cannot read {CATALOG}: {exc}")
        return found
    for raw in body.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 5:
            errors.append(f"{CATALOG}: a line does not hold five fields: {raw}")
            continue
        found.setdefault(fields[1], []).append((fields[0], fields[2]))
        applies(*fields[:4])
    return found


def applies(ident, rel, old, new):
    """The runner's own conditions for applying an entry, checked without running it."""
    try:
        count = read(rel).count(old)
    except OSError:
        errors.append(f"{CATALOG}: {ident}: {rel} cannot be read, so the sweep cannot apply the entry")
        return
    if count != 1:
        errors.append(f"{CATALOG}: {ident}: its text is in {rel} {count} time(s), not once, "
                      "so the sweep cannot apply the entry")
    elif old == new:
        errors.append(f"{CATALOG}: {ident}: it replaces its text with itself, so the sweep cannot apply the entry")


def exemptions():
    found = []
    if not os.path.isfile(os.path.join(root, EXEMPTIONS)):
        return found
    for number, raw in enumerate(read(EXEMPTIONS).splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 3 or not all(f.strip() for f in fields):
            errors.append(f"{EXEMPTIONS}:{number}: not `file<TAB>text<TAB>reason`: {raw}")
            continue
        found.append((number, fields[0], fields[1], fields[2]))
    return found


def overlaps(a, b):
    return a[0] <= b[1] and b[0] <= a[1]


files = watched()
catalogued = entries()
exempt = exemptions()
total = covered = exempted = 0
uncovered = []
used = set()
for rel in files:
    text = read(rel)
    lines = text.split("\n")
    marks = []
    for ident, old in catalogued.get(rel, []):
        where = span_of(text, old)
        if where is not None:
            marks.append(where)
    whole = [e for e in exempt if e[1] == rel and e[2] == "*"]
    parts = [(e, spans_of(text, e[2])) for e in exempt if e[1] == rel and e[2] != "*"]
    for number, _, needle, _ in (e for e, where in parts if not where):
        errors.append(f"{EXEMPTIONS}:{number}: its text is not in {rel}: {needle}")
    if whole and catalogued.get(rel):
        errors.append(f"{EXEMPTIONS}:{whole[0][0]}: {rel} is exempt as a whole and has entries; exempt its refusals one by one")
    spans = refusals(rel, lines)
    for e, where in parts:
        for occurrence in where:
            if not any(overlaps(span, occurrence) for span in spans):
                errors.append(f"{EXEMPTIONS}:{e[0]}: its text at {rel}:{occurrence[0] + 1} reaches no refusal; delete it or narrow it")
    for span in spans:
        total += 1
        hit_entry = any(overlaps(span, m) for m in marks)
        hits = [e for e, where in parts if any(overlaps(span, w) for w in where)]
        for e in hits:
            used.add(e[0])
            if hit_entry:
                errors.append(f"{EXEMPTIONS}:{e[0]}: {rel}:{span[0] + 1} has an entry; delete the exemption")
        if whole:
            used.add(whole[0][0])
        if hit_entry:
            covered += 1
        elif hits or whole:
            exempted += 1
        else:
            uncovered.append((rel, span, lines[span[1]].strip()))
for number, rel, needle, _ in exempt:
    if rel not in files:
        errors.append(f"{EXEMPTIONS}:{number}: {rel} is not a script this check reads")
    elif number not in used and not any(f"{EXEMPTIONS}:{number}:" in e for e in errors):
        errors.append(f"{EXEMPTIONS}:{number}: it reaches no refusal in {rel}; delete it")
if not total:
    errors.append("no refusal found in any script, so this check would pass having looked at nothing")
for rel, (first, last), line in uncovered:
    errors.append(f"{rel}:{first + 1}-{last + 1}: a refusal with no entry in {CATALOG} "
                  f"and no exemption in {EXEMPTIONS}: {line}")
for message in errors:
    print(f"::error::{message}")
if errors:
    sys.exit(1)
print(f"{total} refusal(s) in {len(files)} script(s): {covered} catalogued, {exempted} exempt.")
PY
