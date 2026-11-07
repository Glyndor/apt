#!/usr/bin/env bash
# Run from the repository root, after public/ has been built and signed.
# Keep the runner's fail-fast semantics when invoked as a standalone script.
set -e

# Fail closed if any R2 credential is missing rather than syncing to
# the wrong place (or nowhere) silently.
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY GLYNDOR_APT_R2_ENDPOINT; do
  eval "[ -n \"\${$v:-}\" ]" \
    || { echo "::error::$v is not configured."; exit 1; }
done
# Three passes: the Cache-Control differs per file class, and the
# ordering keeps the live archive consistent for clients mid-publish:
# new packages land before the metadata that references them, and old
# packages are removed only after the metadata stopped referencing
# them, so the signed index never points at a package that 404s. That
# ordering is necessary and not sufficient: it says nothing about an
# index file being removed after it is written, which is what #47/#53
# were, hence the read-back verification that closes this job.
#   - pool/ .debs are immutable (the filename carries the version), so
#     cache them for a year; they never change once published.
#   - everything else (the dists/ metadata, index.html, the keyring
#     .deb) shares a fixed name but changes every rebuild. Cache it a
#     day AND purge it from Cloudflare below on every publish, so a
#     fresh release is visible at once; the long TTL is safe because
#     each rebuild (daily + manual) purges, and nothing changes between
#     rebuilds; it just cuts needless origin revalidations.
#
# Passes 1 and 3 use --size-only: a product .deb is built once and
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
# Pass 2 keeps the default comparison (size + modification time; the
# AWS CLI never content-hashes): the dists/ metadata and the
# bucket-root keyring copy are rewritten every rebuild and land with a
# current mtime, so a re-signed index always re-uploads.
#
# Pass 2 carries no --delete, and must not gain one back. With it,
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
# Pass 3 keeps its --delete: superseded .debs are real storage that
# has to go, no pool filename is a prefix of another (they all end in
# .deb and differ before it), and the read-back check at the end of
# this job verifies the pool too, so a recurrence there would be loud
# rather than silent.
# 1. Upload new pool/ packages (no deletions yet).
aws s3 sync public/ s3://glyndor-apt/ \
  --endpoint-url "$GLYNDOR_APT_R2_ENDPOINT" \
  --no-progress --size-only \
  --exclude "*" --include "pool/*" \
  --cache-control "public, max-age=31536000, immutable"
# 2. Publish the new metadata. Deliberately NOT --delete: see below.
aws s3 sync public/ s3://glyndor-apt/ \
  --endpoint-url "$GLYNDOR_APT_R2_ENDPOINT" \
  --no-progress \
  --exclude "pool/*" \
  --cache-control "public, max-age=86400"
# 3. Remove pool/ packages the new metadata no longer references.
aws s3 sync public/ s3://glyndor-apt/ \
  --endpoint-url "$GLYNDOR_APT_R2_ENDPOINT" \
  --delete --no-progress --size-only \
  --exclude "*" --include "pool/*" \
  --cache-control "public, max-age=31536000, immutable"
