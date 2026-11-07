# Release order fixtures

The suite reuses `../published-build/{old,new}` (tests/fixtures/verify) and its public key for the
1.0.0/2.0.0 acceptance, rollback, corruption and digest cases.

These additional synthetic snapshots carry only Packages metadata (no real
software). Their non-expiring RSA-2048 test key is in `archive-key.asc`.
OpenPGP v4 RSA/SHA256 signatures were generated offline on 2026-11-06 using
Python cryptography; the ephemeral private key was not saved. The suite uses
real gpg/gpgv, never a signature mock. The old fixture key also provides an
independent trust anchor for rejecting signatures from this other key.

- `revision`: 5.16.0-1.
- `epoch`: 2:5.16.0-1.
- `multi`: amd64 1.0.0 and arm64 2.0.0.
- `description`: indented Package/Version lines inside a description.
- `oversized`: a valid signed body padded beyond 1 MiB. InRelease.gz is gzip
  compressed solely to keep the repository small; it is expanded before curl
  reads it. Raising the cap must make the real script accept its signature.
- `near-cap`: the matching positive control within 4 KiB below that limit;
  lowering the cap by 4 KiB must reject it. Padding lines stay below GPG's
  independent cleartext line-length limit.

`harness.sh` adapts the local server/readiness pattern from
`../verify-published-fixture.sh`, binding port zero in the server to avoid a
port allocation race. HTTP is the default; `RELEASE_ORDER_TEST_TRANSPORT=file`
is an explicit restricted-environment diagnostic and prints SIN VERIFICAR for
HTTP. It does not count HTTP or 404 coverage as verified.

`mutate.py` edits only disposable copies, requires exactly one matching guard,
and each control prints a nonempty diff and the original assertion turning
red. The outer suite succeeds only when every control is detected. For the
size guard, the remaining SHA256 guard rejects the modified bytes, but the
size-specific assertion must fail. The same-size case separately proves that
neutralizing SHA256 admits changed bytes.
