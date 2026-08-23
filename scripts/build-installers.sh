#!/usr/bin/env bash
#
# Generate one bootstrap installer per product from scripts/install-template.sh.
#
# The script sets up this archive and installs a package from it, so it belongs
# with the archive rather than with any one product: it is the same script every
# time apart from the package name, and it does not change when a product cuts a
# release. Shipping it as a release asset instead would mean a fix to the
# installer could not reach anyone until the next version was tagged.
#
# Usage: build-installers.sh <out-dir> <product> [<product> ...]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$HERE/scripts/install-template.sh"

OUT_DIR="${1:?usage: build-installers.sh <out-dir> <product> [<product> ...]}"
shift
[ "$#" -gt 0 ] || { echo "::error::no products given" >&2; exit 1; }

[ -f "$TEMPLATE" ] || { echo "::error::missing template: $TEMPLATE" >&2; exit 1; }

# Fail closed on a template that lost its placeholder: it would still be a valid
# shell script, and every product would silently get an installer that installs
# whatever name was left hard-coded in it.
grep -q '@PRODUCT@' "$TEMPLATE" \
	|| { echo "::error::$TEMPLATE has no @PRODUCT@ placeholder" >&2; exit 1; }

mkdir -p "$OUT_DIR"

for product in "$@"; do
	case "$product" in
		*[!a-z0-9.+-]* | '')
			echo "::error::refusing to generate an installer for '$product': a package name is lowercase alphanumerics, dot, plus and hyphen" >&2
			exit 1
			;;
	esac
	out="$OUT_DIR/$product"
	sed "s/@PRODUCT@/$product/g" "$TEMPLATE" > "$out"
	chmod 0755 "$out"
	# A leftover placeholder means the substitution silently did nothing.
	! grep -q '@PRODUCT@' "$out" \
		|| { echo "::error::$out still contains @PRODUCT@" >&2; exit 1; }
	sh -n "$out" || { echo "::error::$out is not valid shell" >&2; exit 1; }
	echo "generated $out"
done
