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
| The keyring package | rebuilt every run, filename follows the version, and the version follows its inputs | the one object in `pool/` where "same name, different bytes" is possible |

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
| An unsigned or tampered `.deb` is served | every `.deb` must carry a detached Ed25519 signature that verifies against the release key file; a missing, invalid, oversized or malformed signature fails the publish | test: `tests/verify/verify-debs.test.sh`, each refusal asserting which refusal |
| A release of product A ships a `.deb` whose control field says it is product B | each product is downloaded into its own directory and verified against its own name: the control `Package:` field and the filename prefix must both match the product that released it | test: the control-field case uses a fixture that breaks only that rule, so the filename check cannot answer for it |
| A product ships a package under the keyring's reserved name | `glyndor-archive-keyring` is refused by both the control field and the filename | test: two cases in the same suite |
| A trust file with no key, or one that does not exist, verifies against nothing | both are refused as such, with the reason named | test: cases 14 and 15 |
| A keyring package with no usable key is built and served | the build refuses an armoured file that dearmors cleanly but carries no public key | test: `tests/build/build-keyring.test.sh`, fixture is a detached signature block |

### Publication: what is served, and whether it is what was built

| Threat | Control | Evidence |
|---|---|---|
| The signed index declares a file the bucket does not have (a race inside the sync) | the sync runs in three ordered passes, the metadata pass carries no `--delete`, and the run ends by reading the live archive back: signature first, then every declared size and hash, down to the pool | test: `tests/verify/verify-published.test.sh`, against a synthetic archive over a local HTTP server; measurement: the read-back caught the race on run 29718989917 before the fix |
| The edge serves an older complete snapshot signed by the archive key after a publish | after the purge, publish passes the SHA-256 of its local `public/dists/stable/InRelease` to read-back; the served index must match that build within the retry budget, as well as pass the signature and index/pool/bootstrap checks; independent health checks do not require a local build | test: `tests/verify/verify-published-build.test.sh`, two valid signed snapshots, acceptance with their own digests, rejection of the old snapshot against the new digest, convergence on retry, and the actual publish step with a local build |
| An older release, validly signed, is re-marked as the latest one and published as the newest | the publish compares the version each release tag names with the version the archive already serves, read out of the served signed index, and refuses a candidate that is lower in SemVer precedence; equal or greater passes, a product the archive does not serve yet is a first publication and passes, and an index that cannot be read fails the publish closed | gate: `scripts/verify/check-release-order.sh#release_order`, called once per product by `.github/workflows/publish.yml#Refuse a release older than the one served` before anything is published |
| An index that verified but declares too much turns the read-back into an unbounded download | the read-back caps entries, per-object size and total pool bytes | test: the caps are exercised by lowering them below what the fixture declares |
| A stale object at the edge under an immutable name | the purge list is derived from the `Release` and `Packages` files the run built, pool included, and split to Cloudflare's per-request limit | test: `tests/publish/purge-cache.test.sh`; measurement: 14 URLs in one request today, 36 in two for the full roster |
| The installer of a product that left the roster keeps being served | the publish prunes the bucket's `install/` down to the installers the run built, deleting the objects the bucket's own listing named, and reads the bucket back to prove the served set is the built set; the paths it removed are purged from the edge, which holds an installer for a day | test: `tests/publish/prune-installers.test.sh` |
| The keyring package changes bytes under the same name and the size-only sync skips it | the package is built byte-reproducibly from the commit date of its inputs, so equal inputs give equal bytes, and every input that decides those bytes -- the files it installs and the generator that writes its control file, its conffiles and its modes -- moves the version | test: `tests/build/build-keyring.test.sh`, two builds a moment apart must be identical; test: `tests/build/keyring/build-keyring-generator.test.sh`, changing the generator moves the version and the bytes, and a generator that does not track itself keeps the version still |
| A clock- or locale-dependent build ships a page missing a package | `LC_ALL=C` wherever a script sorts or compares | test: `tests/ci/policy/locale-pinned.test.sh`, behavioural half under a UTF-8 locale that does collapse the names |
| The archive silently stops refreshing | `Valid-Until` of fourteen days on the signed index, so a stalled publish expires rather than freezes; a health check every six hours fails on a stale or unreachable index; a freshness watcher fails when the publish cron itself stops | gate: `health-check.yml`, `freshness.yml`; measurement: the schedule watchers fired for their reason before promotion |

