#!/usr/bin/env bash
# Fail when a job that holds a secret also installs third-party tooling.
#
# A job that installs third-party tooling is running code we did not write:
# `cargo install` (and the other installers) executes build scripts over the
# whole dependency tree, so the secrets a job holds are reachable from code
# outside this organisation. Keeping the install out of any job that holds a
# secret bounds that reach to nothing. `pip install --require-hashes` is the
# exception because a hash-pinned install resolves nothing, since the
# artifacts are fixed by the lockfile, so no surprise tree appears.
#
# `apt-get install` and `brew install` are the same shape and are judged by
# the same rule, with the exemptions this check grants:
#
#   - An apt install from the distribution's own archive is exempt. The
#     mechanism is identical -- dpkg runs maintainer scripts as root in the
#     same workspace -- and the difference is who can put a package there:
#     that archive is signed, its uploads are gated on a maintainer, and the
#     runner image already trusts it. A third-party apt source added in the
#     job is not covered, and neither is an install that the archive's own
#     metadata cannot resolve.
#   - That exemption covers the exposure this check accepts, which is
#     persistence: an install in a job whose secret arrives in a later step
#     cannot read that secret, because secrets are injected per step. An
#     install step whose own environment carries the secret is the other
#     exposure -- the maintainer scripts run with the secret in reach -- and
#     it is not covered.
#   - `brew style` and `brew audit` are installs, and get no exemption. Before
#     they run, both install the Ruby gems they need from RubyGems when those
#     are missing (Homebrew's dev-cmd/style.rb and dev-cmd/audit.rb call
#     Utils::GemSetup.install_bundler_gems! first), and HOMEBREW_NO_AUTO_UPDATE
#     does not stop that: it only stops Homebrew updating itself. A job that
#     runs either command holds no secret; run it in a job of its own that has
#     none.
#
# There is no hash exception for apt, and that is decided rather than
# forgotten: apt has no `--require-hashes`, and a version pin fixes the
# version and not the bytes. What verifies an apt package is the archive's
# signature, so the exemption is decided by where the package comes from.
#
# reusable-workflow-lint.yml runs this when its `tooling-isolation` input is
# on, which is the default. python3 runs isolated (-I): the pull request
# controls the working directory, and a module planted there must not be what
# gets imported.
#
# On a pull request reusable-workflow-lint.yml runs the copy of this script in
# the base commit the event names, from a temporary file outside the checkout,
# so the rule that judges a pull request is the base's. The workflow that runs
# it comes from the pull request, and a change there is for the owner's review
# of .github/workflows/ to catch. That is why the default root is the working
# directory and not this file's location.
#
# Usage: check-tooling-isolation.sh [repo-root]   (default: the current directory)
set -euo pipefail
cd "${1:-$PWD}"
python3 -I - <<'PY'
import glob
import re
import sys

import yaml

# A secret is reached in a GitHub Actions expression by its name after
# a dot, or by its name in quotes between square brackets. `secrets: inherit` and `secrets:`
# declarations on reusable calls don't match, because those are
# declaration blocks, not references, and `secrets:` is followed by
# neither a `.` nor a `[`.
SECRET_RE = re.compile(
    r"(?<!\w)secrets(?:\.[A-Za-z_]\w*|\[\s*['\"][^'\"\]]+['\"]\s*\])"
)

# `github.token` is not matched by name, and that is decided rather than
# missed. The job token is not a secret the job opts into: the runner hands it
# to every action as its default `token`, so a job holds it whether a step
# names it or not, and what it can do is set by the job's `permissions`, not by
# a step writing it down. So the token counts as a secret exactly when those
# permissions let it write: a job that installs third-party tooling and whose
# effective permissions (the job's, or the workflow's when the job declares
# none) grant any `write`, or `write-all`, or are declared at neither level,
# which leaves the repository default, is refused with a message of its own.
# Measured 2026-11-21 in apt, homebrew-tap and scoop-bucket: every job that
# installs anything runs with `contents: read` and no other grant, and on a
# public repository that reads nothing an anonymous client cannot.

