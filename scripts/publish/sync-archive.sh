#!/usr/bin/env bash
# Run from the repository root, after public/ has been built and signed.
# Keep the runner's fail-fast semantics when invoked as a standalone script.
set -e

# Fail closed if any R2 credential is missing rather than syncing to
# the wrong place (or nowhere) silently.
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ENDPOINT_URL; do
  eval "[ -n \"\${$v:-}\" ]" \
    || { echo "::error::$v is not configured."; exit 1; }
done
# The R2 endpoint comes from a secret like the keys, so it travels the way
# they do, in the environment (AWS_ENDPOINT_URL), and not as --endpoint-url
# in argv, which any process on the machine can read in /proc/<pid>/cmdline.
# A CLI too old to read that variable would send the requests to AWS
# instead, so it is refused: AWS CLI v2 reads it from 2.13.0, v1 from 1.29.0.
cli="$(aws --version 2>&1 | sed -n 's|^aws-cli/\([0-9]*\)\.\([0-9]*\)\..*|\1 \2|p')"
read -r cli_major cli_minor <<< "$cli" || true
case "${cli_major:-}:${cli_minor:-}" in
  2:* ) [ "$cli_minor" -ge 13 ] ;;
  1:* ) [ "$cli_minor" -ge 29 ] ;;
  * ) false ;;
esac || { echo "::error::this AWS CLI ($(aws --version 2>&1 | head -n 1)) does not read AWS_ENDPOINT_URL; refusing to sync to an endpoint it would ignore."; exit 1; }
# Two other variables decide the endpoint ahead of it: AWS_ENDPOINT_URL_S3
# takes precedence for S3, and AWS_IGNORE_CONFIGURED_ENDPOINT_URLS makes the
# CLI ignore both and talk to AWS. Either one set is refused, empty or not.
for v in AWS_ENDPOINT_URL_S3 AWS_IGNORE_CONFIGURED_ENDPOINT_URLS; do
  if [ -n "${!v+set}" ]; then
    echo "::error::$v is set, and it would decide the S3 endpoint instead of AWS_ENDPOINT_URL; refusing to sync."
    exit 1
  fi
