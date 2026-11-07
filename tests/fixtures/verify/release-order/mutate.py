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
    # The parser that opened a stanza at its Package line and skipped one with
    # no Version: Version ahead of Package no longer reaches the product.
    "order": [
        ('for stanza in re.split(r"\\n[ \\t]*\\n", text.replace("\\r\\n", "\\n")):',
         'for stanza in re.split(r"\\n(?=Package:)", text):'),
        ('sys.exit(f"a stanza of {product} does not declare its Version exactly once")',
         'continue'),
    ],
    "once": ('if len(fields.get("Version", [])) != 1:',
             'if len(fields.get("Version", [])) < 1:'),
    "arch": ('if declared - listed:', 'if False:'),
    # The full Debian version comparison, the check that candidates exist, that
    # they are the product, and that their versions are valid.
    "debian": [('if comparison.returncode == 0:', 'if False:'),
               ('if comparison.returncode != 1:', 'if False:')],
    "debian_pass": ('if comparison.returncode == 0:', 'if True:'),
    "nodebs": ('if not debs:', 'if False:'),
    "package": ('package.stdout.strip() != product or ', ''),
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
    pairs = changes[mutation]
    for before, after in pairs if isinstance(pairs, list) else [pairs]:
        assert text.count(before) == 1, f"inert/ambiguous mutation: {mutation}"
        text = text.replace(before, after)
assert text != pathlib.Path(source).read_text(), 'SABOTAGE INERT'
pathlib.Path(target).write_text(text)
