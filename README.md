# Glyndor apt repository

Signed apt repository for Glyndor's Debian/Ubuntu packages, served at
**https://apt.glyndor.net** (amd64).

## Install

```bash
curl -fsSLO https://apt.glyndor.net/glyndor-archive-keyring.deb
sudo dpkg -i glyndor-archive-keyring.deb
sudo apt update
sudo apt install podup        # or any other Glyndor package
```

The `glyndor-archive-keyring` package installs the signing key at
`/usr/share/keyrings/glyndor.gpg` and the source list at
`/etc/apt/sources.list.d/glyndor.sources`. Because the key ships as a package,
apt owns it — key renewals arrive automatically through `apt upgrade`.

## How it works

`.github/workflows/publish.yml` rebuilds the repository from the latest release
of each product listed in its `PRODUCTS` variable. It downloads each product's
amd64 `.deb` release asset, builds the keyring package, assembles a signed
`reprepro` repository, and publishes it to the `gh-pages` branch. The repo is
rebuilt fresh each run, so it always carries exactly the current version of
every package (no old-version support).

Triggers: manual (`workflow_dispatch`), a daily schedule, and a
`repository_dispatch` of type `product-released` that a product's release
workflow can send for an immediate refresh.

## Adding a product

1. Ensure the product's release attaches an amd64 `*_amd64.deb` asset.
2. Add its repo name to `PRODUCTS` in `publish.yml`.
3. Run the workflow.

## Signing key

Dedicated Ed25519 OpenPGP key. Public half: `keyring/glyndor-apt-key.asc`.
Private half: org secret `GLYNDOR_APT_GPG_PRIVATE_KEY` (scoped to this repo).
`build/build-repo.sh` fails closed if the committed public key does not match
the signing secret. Rotating or renewing the key: bump `keyring/VERSION`,
replace the secret and `glyndor-apt-key.asc`, and re-run the workflow — clients
pick up the new keyring via `apt upgrade`.