### The client's first step

| Threat | Control | Evidence |
|---|---|---|
| The bootstrap keyring is substituted on the way to the client | the generated installer extracts the package without running it, reads every fingerprint in it, and refuses unless every one is a fingerprint it was told to expect; nothing is installed before that | test: `tests/installer/install-template/install-template-behaviour.test.sh`, with a real `gpg` and a sandboxed `PATH`, including a keyring carrying the published key beside an attacker's |
| A hostile package's maintainer script runs before the key is checked | the check happens on the extracted tree, and `dpkg -i` is reached only after it passes | test: the "dpkg -i was never reached" assertions in the same suite |
| An endless body at the download | `curl --max-filesize` bounds the keyring download; the `.deb` admission bounds the signature read | test: the oversized-download case |
| The template loses its placeholder and serves a script that installs the wrong thing | the generator fails closed on a missing placeholder, a leftover placeholder, and output that does not pass `sh -n` | test: `tests/build/build-installers.test.sh` |
| The edge serves a one-line, truncated or wrong-product installer | publish compares the full served body with `public/install/`; health-check regenerates its reference from the checkout and compares every byte | test: `tests/verify/verify-installers.test.sh`, including a failed transfer even when the bytes match; `tests/publication/health-check/health-check-workflow.test.sh` exercises the workflow |
| A cut delivery executes an installation prefix | all executable statements are inside a function invoked on the final line; the generator requires that final invocation | test: `tests/installer/install-template/install-template-delivery.test.sh`, a real pipe with an interrupted producer and assertions on commands and the sandbox keyring, paired with a complete delivery |
| The published fingerprint and the served keyring disagree | the fingerprint is published in this repository, not on the archive host, so a tampered archive cannot vouch for itself | measurement: `9ADF 04EA 8C31 39CD B673 03CF A670 5C2E A153 F3D6`, checked by hand in the README's own steps |

### Automatic upgrades on the client

| Threat | Control | Evidence |
|---|---|---|
| The daily upgrade job touches packages that are not Glyndor's | the job asks `apt-get -s --only-upgrade install` what upgrading the installed Glyndor packages would change and gives exactly that set to `unattended-upgrade` as a strict whitelist; everything else stays pending | test: `tests/keyring/glyndor-upgrade.test.sh`; measurement: on Debian 13 with a fake old `podup`, 12 unrelated Debian upgrades were pending before and 12 after, 2026-10-31 |
| A package name in the index or in the plan reaches the job's configuration and injects a line of its own | every name is checked against Debian's name rules before it is written, and an invalid one fails the unit and is named in the journal instead of being dropped | test: the hostile-name cases in the same suite, including a name with a quote and one in the index |
| An apt that cannot plan the upgrade is read as "nothing to do" | the simulation's exit status is checked; a failure fails the unit | test: the stubbed failing `apt-get -s` case |
| The operator's choice to switch the job off is undone by an upgrade of the keyring | the timer is enabled once per machine, recorded by a marker written only after `systemctl enable --now` succeeded, so a later `systemctl disable` stands | test: the maintainer-script cases; measurement: disable, reinstall the keyring, still disabled, Debian 13, 2026-10-31 |

### The publish job itself

| Threat | Control | Evidence |
|---|---|---|
| A dependency installed by the job alters the workspace the signing step then executes | the job installs only from Debian's archive, which the runner image already trusts; no `pip`, `cargo`, `npm` or `go install` runs beside the signing key, and no action from an owner other than `actions` or `github` is used | gate: `workflow-lint`'s tooling-isolation assertion, on every pull request; test: `tests/ci/reusable/reusable-workflow-lint.test.sh` |
| The job token outlives the checkout beside the signing key | `persist-credentials: false` on every checkout | measurement: read off every checkout in `.github/workflows/` on 2026-09-02; no test holds it |
| A change to the publish workflow ships untested | the workflow's shell is extracted and linted, and its steps are exercised by the workflow suites, on every pull request | gate: `shell / test`, `shell / shellcheck`, `workflow-lint / workflow-lint`, all required on `main` |
| A test exists and no workflow runs it | a watcher fails when a suite under `tests/` is not invoked by any workflow, and another fails when a script has no suite | test: `tests/ci/suites/ci-runs-every-test.test.sh`, `tests/quality/check-test-coverage.test.sh`, each including itself |
| A hung publish holds the archive a day | `timeout-minutes` from a measured 31 to 50 seconds | measurement: the last ten runs, 2026-09-01 |
| A hung purge spends the whole job and is cancelled without saying anything | the purge takes a budget for the whole run, every transfer and every retry inside it are limited to the time that is left, and the failure names the group and the batch that were in flight | test: `tests/publish/purge-cache-budget.test.sh`, against a fake Cloudflare API that accepts the request and never answers; measurement: before, one hung purge request was four attempts of `--max-time 300` -- 1200s of transfer against a 900s job -- and the operator read "cancelled after 15 minutes" |

