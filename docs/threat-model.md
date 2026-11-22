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
| The post-quantum release key (public half) and the products that must use it | `keyring/glyndor-release-mldsa65.b64`, which holds no key yet, and `keyring/pq-required-products`, empty | the second trust anchor, and the list that makes the second signature mandatory |
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
| The Ed25519 release signature is forged, by a quantum computer or a flaw in the scheme | a second signature, ML-DSA-65 over the same bytes in `<deb>.mldsa65.sig`, checked after the Ed25519 one; when present both must verify, a product in the required list must carry it, and one present while no ML-DSA-65 key is configured, the wrong length, read past a 4096-byte cap, or from a library without ML-DSA is refused rather than skipped. The publish downloads it when a release has one, under the same caps as the `.sig` | test: `tests/verify/verify-debs-hybrid.test.sh` for the cases that need no ML-DSA library, `tests/verify/verify-debs-mldsa.test.sh` for real signatures, generated and one fixed vector made with OpenSSL, `tests/publication/publish/publish-workflow-pq-sidecar.test.sh` for the download. No product signs with it yet, so this row protects nothing today |
| A validly signed `.deb` from an older release is attached to a new tag | the control `Version` must equal the tag the package was downloaded from, epoch and Debian revision aside; the publish calls the verifier with `--require-tag`, so a tag that did not survive the step boundary is refused by the verifier and not read as "do not check" | test: `tests/verify/verify-debs.test.sh`, the same bytes refused under another tag and admitted under their own; `tests/publication/publish/publish-workflow-verify-debs.test.sh` runs the step with no tag recorded, and a copy without the flag must pass |
| A hostile `.deb` exploits the package parser in the publish job before anything has verified it | `verify-debs.sh` checks the Ed25519 signature, and a present ML-DSA-65 one, on the raw bytes before it opens the package with `dpkg-deb`; in `publish.yml` no step before the signature check runs `dpkg-deb`, so the release-order check, which reads each candidate's control fields, runs after it | test: `tests/verify/verify-debs.test.sh`, a `dpkg-deb` on `PATH` that must not be called for a package with an invalid signature; `tests/publication/publish/publish-workflow.test.sh` reads every step before the signature check and every script it runs, and reports one that opens a package |
| A product ships a package under the keyring's reserved name | `glyndor-archive-keyring` is refused by both the control field and the filename | test: two cases in the same suite |
| A trust file with no key, or one that does not exist, verifies against nothing | both are refused as such, with the reason named | test: the two cases in `tests/verify/verify-debs.test.sh` for a trust file with no key and a missing one |
| A keyring package with no usable key is built and served | the build refuses an armoured file that dearmors cleanly but carries no public key | test: `tests/build/build-keyring.test.sh`, fixture is a detached signature block |

### Publication: what is served, and whether it is what was built

