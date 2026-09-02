# Threat model

What this archive protects, against whom, with which control, and how each
control is known to work. The README says how the archive is built and what to
verify; this page is the assessor's view: one row per threat, the control that
answers it, and the evidence that the control is real. Residual risks come last,
on purpose.

Evidence is of three kinds: a **test** is a case under `tests/` that fails when
the control is removed from the script it covers; a **gate** is a required
status check or a step the publish cannot pass; a **measurement** is a number or
an outcome read off a real run, with the date.

## Assets

| Asset | Where | Why it matters |
|---|---|---|
| The signed index (`InRelease`, `Release`, `Release.gpg`) | the R2 bucket behind `apt.glyndor.net` | what every client's `apt update` trusts, through the archive key it already holds |
| The packages in `pool/` | the same bucket, served immutable for a year | what `apt install` runs as root |
| The archive signing key | a CI secret in this repository only | signs the index; its public half ships in `glyndor-archive-keyring` |
| The organization's release key (public half) | `keyring/glyndor-release-ed25519.b64` | the trust anchor that admits a product's `.deb` into the archive |
| The bootstrap installer served at `install/<product>` | generated from one template, served from the bucket | a root shell one-liner every product's README points at |
| The keyring package | rebuilt every run, same filename until the key changes | the one object in `pool/` where "same name, different bytes" is possible |

## Adversaries considered

- **A compromised or buggy release of one product**, signed with the shared release key.
- **A network position** between a client and the edge, or between the publish job and GitHub.
- **A poisoned edge cache**, serving an old object under an immutable name.
- **A hostile package** with a maintainer script, reaching a client before its key is checked.
- **A third-party dependency** installed by the publish job beside the signing key.

Not considered: an adversary holding the archive signing key, an adversary holding the R2 credentials, and a compromise of Debian's own archive, which the runner image trusts before this repository runs a line.

## Threats and controls

### Admission: what gets into the archive

| Threat | Control | Evidence |
|---|---|---|
| An unsigned or tampered `.deb` is served | every `.deb` must carry a detached Ed25519 signature that verifies against the release key file; a missing, invalid, oversized or malformed signature fails the publish | test: `tests/verify-debs.test.sh`, each refusal asserting which refusal |
| A release of product A ships a `.deb` whose control field says it is product B | each product is downloaded into its own directory and verified against its own name: the control `Package:` field and the filename prefix must both match the product that released it | test: the control-field case uses a fixture that breaks only that rule, so the filename check cannot answer for it |
| A product ships a package under the keyring's reserved name | `glyndor-archive-keyring` is refused by both the control field and the filename | test: two cases in the same suite |
| A trust file with no key, or one that does not exist, verifies against nothing | both are refused as such, with the reason named | test: cases 14 and 15 |
| A keyring package with no usable key is built and served | the build refuses an armoured file that dearmors cleanly but carries no public key | test: `tests/build-keyring.test.sh`, fixture is a detached signature block |

### Publication: what is served, and whether it is what was built

| Threat | Control | Evidence |
|---|---|---|
| The signed index declares a file the bucket does not have (a race inside the sync) | the sync runs in three ordered passes, the metadata pass carries no `--delete`, and the run ends by reading the live archive back: signature first, then every declared size and hash, down to the pool | test: `tests/verify-published.test.sh`, 20 cases against a synthetic archive over a local HTTP server; measurement: the read-back caught the race on run 29718989917 before the fix |
| An index that verified but declares too much turns the read-back into an unbounded download | the read-back caps entries, per-object size and total pool bytes | test: the caps are exercised by lowering them below what the fixture declares |
| A stale object at the edge under an immutable name | the purge list is derived from the `Release` and `Packages` files the run built, pool included, and split to Cloudflare's per-request limit | test: `tests/purge-cache.test.sh`; measurement: 14 URLs in one request today, 36 in two for the full roster |
| The keyring package changes bytes under the same name and the size-only sync skips it | the package is built byte-reproducibly from the key's commit date, so equal bytes are equal by construction and different inputs move the version | test: two builds a moment apart must be identical; the version must track every packaged input |
| A clock- or locale-dependent build ships a page missing a package | `LC_ALL=C` wherever a script sorts or compares | test: `tests/locale-pinned.test.sh`, behavioural half under a UTF-8 locale that does collapse the names |
| The archive silently stops refreshing | `Valid-Until` of fourteen days on the signed index, so a stalled publish expires rather than freezes; a health check every six hours fails on a stale or unreachable index; a freshness watcher fails when the publish cron itself stops | gate: `health-check.yml`, `freshness.yml`; measurement: the schedule watchers fired for their reason before promotion |