# (`pattern`, `opt-out marker on the same line`). The marker, when
# present on the line, exempts that install: the only case where
# the resolved tree is fixed is pip with --require-hashes, which
# reads the lockfile verbatim and installs exactly what it lists.
INSTALL_PATTERNS = (
    ("cargo install",   None),
    ("go install",      None),
    ("gem install",     None),
    ("npm install -g",  None),
    ("npm i -g",        None),
    ("pip install",     "--require-hashes"),
)

# `apt-get install` and `apt install`, and the two edges of the
# exemption this workflow grants them.
#
# This workflow exempts an apt install from the distribution's own
# repositories, and the reason is the trust anchor rather than the
# mechanism: dpkg runs maintainer scripts as root either way, so a
# hostile package can persist the way a build.rs can. What differs
# is who can put a package there. A distribution's archive is signed,
# its uploads are gated on a maintainer, and the runner image already
# trusts it; a third-party source added in the job is publish-on-
# demand with extra steps, and this workflow says so in as many
# words. Its other edge is that the package has to come from that
# archive: an install the archive's own metadata cannot resolve
# carries no archive signature.
#
# The second edge is this repository's own, and it is where the
# the account of the exposure given above decides it. Secrets are
# injected per step, so an install in a job whose secret arrives in
# a LATER step cannot read that secret; what it can do is persist,
# and this workflow accepts that residual for the distribution's
# archive. An install step whose own environment carries the secret
# is a different exposure -- the package's maintainer scripts run
# as root with the secret in reach -- and the residual this workflow
# accepted does not cover it.
APT_INSTALL_RE = re.compile(r"\bapt(?:-get)?\s+install\b")

# The arguments of an apt install, up to the first shell operator.
APT_INSTALL_ARGS_RE = re.compile(r"\bapt(?:-get)?\s+install\s+(.*)$")

# A package the archive's own metadata can resolve: a name, with an
# optional architecture qualifier and an optional exact version.
# Anything else -- a URI, a local file, a shell expansion -- is not
# resolved by the archive.
APT_PACKAGE_RE = re.compile(
    r"^[a-z0-9][a-z0-9+.-]*(?::[a-z0-9-]+)?(?:=[^ ]+)?$"
)

# What adds an apt source that is not the distribution's own: a
# source list written, a key dropped into the trusted directory, a
# preferences file, a key added with apt-key, or a sources.list
# entry wherever it is written.
APT_SOURCE_RE = re.compile(
    r"\badd-apt-repository\b"
    r"|/etc/apt/sources\.list"
    r"|/etc/apt/trusted\.gpg\.d"
    r"|/etc/apt/preferences\.d"
    r"|\bapt-key\s+(add|adv)\b"
    r"|^\s*deb(?:-src)?\s+(?:\[[^\]]*\]\s*)?\S+/\S+\s+\S+"
)

# The flags that switch the archive's signature check off. With one
# of them the package is not verified by the trust anchor the
# exemption rests on.
APT_INSECURE_RE = re.compile(
    r"--allow-unauthenticated|--allow-insecure-repositories"
    r"|AllowInsecure|AllowUnauthenticated"
)

# `brew install` resolves a formula and installs it, and `brew
# upgrade` installs the bottles of the formulae it resolves. Homebrew
# is not the distribution the runner image already trusts -- it is
# installed into the job on demand -- and a formula can come from any
# tap, where publication is on demand. The bottle's digest comes
# from the tap rather than from this repository, so it is not the
# analogue of `pip install --require-hashes`, and no exemption is
# granted to it.
BREW_INSTALL_RE = re.compile(r"\bbrew\s+(install|upgrade)\b")

