# Glyndor apt repository

Signed apt repository for Glyndor's Debian/Ubuntu packages, served at
**https://apt.glyndor.net** (amd64, arm64).

## Install

```bash
curl -fsSLO https://apt.glyndor.net/glyndor-archive-keyring.deb
sudo dpkg -i glyndor-archive-keyring.deb
sudo apt update
sudo apt install podup        # or any other Glyndor package
```

The keyring package installs the signing key and the source list, and ships the
key as a package — so renewals arrive automatically through `apt upgrade`.

## Adding a product

A product needs **no secrets and no access to this repo**. Its release just
attaches, per architecture, a signed `<name>_<version>_<arch>.deb` and its
detached `<deb>.sig` (signed with the shared Glyndor release key). Then add the
repo name to `PRODUCTS` in `.github/workflows/publish.yml` and run the workflow.

`publish.yml` rebuilds the whole repository fresh from the latest release of
every product — the current version only, no old-version support.

## Keys

Two distinct keys, never conflated:

- **Archive key** (GPG, secret `GLYNDOR_APT_GPG_PRIVATE_KEY`) — signs the
  repository metadata; its public half ships in `glyndor-archive-keyring.deb`.
  Rotate by bumping `keyring/VERSION`, replacing the secret and
  `keyring/glyndor-apt-key.asc`, and re-running the workflow.
- **Release key** (Ed25519, `keyring/glyndor-release-ed25519.b64`) — shared
  across all products; every `.deb` is verified against it before it enters the
  archive. A missing or invalid signature fails the publish closed.