done
# Five passes: the Cache-Control differs per file class, and the
# ordering keeps the live archive consistent for clients mid-publish:
# new packages land before the metadata that references them, and old
# packages are removed only after the metadata stopped referencing
# them, so the signed index never points at a package that 404s.
#
# Under dists/ the order is: the by-hash copies, then the signed index
# (InRelease, and the Release / Release.gpg pair), then the index files
# under their fixed names. A client that offers by hash asks for the
# copies the InRelease it read declares; the old ones are never deleted
# and the new ones land before the InRelease that names them, so it
# never sees a mismatch, whichever InRelease it read. A client that
# asks by the fixed name (one holding an InRelease from before
# Acquire-By-Hash, which is every client during the first publish that
# carries it) finds the fixed names unchanged for as long as the old
# InRelease is the one served, and only a client that read the old
# InRelease and then asks for Packages after pass 4 has replaced it can
# see a mismatch: the window every publish had before, and no longer.
# Putting the signed index after the fixed names instead would leave
# the old InRelease served over new Packages for the whole of that pass,
# and for as long as a publish cut between the two stays cut.
#
# A publish cut before the new InRelease lands leaves the previous index
# served with everything it declares. Cut after it and before pass 4
# ends, it leaves the new InRelease over some old fixed-name files: a
# client that offers by hash is not affected, and the read-back at the
# end of the job fails on those files, as the six-hourly health check
# does until the next publish.
#
# The ordering is necessary and not sufficient: it says nothing about an
# index file being removed after it is written, which is what #47/#53
# were, hence the read-back verification that closes this job.
#
# The Cache-Control of each class of file:
#   - pool/ .debs are immutable (the filename carries the version), so
#     cache them for a year; they never change once published.
#   - the by-hash copies under dists/ are named for the SHA256 of their
#     content, so a name never changes its bytes: a year as well, and
#     no purge.
#   - everything else (the dists/ metadata, index.html, the keyring
#     .deb, install/) shares a fixed name but changes every rebuild.
#     It is uploaded with max-age=86400, and that is what the edge
#     caches it by: measured on 2026-11-21, InRelease was a HIT at the
#     edge with an Age of 13457 s, which a 300 s edge lifetime would
#     not allow. What the edge tells clients is something else:
#     `public, max-age=300` on every file outside pool/, on a HIT and
#     on a HEAD it answers without its cache, while pool/ keeps the
#     header uploaded with it. That 300 is set in the configuration
#     of the zone, which this repository cannot read, and not by this
#     upload. So a client or a proxy revalidates every five minutes,
#     the edge would serve a stale copy for up to a day, and the purge
#     below, not the TTL, is what makes a publish visible.
#
# Passes 1, 2 and 5 use --size-only: a by-hash name is the hash of its
# content, so the same name is the same bytes. A product .deb is built once and
# published, and its version is baked into the filename, so a size
# match is sufficient proof pool/ already carries the same object.
#
# That reasoning covers product .debs and nothing else, which is the
# part that bit. The keyring package is ALSO in pool/ and is NOT a
# release: publish.yml rebuilds it every run, under a filename that
# only moves when one of its inputs changes -- the files it installs
# and the generator that writes them. So "same name, same size,
# different content" needs no immutability violation to happen here;
# it just needs a non-deterministic build, which is what #55 was. When
# the rebuild landed on the same size, --size-only skipped the upload
# while reprepro had already written the new hash into the signed
# index, and the archive served a package its own index rejected.
# build-keyring.sh is reproducible now (stamped from the commit of its
# inputs, locked by tests/build/build-keyring.test.sh and
# tests/build/keyring/build-keyring-generator.test.sh), which is what makes
# --size-only sound for that object too. If anything else that is
# regenerated per run is ever added under pool/, it needs the same
# property or it does not belong in these passes.
#
# Passes 3 and 4 keep the default comparison (size + modification time;
# the AWS CLI never content-hashes): the dists/ metadata and the
# bucket-root keyring copy are rewritten every rebuild and land with a
# current mtime, so a re-signed index always re-uploads.
#
# No pass over dists/ carries --delete, and none may gain one. With it,
# sync emitted an upload AND a delete for the same key in the same
# pass and let them race: run 29718989917 uploaded binary-arm64's
# Packages at .2227 and deleted it at .2682, leaving the freshly
# signed index declaring a file the bucket no longer had. Every key it
# did that to was a strict prefix of a sibling (Packages of
# Packages.gz, Release of Release.gpg) and no other key ever was, so
# the comparator appears to classify a prefix key as local-only and
# remote-only at once. This is what #47 actually was, not the R2
# visibility lag recorded there at the time.
#
# Do NOT "fix" this by splitting the pass into upload-then-delete:
# that makes the delete deterministically last and turns an
# intermittent breakage into one on every publish. Dropping --delete
# removes the race outright; the cost is that an index file reprepro
# stops emitting lingers in the bucket, which is harmless because apt
# only ever fetches what the signed InRelease declares.
#
# The same absence keeps every by-hash copy a publish ever uploaded:
# nothing deletes one, so a client that read an InRelease of any earlier
# publish (a proxy or a cache can hand one out until its Valid-Until)
# still finds the copies it declares. A copy only appears when an index
# changes, which is when a product releases, and an index is a few KiB,
# so the kept set grows by kilobytes per release. Pruning them would need
# a delete by age, the shape prune-installers.sh uses for install/, and
# that is not worth a second way to delete from the archive while the
# set is this small.
#
# Pass 5 keeps its --delete: superseded .debs are real storage that
# has to go, no pool filename is a prefix of another (they all end in
# .deb and differ before it), and the read-back check at the end of
# this job verifies the pool too, so a recurrence there would be loud
# rather than silent.
# 1. Upload new pool/ packages (no deletions yet).
aws s3 sync public/ s3://glyndor-apt/ \
  --no-progress --size-only \
  --exclude "*" --include "pool/*" \
  --cache-control "public, max-age=31536000, immutable"
# 2. Upload the by-hash copies of the new index files, before anything that
#    names them.
aws s3 sync public/ s3://glyndor-apt/ \
  --no-progress --size-only \
  --exclude "*" --include "dists/*/by-hash/*" \
  --cache-control "public, max-age=31536000, immutable"
# 3. Publish the signed index, after the copies it declares and before
#    the fixed-name index files.
aws s3 sync public/ s3://glyndor-apt/ \
  --no-progress \
  --exclude "*" --include "dists/stable/InRelease" --include "dists/stable/Release" --include "dists/stable/Release.gpg" \
  --cache-control "public, max-age=86400"
# 4. Publish the rest of the metadata, the index files under their fixed
#    names among it. Deliberately NOT --delete: see above.
aws s3 sync public/ s3://glyndor-apt/ \
  --no-progress \
  --exclude "pool/*" --exclude "dists/*/by-hash/*" \
  --exclude "dists/stable/InRelease" --exclude "dists/stable/Release" --exclude "dists/stable/Release.gpg" \
  --cache-control "public, max-age=86400"
# 5. Remove pool/ packages the new metadata no longer references.
aws s3 sync public/ s3://glyndor-apt/ \
  --delete --no-progress --size-only \
  --exclude "*" --include "pool/*" \
  --cache-control "public, max-age=31536000, immutable"