# `brew style` and `brew audit` install Ruby gems from RubyGems when
# the ones they need are missing, before they do anything else, and
# HOMEBREW_NO_AUTO_UPDATE does not stop that: it only stops Homebrew
# updating itself. A gem resolved from a registry that publishes on
# demand is the exposure of `gem install`, so no variable exempts
# either command in a job that holds a secret. The job that runs them
# holds none, and hands its verdict on.
BREW_TOOL_RE = re.compile(r"\bbrew\s+(style|audit)\b")


# An action runs with the job's secrets in reach, so one from an
# owner outside this list is third-party code in a secret-holding
# job, the same exposure as `go install` above. Local reusables
# (`./`) are this repository's own and are skipped by the caller.
FIRST_PARTY_OWNERS = {"actions", "github"}


def normalize_run(value):
    # `run:` is either a single string or a list of strings. Split
    # each into lines so the install scan is per-line: a
    # `--require-hashes` marker on one line only exempts that line.
    if isinstance(value, list):
        out = []
        for v in value:
            if isinstance(v, str):
                out.extend(v.splitlines())
        return out
    if isinstance(value, str):
        return value.splitlines()
    return []


def env_carries_secret(env):
    # Whether the environment a step runs in carries a secret. The
    # environment is the workflow's `env:`, the job's `env:` and the
    # step's `env:` merged, the step's last, because that is what
    # the step's process gets.
    if not env:
        return False
    return bool(SECRET_RE.search(yaml.safe_dump(env)))


def apt_source_added(lines):
    # Whether the job adds an apt source that is not the
    # distribution's own. A comment adds nothing.
    for line in lines:
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        if APT_SOURCE_RE.search(line):
            return True
    return False


def apt_from_archive(line):
    # Whether the install names packages the distribution's own
    # metadata resolves, and keeps the archive's signature check on.
    if APT_INSECURE_RE.search(line):
        return False
    match = APT_INSTALL_ARGS_RE.search(line)
    if not match:
        return False
    args = re.split(r"[|;&<>]", match.group(1))[0]
    for token in args.split():
        if token.startswith("-"):
            continue
        if not APT_PACKAGE_RE.match(token):
            return False
    return True


def classify(line, env, apt_tainted):
    # Why this line installs third-party tooling in a job that holds
    # a secret, or None when it installs nothing third-party. The
    # empty string is the case the rules already had, which says
    # nothing beyond the line itself.
    for pattern, except_marker in INSTALL_PATTERNS:
        if pattern in line and not (
            except_marker and except_marker in line
        ):
            return ""
    if APT_INSTALL_RE.search(line):
        if apt_tainted:
            return (
                "The job adds an apt source of its own, so the "
                "package does not come from the distribution's own "
                "archive; install from that archive alone."
            )
        if not apt_from_archive(line):
            return (
                "The install does not name packages the "
                "distribution's archive resolves, so nothing in it "
                "carries the archive's signature; install packages "
                "by name from that archive."
            )
        if env_carries_secret(env):
            return (
                "The environment of the step that installs carries a "
                "secret, so the package's maintainer scripts run as "
                "root with it in reach; keep the secret out of that "
                "step's environment."
            )
        return None
    if BREW_INSTALL_RE.search(line):
        return (
            "A formula is resolved from a tap, where publication is "
            "on demand."
        )
    if BREW_TOOL_RE.search(line):
        return (
            "The command installs the Ruby gems it needs from "
            "RubyGems when they are missing, and "
            "HOMEBREW_NO_AUTO_UPDATE does not stop that; run it in "
            "a job that holds no secret."
        )
    return None


def token_can_write(job, spec):
    """Why the job's token can write, or None when it is read-only."""
    if "permissions" in job:
        perms = job["permissions"]
    elif "permissions" in spec:
        perms = spec["permissions"]
    else:
        return "no `permissions` at the job or the workflow, so the repository default applies"
    if perms is None or perms == {}:
        return None
    if isinstance(perms, str):
        return None if perms == "read-all" else f"`permissions: {perms}`"
    if isinstance(perms, dict):
        writes = sorted(str(k) for k, v in perms.items() if v != "read" and v != "none")
        return ("`" + ", ".join(f"{k}: {perms[k]}" for k in writes) + "`") if writes else None
    return "`permissions` that cannot be read"


