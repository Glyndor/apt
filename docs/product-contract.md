# What a product release has to carry

The archive rebuilds itself from the latest release of every product in the
`PRODUCTS` line of `.github/workflows/publish.yml`. It admits a package only after
`scripts/verify/verify-debs.sh` has checked it against the organization's release
key and against the release it came from. A product whose release does not meet
what follows is refused, and one refused product stops the refresh of the whole
archive, so each point below is a thing the release has to do, not a preference.

`tests/verify/new-product-end-to-end.test.sh` and `tests/build/new-product-archive.test.sh`
run a minimal package of helmly (two architectures) and of epistle-panel (`all`)
through every point, with a key made for the run and without touching the
real roster. It passes today, so
the day either product publishes, apt needs one edit and no other change.

## What the release carries

- **One `.deb` and one `.deb.sig` for every architecture the roster entry
  declares.** The names are `<product>_<version>_<arch>.deb` and
  `<product>_<version>_<arch>.deb.sig`. A product with one package for every
  architecture is `epistle-panel:all` and carries `epistle-panel_<version>_all.deb`
  and its `.sig`. Two files for one architecture, or none, stop the publish
  (`scripts/verify/roster-has-releases.sh` asks the same question before a merge).
- **No glob character in an asset name** (`*`, `?`, `[`, `]`), and no `/` or `\`.
- **A package no larger than 300 MiB**, checked against the size the release
  announces and again against the bytes written to disk.
- **The product name is the package name.** `Package:` in the control file is the
  product name, the file name starts with `<product>_`, and the name uses
  lowercase letters, digits, `.`, `+` and `-`, at least two characters, starting
  with a letter or a digit.
- **`Version:` is the release tag without its leading `v`.** An epoch (`1:`) and a
  Debian revision that starts with a digit (`-1`) are allowed and left out of the
  comparison. A suffix that starts with a letter, such as `-rc1`, is part of the
  version. A package whose version is another release's is refused, which is what
  stops an old signed package from being attached to a new release.
- **`Architecture:` in the control file is the architecture in the file name.**
  The file name is not part of what is signed, so one signed `amd64` package under
  an `arm64` name is refused.

## The signature

- **`<deb>.sig` is the raw Ed25519 signature, exactly 64 bytes**, over the bytes of
  the `.deb`. A file of any other length is refused before any cryptography, and so
  is one over 4096 bytes.
- **It is made with the organization's release key**, the one in
  `keyring/glyndor-release-ed25519.b64`. A valid signature from another key is
  refused. During a rotation the file lists both keys and a package is admitted if
  either one verifies it.
- **A second signature is optional until the product is listed.** `<deb>.mldsa65.sig`
  is the raw ML-DSA-65 signature over the same bytes, exactly 3309 bytes. It is
  checked in addition to the first one, never instead of it, and a product named in
  `keyring/pq-required-products` is refused without it. The key is not configured
  yet, so a release that carries one is refused until it is.

## What apt does with it

- Each entry of `PRODUCTS` gets a bootstrap installer at `/install/<product>`, with
  no list of its own to join.
- The package is indexed for the architectures of the distribution. An `all`
  package appears in every one of them.
- The archive keeps only the latest version of each package.

## The one edit, on the day

A product joins `PRODUCTS` with its first release and not before, because the
publish stops when it cannot resolve a release. For helmly that is `helmly` (the
architectures of `ARCHITECTURES`), for epistle-panel `epistle-panel:all`. Then
`scripts/verify/roster-has-releases.sh` has to pass against the real release, and
the product's name goes into `keyring/pq-required-products` when the second
signature becomes mandatory for it.