| Threat | Control | Evidence |
|---|---|---|
| The signed index declares a file the bucket does not have (a race inside the sync) | the sync runs in five ordered passes, no pass over `dists/` carries `--delete`, the by-hash copies land before the signed index that declares them and the fixed-name index files after it, and the run ends by reading the live archive back: signature first, then every declared size and hash, its by-hash copies, down to the pool | test: `tests/verify/verify-published.test.sh`, against a synthetic archive over a local HTTP server; measurement: the read-back caught the race on run 29718989917 before the fix; `tests/publish/sync-archive.test.sh` stops the sync after every write of every pass and checks, from an archive offered by hash and from one before the field, that the visible InRelease's by-hash copies are served and that an index without the field is served over the files it declares |
| A client reads the index of one publish and its `Packages` after the next one, and `apt update` fails with `Hash Sum mismatch` | the signed index says `Acquire-By-Hash: yes` and every file it declares is served at `by-hash/SHA256/<hash>` beside it, uploaded before the index and never deleted, so a client asks for the bytes its index declares; the field is added before signing, since reprepro writes neither it nor the copies. This holds from the second publish that carries the field: the first one replaces an index whose clients ask by the fixed name, and the sync publishes the new index before the fixed-name files, so only a client that read the old index before it was replaced and asks by name after the files change can still see the mismatch, the window every publish had before. A publish cut after the new index and before the fixed-name files leaves those files stale: clients that ask by hash are not affected, the read-back fails the publish and the health check fails until a publish completes | test: `tests/build/add-by-hash/add-by-hash-apt.test.sh`, a real `apt-get update` against an archive caught between two publishes, which passes by hash and fails with the mismatch when the index is signed without the field; `tests/verify/verify-published/verify-published-by-hash.test.sh` for the read-back of the copies |
| The edge serves an older complete snapshot signed by the archive key after a publish | after the purge, publish passes the SHA-256 of its local `public/dists/stable/InRelease` to read-back; the served index must match that build within the retry budget, as well as pass the signature and index/pool/bootstrap checks; independent health checks do not require a local build | test: `tests/verify/verify-published/verify-published-build.test.sh`, two valid signed snapshots, acceptance with their own digests, rejection of the old snapshot against the new digest, convergence on retry, and the actual publish step with a local build |
| An older release, validly signed, is re-marked as the latest one and published as the newest | the publish compares the version each release tag names with the version the archive already serves, read out of the served signed index, and refuses a candidate that is lower in SemVer precedence, or whose `.deb` is lower in Debian's full version order (epoch and revision included, checked with `dpkg`); equal or greater passes, a product the archive does not serve yet is a first publication and passes, and an index that cannot be read fails the publish closed | gate: `scripts/verify/check-release-order.sh#release_order`, called once per product by `.github/workflows/publish.yml#Refuse a release older than the one served` before anything is published |
| An index that verified but declares too much turns the read-back into an unbounded download | the read-back caps the number of files the signed index declares, the number of packages the verified indices declare, the size of every object it fetches and the total pool bytes | test: `tests/verify/verify-published/verify-published-budget.test.sh` lowers the cap on the number of files below what the fixture declares, the cap on the total pool bytes likewise, and the cap on the number of packages on an archive that declares five packages in four index files (refused at a cap of four, accepted at five); `tests/verify/verify-published/verify-published-object-size.test.sh` serves an object at the per-object cap and one byte over it |
| A stale object at the edge under an immutable name | the purge list is derived from the `Release` and `Packages` files the run built and split to Cloudflare's per-request limit. Of `pool/` it holds the keyring package, the one object rebuilt under a stable name, and no product package: that name carries its version and its bytes are never rewritten | test: `tests/publish/purge-cache.test.sh`; measurement: 44 URLs in three requests for seven products on three architectures |
| The installer of a product that left the roster keeps being served | the publish prunes the bucket's `install/` down to the installers the run built, deleting the objects the bucket's own listing named, and reads the bucket back to prove the served set is the built set; the paths it removed are purged from the edge, which holds an installer for a day | test: `tests/publish/prune-installers.test.sh` |
| The keyring package changes bytes under the same name and the size-only sync skips it | the package is built byte-reproducibly from the commit date of its inputs, so equal inputs give equal bytes, and every input that decides those bytes -- the files it installs and the generator that writes its control file, its conffiles and its modes -- moves the version | test: `tests/build/build-keyring.test.sh`, two builds a moment apart must be identical; test: `tests/build/keyring/build-keyring-generator.test.sh`, changing the generator moves the version and the bytes, and a generator that does not track itself keeps the version still |
| The index or the bootstrap keyring package is signed by a key clients were not told to trust, or by the retired one of two keys pasted into the secret during a rotation | the secret is imported once, by `scripts/build/build-repo.sh`, which refuses anything but exactly one secret key and a key absent from `keyring/glyndor-apt-key.asc`, and signs both the index and the served keyring package with it | test: `tests/build/build-repo.test.sh`; `tests/publication/publish/publish-workflow-bootstrap.test.sh` runs the build step as shipped with a stubbed `reprepro`, and the secret reaches no other step |
| A clock- or locale-dependent build ships a page missing a package | `LC_ALL=C` wherever a script sorts or compares | test: `tests/ci/policy/locale-pinned.test.sh`, behavioural half under a UTF-8 locale that does collapse the names |
| The archive silently stops refreshing | `Valid-Until` of fourteen days on the signed index, so a stalled publish expires rather than freezes; a health check every six hours fails on a stale or unreachable index, and on one whose `Valid-Until` is missing or already past, which apt refuses whatever its `Date` says; a freshness watcher fails when the publish cron itself stops | gate: `health-check.yml`, `freshness.yml`; test: `tests/publication/health-check/health-check-workflow.test.sh` runs the freshness step against an expired, a missing and an unreadable `Valid-Until`; measurement: the schedule watchers fired for their reason before promotion |

