## Summary

<!-- What does this PR do? 1-3 bullet points. -->

## Changes

<!-- List the main changes made. -->

## Test plan

<!-- How was this tested? Check all that apply. -->

- [ ] `./tests/*.test.sh` pass locally
- [ ] `shellcheck scripts/*.sh tests/*.sh` is clean
- [ ] Ran against a real archive or a container, for changes to publishing, signing or the installer

<!--
A test that was not watched fail is not a test. If this PR adds or changes a
check, say which control you removed to make it go red, and what it reported.
See standards/testing, "Three ways a sabotage lies to you".
-->

- [ ] New or changed checks were verified by deleting the control and watching them fail

## Checklist

- [ ] Targets `main` (this repository has no `develop` branch)
- [ ] Commits are signed off (DCO, `git commit -s`)
- [ ] Labels applied (`type:`, `prio:`, `effort:`, `area:` where applicable)
- [ ] Every script under `scripts/` still has a test (`./scripts/check-test-coverage.sh`)
- [ ] No secrets, keys or credentials in code, logs or fixtures
- [ ] Docs updated if behaviour changed

## Related issues

<!-- Closes #123 -->
