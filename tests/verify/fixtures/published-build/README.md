# Signed read-back snapshots

`old` carries podup 1.0.0; `new` carries 2.0.0. Both are complete synthetic
archives signed by the same public test key in `archive-key.asc`, including the
bootstrap package's detached signature. The `.deb.txt` files are synthetic
payloads, copied to their declared `.deb` paths by the suite. They are not
installable packages: read-back checks their exact bytes, size and signatures.

The fixtures use OpenPGP v4 RSA-3072/SHA-256 signatures, created on 2026-11-05,
with a non-expiring test key. No private key is retained. Keeping signed bytes
lets the regression test use real GPG verification without a signing agent or
network. Each snapshot is first accepted by the complete verifier with its own
digest; the old snapshot must then be rejected against the new build's digest.
