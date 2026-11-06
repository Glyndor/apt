#!/usr/bin/env bash
#
# The keyring package's version has to move when the generator changes.
#
# The version is what tells apt there is something new: apt compares the
# version in the index with the one it has installed and only then fetches the
# file. A generator change that does not move the version produces a different
# package under a name apt already knows, so the change reaches the archive
# and no client, silently. That is the failure this file exists to catch.
#
# The generator decides the bytes as much as the files it installs do: it
# writes the control file and the conffiles, and it fixes the modes and the
# paths of everything the package carries. Tracking only what lives under
# keyring/ left it out, so the archive could serve a keyring package that no
# installed client would ever fetch.
#
# Three kinds of case:
#
#   * changing the generator moves the version, changes the bytes, and the
#     change is visible in what the package carries -- the acceptance;
#   * every file the build reads is version-tracked, so a template that
#     generates the control file or the conffiles cannot join the build
#     without joining the list;
#   * a generator that does not track itself reproduces the failure, which is
#     what makes the acceptance mean anything: a case that passes for a
#     reason other than the fix proves nothing.
#
# The build reads git history to derive its version, so the cases run against
# a throwaway repository built here rather than against this checkout.
#
# Requires: gpg, dpkg-deb, dpkg, git.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Where the generator lives, relative to the repository root.
GENERATOR="scripts/build/build-keyring.sh"

# The two literals of the generator that the cases below have to name. Held in
# variables so the patterns are the text they are, not the text the shell
# would have expanded.
HERE_PREFIX="\"\$HERE/"
GEN_ENTRY="\"\$GENERATOR_REL\""

pass=0
fail=0

ok() {
	echo "ok   - $1"
	pass=$((pass + 1))
}

no() {
	echo "FAIL - $1"
	fail=$((fail + 1))
}

# A repository the build can run in: the generator under test plus the
# keyring inputs, committed, so the version has history to read.
fixture() { # $1=dir  $2=generator to install
	local d="$1"
	mkdir -p "$d/scripts/build" "$d/keyring/upgrade"
	cp "$2" "$d/scripts/build/build-keyring.sh"
	chmod 0755 "$d/scripts/build/build-keyring.sh"
	cp -r "$HERE"/keyring/* "$d/keyring/"
	git -C "$d" init -q
	git -C "$d" add -A
	git -C "$d" -c user.name=test -c user.email=test@example.invalid \
		commit -qm "fixture"
}

# Build in a repository and print the version of the package that came out.
build() { # $1=repo  $2=out dir
	mkdir -p "$2"
	"$1/scripts/build/build-keyring.sh" "$2" >/dev/null
	dpkg-deb --field "$2/glyndor-archive-keyring.deb" Version
}

# Commit whatever is in the tree, with a date of its own so the case cannot
# race the clock. The date is later than the fixture's own commit, so a
# change the version does not track shows up as a version that did not move.
commit_change() { # $1=repo  $2=date
	git -C "$1" add -A
	GIT_COMMITTER_DATE="$2" GIT_AUTHOR_DATE="$2" \
		git -C "$1" -c user.name=test -c user.email=test@example.invalid \
		-c commit.gpgsign=false commit -qm "change the generator"
}

# Change the generator the way a maintainer would: a sentence in the
# description the package carries. The control file is generated from the
# script, so this changes the bytes of the package.
probe_change() { # $1=repo
	sed -i \
		's|^Description: GPG key and apt source for the Glyndor repository$|Description: GPG key and apt source for the Glyndor repository (probe)|' \
		"$1/scripts/build/build-keyring.sh"
	if ! grep -q '(probe)' "$1/scripts/build/build-keyring.sh"; then
		no "the probe changed the generator at all"
		return 1
	fi
}

# --- changing the generator moves the version --------------------------------

REPO="$WORK/repo"
fixture "$REPO" "$HERE/$GENERATOR"

before="$(build "$REPO" "$WORK/out-before")"

probe_change "$REPO"
commit_change "$REPO" "2032-01-02T03:04:05+0000"
after="$(build "$REPO" "$WORK/out-after")"

# dpkg's comparison is the one apt uses to decide that an installed package
# has something newer to install, so this is the question "does apt see this
# as an upgrade" asked the way apt would ask it.
if dpkg --compare-versions "$after" gt "$before"; then
	ok "a change to the generator moves the version ($before -> $after)"
else
	no "a change to the generator moves the version (stayed $before, then $after)"
fi

# A version on its own is a claim about a number. The bytes have to move as
# well, or the version would be describing a package that does not exist.
if cmp -s "$WORK/out-before/glyndor-archive-keyring.deb" \
	"$WORK/out-after/glyndor-archive-keyring.deb"; then
	no "and the change reaches the bytes of the package"
else
	ok "and the change reaches the bytes of the package"
fi

# And the change has to be the one that was made, in the part of the package
# the generator writes. Otherwise a build that produced the same bytes under
# a new version would satisfy the case above.
# The field is read into a variable first. dpkg-deb piped into `grep -q` is
# a race under pipefail: grep exits at the first match, dpkg-deb can still be
# writing, gets SIGPIPE and the pipeline reports 141 for a correct package.
# It failed about 3 percent of the runs.
description="$(dpkg-deb --field "$WORK/out-after/glyndor-archive-keyring.deb" Description)"
if grep -q '(probe)' <<< "$description"; then
	ok "and the package carries the new description"
else
	no "and the package carries the new description"
fi

# --- every file the build reads is version-tracked ---------------------------
#
# The list, read out of the generator. One item per line and the closing
# parenthesis on a line of its own: the generator keeps that shape so this
# check has something to read.
tracked_inputs() { # $1=generator
	sed -n '/^VERSION_INPUTS=(/,/^)$/p' "$1" \
		| sed -e 's/^[[:space:]]*//' -e '/^VERSION_INPUTS=(/d' -e '/^)$/d' \
		| tr -d '"' \
		| grep -v '^$' \
		| sed "s|^\$GENERATOR_REL\$|$GENERATOR|"
}

