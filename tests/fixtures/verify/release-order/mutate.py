#!/usr/bin/env python3
"""Mutate only a disposable copy; exact matches prevent inert controls."""
import pathlib
import sys

source, target, mutation = sys.argv[1:]
text = pathlib.Path(source).read_text()
changes = {
    "greater": ('if new < highest[0]:', 'if new > highest[0]:'),
    "equal": ('if new < highest[0]:', 'if new <= highest[0]:'),
    "comparison": ('if new < highest[0]:', 'if False:'),
    "first": ('print("not-served")', 'sys.exit("first publication refused")'),
    "prerelease": ('pre is None,', 'True,'),
    "revision": ('if dash and REVISION.match(revision):', 'if False:'),
    "epoch": ('if EPOCH.match(version):', 'if False:'),
    "highest": ('highest = max(orders,', 'highest = min(orders,'),
    "size": ('if [ "$got_size" != "$size" ]; then', 'if false; then'),
    "sha256": ('if [ "$(sha256_of "$dest")" != "$digest" ]; then', 'if false; then'),
    "cap": ('MAX_INRELEASE_BYTES=$((1024 * 1024))',
            'MAX_INRELEASE_BYTES=$((2 * 1024 * 1024))'),
    "lower-cap": ('MAX_INRELEASE_BYTES=$((1024 * 1024))',
                  'MAX_INRELEASE_BYTES=$((1024 * 1024 - 4096))'),
    "semver": ('new = precedence(candidate)', 'new = precedence("9.0.0")'),
    "description": ('if not line or line[0] in " \\t":', 'if not line:'),
}
if mutation == "gpgv":
    start = text.index('if ! gpgv --keyring')
    end = text.index('\nfi', start) + len('\nfi')
    # Preserve the cleartext body, but remove the signature verification itself.
    text = text[:start] + (
        'sed \'1,/^$/d; /^-----BEGIN PGP SIGNATURE-----/,$d\' '
        '"$WORK/InRelease" > "$WORK/InRelease.body"'
    ) + text[end:]
elif mutation == "fetch":
    start = text.index('if ! fetch "$BASE_URL/$DIST_PATH/InRelease"')
    end = text.index('\nfi', start)
    block = text[start:end]
    assert block.count('exit 1') == 1
    text = text[:start] + block.replace('exit 1', 'exit 0') + text[end:]
else:
    before, after = changes[mutation]
    assert text.count(before) == 1, f"inert/ambiguous mutation: {mutation}"
    text = text.replace(before, after)
assert text != pathlib.Path(source).read_text(), 'SABOTAGE INERT'
pathlib.Path(target).write_text(text)