### The client's first step

| Threat | Control | Evidence |
|---|---|---|
| The bootstrap keyring is substituted on the way to the client | the generated installer extracts the package without running it, reads every fingerprint in it, and refuses unless every one is a fingerprint it was told to expect; the downloaded package is not installed before that | test: `tests/installer/install-template/install-template-behaviour.test.sh`, with a real `gpg` and a sandboxed `PATH`, including a keyring carrying the published key beside an attacker's |
| A hostile package's maintainer script runs before the key is checked | the check happens on the extracted tree, and `dpkg -i` is reached only after it passes | test: the "dpkg -i was never reached" assertions in the same suite |
| An endless body at the download | `curl --max-filesize` bounds the keyring download; the `.deb` admission bounds the signature read | test: the oversized-download case |
| The template loses its placeholder and serves a script that installs the wrong thing | the generator fails closed on a missing placeholder, a leftover placeholder, and output that does not pass `sh -n` | test: `tests/build/build-installers.test.sh` |
| The edge serves a one-line, truncated or wrong-product installer | publish compares the full served body with `public/install/`; health-check regenerates its reference with the generator of the commit the last successful publish ran from (the generator of its own checkout when that commit cannot be learned or fetched, which is the strict behaviour) and compares every byte | test: `tests/verify/verify-installers.test.sh`, including a failed transfer even when the bytes match, and `tests/verify/reference-installers.test.sh` for the reference; `tests/publication/health-check/health-check-workflow.test.sh` exercises the workflow |
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
| A dependency installed by the job alters the workspace the signing step then executes | the job installs from Debian's archive, which the runner image already trusts; the one exception is the `cryptography` wheel that ML-DSA-65 needs, installed only once an ML-DSA-65 key is committed, pinned by hash, binary only and into a virtual environment outside the workspace; no other `pip`, and no `cargo`, `npm` or `go install`, runs beside the signing key, and no job whose token can write installs third-party tooling either (the two exemptions above hold with a write token as they do with a secret, so a job that can write may still install from Debian's archive or by hash, and the gate refuses it only when the install step itself names the job token), and no action from an owner other than `actions` or `github` is used | gate: `workflow-lint`'s tooling-isolation assertion (`scripts/quality/lint/check-tooling-isolation.sh`, read from the base commit the pull request event names, so the rule that judges a pull request is the base's, and at its earlier path when the pull request moves it (the base's copy of the file of the same name under `scripts/quality/`; two such files fail the job, and only a rule the base has never had runs from the checkout); the workflow that runs it comes from the pull request and is covered by the owner's review of `.github/workflows/`), on every pull request that changes a workflow or that script and on every push to `main`; a pull request that changes neither cannot change its answer | test: `tests/quality/lint/check-tooling-isolation.test.sh` for the rule, `tests/ci/reusable/reusable-workflow-lint.test.sh` for the step that runs it (`tests/ci/reusable/reusable-workflow-lint.test.sh#the move: a rule moved and weakened in the same change still refuses the violation`) |
| The job token outlives the checkout beside the signing key | `persist-credentials: false` on every checkout | test: `tests/ci/policy/persist-credentials.test.sh`, which reads every `actions/checkout` of every `.yml` and `.yaml` workflow, the reusables included; measurement: read off every checkout in `.github/workflows/` on 2026-09-02 |
| A change to the publish workflow ships untested | the workflow's shell is extracted and linted, and its steps are exercised by the workflow suites, on every pull request that changes the workflow | gate: the checks `shell / test`, `shell / shellcheck` and `workflow-lint / workflow-lint`, which `tests.yml` and `workflow-lint.yml` report on every pull request and on every push to `main` |
| A test exists and no workflow runs it | a watcher fails when a suite under `tests/` is not invoked by any workflow, and another fails when a script has no suite | test: `tests/ci/suites/ci-runs-every-test.test.sh`, `tests/quality/coverage/check-test-coverage.test.sh`, each including itself |
| A pull request drops suites from the test job, the watcher among them, and the job stays green | the `workflow-lint` check, outside the test job, fails when a suite under `tests/` is run by no workflow on a pull request. A suite counts only from a job without `if:`, `needs:` or `continue-on-error`, from a caller whose `skip-suite-paths` matches no file under `.github/`, `scripts/` or `tests/`, or from a `run:` line that no shell operator follows, in a step without a here-doc, with errexit on and under bash; a line in a branch that is never taken still counts. The checker and the list of exempt suites (`scripts/quality/coverage/suite-exemptions.txt`) are read from the base commit the pull request event names, at their earlier path when the pull request moves them, so the pull request cannot weaken the checker or exempt what it unwires; the workflow that runs them comes from the pull request and is covered by the owner's review of `.github/workflows/` that CODEOWNERS routes to the owner | test: `tests/quality/coverage/check-suites-wired.test.sh`, which drops the watcher, disarms the checker, exempts what it drops, adds `needs:` and widens `skip-suite-paths` in a pull request |
| A caller passes an input that weakens the check it calls (`tooling-isolation: false`, `severity: ignore`, `check-exec-bit: false`, `exclude-pattern: ".*"`, a larger `hard-limit`, an `extensions` list without `sh`) and every suite stays green | `workflow-lint` refuses, for every caller of a local reusable, an input that the closed list of that reusable does not name, and a caller of a reusable that has no entry in the list. The `extensions` of the line limit may grow but may not lose a word the callers of the base commit pass, and are lowercase words of letters and digits with one space between them, because the reusable builds a regular expression from them and refuses any other word itself. The list is read from the base commit the pull request event names, like the rest of the rule; the workflow that runs it comes from the pull request and is covered by the owner's review of `.github/workflows/` (`.github/workflows/reusable-workflow-lint.yml#A required test job must not be switchable off`, `scripts/quality/lint/check-test-job-not-switchable.sh#check-test-job-not-switchable`) | test: `tests/quality/lint/check-test-job-not-switchable-inputs.test.sh#a caller with two refused inputs is refused`; `tests/quality/lint/check-test-job-not-switchable-inputs.test.sh#a caller of a local reusable with no entry in the list is refused`; `tests/quality/lint/check-test-job-not-switchable-inputs.test.sh#and the message names the extension taken` |
| A required job, or the step inside it that runs the suite or the comparison, is switched off with a job-level `if:` (`if: false`), `needs:` or `continue-on-error:`, or a step-level `if:`, and every suite stays green; the job can be a caller, one of the jobs inside a local reusable (`shell / test`, `dco`, `empty diff`) or a job a workflow defines itself (the alarm of the health check) | `workflow-lint` reads every job and every step of every workflow, the reusables included, and refuses a job-level `if:`, `needs:` or `continue-on-error:` and a step-level `if:` or `continue-on-error:` that two closed lists in the script do not name by workflow file, job and exact value (the conditions that exist on purpose: an event, a scope decision, the job a watcher waits for). A job added later is held to the rule without a new case, and the refusal says where a condition on purpose is declared. A condition that reads the output of a step or a job (`steps.scope.outputs.needed`) is only accepted while everything that producer can see is what the base commit has: the steps of the job up to it, whole, the `env`, `defaults`, `runs-on`, `container`, `services` and `permissions` of the job and the `env` and `defaults` of the workflow (for a producer that is a job, the whole job and the reusable it calls). A pull request therefore cannot make the scope step write `false`, nor add a step before it that writes `needed=false` to `GITHUB_ENV`, nor set an `env:` that changes what it runs, and a producer that runs a script of the repository from the checkout of a pull request is refused in the workflows a pull request can run; a producer is changed on purpose in two pull requests. `skip-suite-paths`, which decides when `shell / test` is skipped, is a list of words that name a file, never `*` or a pattern that matches every file, and may not gain a word the callers of the base commit do not pass. The lists are read from the base commit the pull request event names, like the rest of the rule; the workflow that runs it comes from the pull request and is covered by the owner's review of `.github/workflows/` (`.github/workflows/reusable-workflow-lint.yml#A required test job must not be switchable off`, `scripts/quality/lint/check-test-job-not-switchable.sh#check-test-job-not-switchable`) | test: `tests/quality/lint/check-test-job-not-switchable-jobs.test.sh#and says how to change a producer on purpose`; `tests/quality/lint/check-test-job-not-switchable-inputs.test.sh#and it says the callers of the base commit do not pass it`; `tests/quality/lint/check-test-job-not-switchable-jobs.test.sh#the alarm of a scheduled workflow switched off with if: false is refused`; `tests/quality/lint/check-test-job-not-switchable-jobs.test.sh#the step that runs the comparison switched off with if: false is refused`; `tests/quality/lint/check-test-job-not-switchable-jobs.test.sh#the job that runs the tests with a condition that can never hold is refused` |
| A hung publish holds the archive a day | `timeout-minutes` from a measured 31 to 50 seconds | measurement: the last ten runs, 2026-09-01 |
| A hung purge spends the whole job and is cancelled without saying anything | the purge takes a budget for the whole run, every transfer and every retry inside it are limited to the time that is left, and the failure names the group and the batch that were in flight | test: `tests/publish/purge-cache/purge-cache-budget.test.sh`, against a fake Cloudflare API that accepts the request and never answers; measurement: before, one hung purge request was four attempts of `--max-time 300` -- 1200s of transfer against a 900s job -- and the operator read "cancelled after 15 minutes" |

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
- **A gate replaced in the pull request that should be judged by it.** A
  required status check is matched by name, so someone with write access could
  replace a gate with a job of the same name in the pull request that
  neutralises it. The mitigation is Code Owner review on `.github/workflows/`
  (see `.github/CODEOWNERS`).
