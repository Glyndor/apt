#!/usr/bin/env bash
#
# The architecture list is written in three places, and the three must agree:
#
#   .github/workflows/publish.yml   ARCHITECTURES -- what the publish downloads
#   scripts/build-repo.sh           the reprepro distribution -- what it indexes
#   keyring/glyndor.sources         what a client asks the archive for
#
# publish.yml already says they must match. Saying so is not enforcing it. The
# three drift in the direction that is hardest to notice: add an architecture to
# the workflow and the keyring but miss the reprepro block, and the publish
# downloads the new .deb, reprepro silently declines to index an architecture its
# distribution does not declare, and clients ask for a Packages that was never
# written. Nothing fails. The archive just does not serve the thing that was
# added, and the machines asking for it get a 404 on every `apt update`.
#
# Comparing them here rather than deriving one from the others on purpose: the
# reprepro block is a config file it parses itself and the sources stanza is a
# file apt parses, so neither can read a shell variable. What can be shared is
# the assertion that they say the same thing.
#
# Requires: nothing beyond coreutils and grep.
set -u

cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0

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

# Sorted under a fixed collation so "arm64 amd64" and "amd64 arm64" compare
# equal: the three files are read by three different tools and none of them
# cares about order, so a diff in order is not a diff in meaning.
normalise() { tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }

workflow_arches="$(grep -oE '^[[:space:]]*ARCHITECTURES:[[:space:]]*"[^"]*"' \
	.github/workflows/publish.yml | head -1 | sed 's/.*"\(.*\)"/\1/' | normalise)"

# The reprepro distribution block, not any other Architectures: line that might
# appear in a comment or a fixture further down the script.
reprepro_arches="$(awk '
	/^Codename:/ { in_dist = 1 }
	in_dist && /^Architectures:/ { sub(/^Architectures:[[:space:]]*/, ""); print; exit }
' scripts/build-repo.sh | normalise)"

sources_arches="$(grep -oE '^Architectures:.*' keyring/glyndor.sources \
	| head -1 | sed 's/^Architectures:[[:space:]]*//' | normalise)"

check "publish.yml declares an architecture list" "1" \
	"$([ -n "$workflow_arches" ] && echo 1 || echo 0)"
check "the reprepro distribution declares one" "1" \
	"$([ -n "$reprepro_arches" ] && echo 1 || echo 0)"
check "keyring/glyndor.sources declares one" "1" \
	"$([ -n "$sources_arches" ] && echo 1 || echo 0)"

check "reprepro indexes exactly what the publish downloads" \
	"$workflow_arches" "$reprepro_arches"
check "clients ask for exactly what reprepro indexes" \
	"$reprepro_arches" "$sources_arches"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
