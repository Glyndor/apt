#!/usr/bin/env bash
# Run by sync-archive.sh before its first pass, from the repository root and
# with the credentials it has already checked.
#
# The passes over pool/ use --size-only, so an object whose name and size the
# bucket already holds is not uploaded, whatever its bytes are, while the new
# signed index declares the hash of the built file. This compares the two byte
# for byte before anything is written.
#
# A product package is immutable: its pool path carries its version and it is
# uploaded to be kept for a year, so a build that holds other bytes under a
# published name is refused. The keyring package is rebuilt on every run and is
# the one pool object a publish may replace (purge-cache.sh purges its path), so
# a rebuild with other bytes is uploaded here, with a warning, instead of being
# left to --size-only.
#
# The whole of pool/ is downloaded through the bucket's API. An ETag is not the
# hash of an object uploaded in parts, and the served index does not name an
# object left by a publish that was cut before the index landed.
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/pool"
aws s3 sync s3://glyndor-apt/pool/ "$work/pool/" --no-progress
find public/pool -type f -print0 > "$work/built"

refused=0
rebuilt=()
while IFS= read -r -d '' built; do
  key="${built#public/}"
  [ -f "$work/$key" ] || continue
  if cmp -s "$built" "$work/$key"; then continue; fi
  case "$key" in
    pool/main/g/glyndor-archive-keyring/*) rebuilt+=("$key") ;;
    *)
      echo "::error::$key is already in the bucket with other bytes, and a published package is never replaced. Release the change under a new version; remove the object by hand only if no signed index ever declared it."
      refused=1
      ;;
  esac
done < "$work/built"
# Every differing package is named before the refusal, and nothing is written.
[ "$refused" -eq 0 ] || exit 1

for key in "${rebuilt[@]}"; do
  echo "::warning::$key was rebuilt with other bytes under the same name; uploading it"
  aws s3 cp "public/$key" "s3://glyndor-apt/$key" \
    --no-progress --cache-control "public, max-age=31536000, immutable"
done