- **What refuses a merge is set outside this repository.** The checks named
  above are the ones this repository's CI reports, on every pull request and
  on every push to `main`. Whether a merge into `main` is refused without them
  is a branch protection setting on GitHub, which this repository does not
  record; the list it keeps of the checks it expects to be required, and the
  test that holds the callers to those names, live in
  `tests/ci/policy/workflow-shape.test.sh`.
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
- **The post-quantum signature is in the verifier, not yet in any release.** No
  ML-DSA-65 key is configured and no product is required, so every package is
  admitted on Ed25519 alone, and a release that attaches the second signature
  is refused until the key is committed. Committing the key is also what makes
  the publish install the library that checks it. A second signature that is optional
  protects nothing, because whoever forges the first one leaves it out; the
  protection for a product starts the day it enters
  `keyring/pq-required-products`. It covers admission only: apt clients check
  the index, which stays Ed25519 until the verifiers apt uses accept a
  post-quantum signature.
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
  validated modules, and neither is the `cryptography` wheel, with its own
  OpenSSL, that ML-DSA-65 verification needs. An assessment that requires one needs a validated
  verifier in the path or a documented exception.
- **Reproducibility is bounded by the packaging environment.** The keyring
  package is byte-for-byte reproducible for the same inputs *on the same
  tooling*: `dpkg-deb`, `tar` and `gpg` write it, and a different version of
  any of them can produce different bytes from identical inputs. The publish
  names its runner image, `ubuntu-26.04`, so a new Ubuntu release reaches it as
  a commit; but GitHub still refreshes the packages of that image every week
  under the same name, so that can change without anyone editing this
  repository, and the pool object is served under an immutable name for a
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