## How the evidence is kept honest

Reading a test does not say whether it works. On 2026-09-01 every control above
was checked by deleting it from its script and reading the suite: seven
deletions left a suite green, and each became a case that day. Two were fixtures
that broke two rules at once, so the first guard refused them and the needle
could not tell which; three were controls that existed as a line and not as a
test; the rest were assertions inside the copied reusables that had no test at
all. The pull requests that closed them carry the before-and-after runs.

The keyring's version tracking was checked the same way when the generator was
added to it, on 2026-11-05: with the generator out of the list of inputs the
version follows, changing the generator left the version standing and moved the
bytes, and that is the case `tests/build/keyring/build-keyring-generator.test.sh` holds.

## Residual risks

- **The first bootstrap hop trusts the script host.** `curl | sudo sh` obtains
  the verifier from the same host that serves the keyring package and signature.
  The fingerprint and signature authenticate the package only when the installer
  itself is the expected script. A replaced script can omit both checks; they
  do not authenticate the script executing as root. Read-back detects differences
  from the runner's location, not every client's response. Independent inspection
  of the installer and an independently obtained trust anchor are needed to
  authenticate this first hop. Deferring execution until the final invocation
  protects incomplete prefixes, not malicious replacements or a transfer error
  reported after the complete invocation has already arrived; a pipeline also
  needs its producer's status checked to report that error.
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
- **A superseded package disappears at once.** The archive is latest-only, and
  the third sync pass deletes superseded `.deb`s from `pool/` right after the new
  metadata lands. A client that fetched the index before the publish and
  installs after it asks for a file that is gone and gets a 404 until its next
  `apt update`. It fails closed and the fix is the command apt already suggests;
  keeping the previous version for a grace period was weighed against the
  evergreen policy and declined.
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
- **Automatic upgrades widen the reach of a compromised archive.** Before the
  upgrade timer a bad package waited for someone to run `apt upgrade`; now it is
  installed as root within a day on every machine that kept the timer on. The
  controls on admission, the signed index and its fourteen-day `Valid-Until`
  are what stand in front of that, and the timer adds only a narrower trigger,
  not a new way in. The opt-out is `systemctl disable --now
  glyndor-upgrade.timer`. A staged rollout (a delay or a canary cohort) was not
  built; it would be the next control if the cost of a bad release grows.
- **The signature libraries are not a validated cryptographic module.** Ed25519
  is an approved algorithm; `python3-cryptography` and `gpg` here are not
  validated modules. An assessment that requires one needs a validated
  verifier in the path or a documented exception.
- **Reproducibility is bounded by the packaging environment.** The keyring
  package is byte-for-byte reproducible for the same inputs *on the same
  tooling*: `dpkg-deb`, `tar` and `gpg` write it, and a different version of
  any of them can produce different bytes from identical inputs. The publish
  runs on a moving runner image, so that can change without anyone editing
  this repository, and the pool object is served under an immutable name for a
  year. What stands in front of it is the read-back at the end of the publish,
  which compares the bytes the archive serves with the hashes the signed index
  declares and fails the run when they disagree. The version is the other half
  of the guarantee: it moves when an input moves, so apt has something new to
  install.
- **No independent audit.** Every measurement on this page was made by the
  project.

## Reporting

Report vulnerabilities privately through the repository's **Security tab**.
The organization's [security policy](https://github.com/Glyndor/.github/blob/main/SECURITY.md)
carries the response targets.