### The client's first step

| Threat | Control | Evidence |
|---|---|---|
| The bootstrap keyring is substituted on the way to the client | the generated installer extracts the package without running it, reads every fingerprint in it, and refuses unless every one is a fingerprint it was told to expect; nothing is installed before that | test: `tests/install-template-behaviour.test.sh`, 48 cases with a real `gpg` and a sandboxed `PATH`, including a keyring carrying the published key beside an attacker's |
| A hostile package's maintainer script runs before the key is checked | the check happens on the extracted tree, and `dpkg -i` is reached only after it passes | test: the "dpkg -i was never reached" assertions in the same suite |
| An endless body at the download | `curl --max-filesize` bounds the keyring download; the `.deb` admission bounds the signature read | test: the oversized-download case |
| The template loses its placeholder and serves a script that installs the wrong thing | the generator fails closed on a missing placeholder, a leftover placeholder, and output that does not pass `sh -n` | test: `tests/build-installers.test.sh` |
| The published fingerprint and the served keyring disagree | the fingerprint is published in this repository, not on the archive host, so a tampered archive cannot vouch for itself | measurement: `9ADF 04EA 8C31 39CD B673 03CF A670 5C2E A153 F3D6`, checked by hand in the README's own steps |

### The publish job itself

| Threat | Control | Evidence |
|---|---|---|
| A dependency installed by the job alters the workspace the signing step then executes | the job installs only from Debian's archive, which the runner image already trusts; no `pip`, `cargo`, `npm` or `go install` runs beside the signing key | gate: `workflow-lint`'s tooling-isolation assertion, on every pull request; test: `tests/reusable-workflow-lint.test.sh` |
| The job token outlives the checkout beside the signing key | `persist-credentials: false` on every checkout | measurement: read off every checkout in `.github/workflows/` on 2026-09-02; no test holds it |
| A change to the publish workflow ships untested | the workflow's shell is extracted and linted, and its steps are exercised by the workflow suites, on every pull request | gate: `shell / test`, `shell / shellcheck`, `workflow-lint / workflow-lint`, all required on `main` |
| A test exists and no workflow runs it | a watcher fails when a suite under `tests/` is not invoked by any workflow, and another fails when a script has no suite | test: `tests/ci-runs-every-test.test.sh`, `tests/check-test-coverage.test.sh`, each including itself |
| A hung publish holds the archive a day | `timeout-minutes` from a measured 31 to 50 seconds | measurement: the last ten runs, 2026-09-01 |

## How the evidence is kept honest

Reading a test does not say whether it works. On 2026-09-01 every control above
was checked by deleting it from its script and reading the suite: seven
deletions left a suite green, and each became a case that day. Two were fixtures
that broke two rules at once, so the first guard refused them and the needle
could not tell which; three were controls that existed as a line and not as a
test; the rest were assertions inside the copied reusables that had no test at
all. The pull requests that closed them carry the before-and-after runs.

## Residual risks

- **One maintainer.** Every pull request is reviewed and merged by its author.
  A required status check is matched by name, so a maintainer could replace a
  gate with a job of the same name in the pull request that neutralises it.
  Accepted while the repository is single-maintainer; the mitigation for the
  day a second person gets write access is written down in the organization's
  CI standard.
- **Monitoring shares fate with the monitored.** The publish, the health check
  and the freshness watchers all run on GitHub Actions. An outage there stops
  the archive and its alarms at once, silently, bounded only by the fourteen-day
  `Valid-Until`. An external watcher was considered and declined.
- **The read-back is detection, not preservation.** By the time it runs the old
  metadata is gone; a red run means a known-broken archive for as long as it
  takes to publish again. Forward-fix is the policy; there is no rollback.
- **The release key is shared across products.** Admission binds a package to
  the product that released it, so a compromised sibling cannot serve its
  package under another product's name here, but it can serve one under its own.
- **The single suite serves every Debian and Ubuntu from one build.** That is
  valid only while every package installs the same everywhere; a product built
  against a moving base image can acquire a glibc floor that bookworm and jammy
  do not meet, and the archive has no gate for it. It has happened, and it is a
  property of the products, tracked with them.
- **The signature libraries are not a validated cryptographic module.** Ed25519
  is an approved algorithm; `python3-cryptography` and `gpg` here are not
  validated modules. An assessment that requires one needs a validated
  verifier in the path or a documented exception.
- **No independent audit.** Every measurement on this page was made by the
  project.

## Reporting

Report vulnerabilities privately through the repository's **Security tab**.
The organization's [security policy](https://github.com/Glyndor/.github/blob/main/SECURITY.md)
carries the response targets.