def find_violations(spec_path):
    violations = []
    try:
        with open(spec_path) as fh:
            spec = yaml.safe_load(fh)
    except yaml.YAMLError as e:
        # Silent skip would hide a misconfigured workflow that the
        # caller is going to learn about elsewhere in CI for the
        # wrong reason. Warning annotation instead.
        print(f"::warning file={spec_path}::skipped: YAML parse error: {e}")
        return violations
    if not isinstance(spec, dict):
        return violations
    workflow_env = spec.get("env")
    workflow_env = workflow_env if isinstance(workflow_env, dict) else {}
    jobs = spec.get("jobs") or {}
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        # Re-serialize the job so `with:`, `env:`, `if:` and
        # `run:` strings are all scanned for a secret reference.
        # Comments are stripped by safe_load, so they cannot
        # produce a false positive.
        job_text = yaml.safe_dump(job)
        # A secret in the workflow's own `env:` reaches every step of
        # every job, so the job holds it without naming it.
        holds_secret = bool(SECRET_RE.search(job_text) or env_carries_secret(workflow_env))
        # A job that calls a reusable has no steps here; the reusable's own
        # jobs are read from its file.
        writes = None if "uses" in job else token_can_write(job, spec)
        if not (holds_secret or writes):
            continue
        token = None if holds_secret else writes
        steps = [
            s for s in (job.get("steps") or [])
            if isinstance(s, dict)
        ]
        job_env = job.get("env")
        job_env = job_env if isinstance(job_env, dict) else {}
        # A job that adds an apt source of its own is not talking
        # to the distribution's archive any more, and every install
        # in it is third-party from then on.
        apt_tainted = apt_source_added(
            [l for s in steps for l in normalize_run(s.get("run"))]
        )
        for step in steps:
            uses = step.get("uses")
            if isinstance(uses, str) and not uses.startswith("./"):
                owner = uses.split("/", 1)[0].lower()
                if owner not in FIRST_PARTY_OWNERS:
                    violations.append((spec_path, job_id, f"uses: {uses}", "", token))
            run = step.get("run")
            if run is None:
                continue
            step_env = step.get("env")
            step_env = step_env if isinstance(step_env, dict) else {}
            env = dict(workflow_env)
            env.update(job_env)
            env.update(step_env)
            for line in normalize_run(run):
                stripped = line.lstrip()
                if not stripped or stripped.startswith("#"):
                    continue
                why = classify(line, env, apt_tainted)
                if why is None:
                    continue
                violations.append((spec_path, job_id, line, why, token))
    return violations


def main():
    files = sorted(set(
        glob.glob(".github/workflows/*.yml")
        + glob.glob(".github/workflows/*.yaml")
    ))
    violations = []
    for path in files:
        violations.extend(find_violations(path))
    if violations:
        for path, job_id, line, why, token in violations:
            because = f" {why}" if why else ""
            if token:
                print(
                    f"::error file={path}::job `{job_id}` installs third-party "
                    f"tooling while its token can write ({token}): "
                    f"`{line.strip()}`.{because} The token reaches every step "
                    "of the job, so the installer runs with write access. Fix "
                    "by giving the job read-only permissions, or by moving the "
                    "install into a job that has them."
                )
                continue
            print(
                f"::error file={path}::job `{job_id}` installs third-party "
                f"tooling while holding a secret: `{line.strip()}`.{because} "
                "See Glyndor/apt#121. Fix by moving the install into a "
                "job that holds no secrets, or pin it by hash "
                "(e.g. `pip install --require-hashes`)."
            )
        sys.exit(1)
    print(
        "tooling-isolation: no job holding a secret installs third-party "
        "tooling, and no job whose token can write does either."
    )
    sys.exit(0)


if __name__ == "__main__":
    sys.exit(main())
PY