# The repository paths the generator reads, as literals in its source.
read_paths() { # $1=generator
	{
		grep -oE '"[^"[:space:]]*/[^"[:space:]]*"' "$1" || true
	} | tr -d '"' \
		| sed -e "s|${HERE_PREFIX}||" \
		| awk '!/^\// && !/^\$/ && !/:/ && !/\.\./' \
		| LC_ALL=C sort -u
}

tracked="$(tracked_inputs "$HERE/$GENERATOR")"

if grep -qxF "$GENERATOR" <<< "$tracked"; then
	ok "the generator is among the version-tracked inputs"
else
	no "the generator is among the version-tracked inputs"
fi

# A template that generates the control file or the conffiles is a read like
# any other. Without this it would change the package without moving the
# version, which is the failure the tracked list exists to prevent.
#
# keyring/version is the one path that is read on purpose and not tracked:
# it is the base version, so changing it moves the version by changing the
# base, and tracking it as well would only give the same decision a second
# date to argue about.
untracked=""
while IFS= read -r p; do
	[ -n "$p" ] || continue
	[ "$p" = "keyring/version" ] && continue
	if grep -qxF "$p" <<< "$tracked"; then
		continue
	fi
	untracked="$untracked $p"
done <<EOF
$(read_paths "$HERE/$GENERATOR")
EOF

if [ -z "$untracked" ]; then
	ok "every file the build reads is version-tracked"
else
	no "every file the build reads is version-tracked (not tracked:$untracked)"
fi

# --- the control of the control ----------------------------------------------
#
# A generator that does not track itself has to reproduce the failure. If the
# version moved even there, the case above would be satisfied by something
# other than the fix, and the file would be a green that never looked.
#
# The sabotage is a copy with the generator dropped from the list. The diff
# is printed, because a sabotage that did not apply would leave the case
# green for the wrong reason.

SAB="$WORK/sabotaged-keyring.sh"
sed "/${GEN_ENTRY}/d" "$HERE/$GENERATOR" > "$SAB"

if cmp -s "$HERE/$GENERATOR" "$SAB"; then
	no "the sabotage is inert (the generator it copies had already lost the entry)"
else
	ok "the sabotage is not inert: it took the generator out of the tracked list"
	echo "    sabotage diff:"
	diff -u "$HERE/$GENERATOR" "$SAB" | sed -n '3,12p' || true
fi

SREPO="$WORK/sabotaged-repo"
fixture "$SREPO" "$SAB"

sab_before="$(build "$SREPO" "$WORK/sab-out-before")"
probe_change "$SREPO"
commit_change "$SREPO" "2032-01-02T03:04:05+0000"
sab_after="$(build "$SREPO" "$WORK/sab-out-after")"

if [ "$sab_before" = "$sab_after" ]; then
	ok "a generator that does not track itself keeps the version still ($sab_after)"
else
	no "a generator that does not track itself keeps the version still (moved $sab_before -> $sab_after)"
fi

# The bytes do change even there. That is the finding in one line: a
# different package under a version apt has already seen.
if cmp -s "$WORK/sab-out-before/glyndor-archive-keyring.deb" \
	"$WORK/sab-out-after/glyndor-archive-keyring.deb"; then
	no "while the bytes it produces do change"
else
	ok "while the bytes it produces do change"
fi

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
