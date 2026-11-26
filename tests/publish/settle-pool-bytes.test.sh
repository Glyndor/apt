#!/usr/bin/env bash
# What a publish does with a pool name the bucket already holds, driven through
# sync-archive.sh against a local model of the bucket. No credentials, sockets
# or real AWS calls are involved.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
passed = 0


def check(condition, message):
    global passed
    assert condition, message
    passed += 1
    print('ok   ', message, flush=True)


def tree(path):
    return {p.relative_to(path).as_posix(): p.read_bytes()
            for p in path.rglob('*') if p.is_file()}


def put(base, key, value, stamp):
    path = base / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value)
    os.utime(path, (stamp, stamp))


PRODUCT = 'pool/main/p/podup/podup_6.1.0_amd64.deb'
OTHER = 'pool/main/e/epistle/epistle_0.14.0+r1_arm64.deb'
ADDED = 'pool/main/p/podup/podup_6.2.0_amd64.deb'
KEYRING = 'pool/main/g/glyndor-archive-keyring/glyndor-archive-keyring_1.0.0+pkg1_all.deb'
BUILT = {PRODUCT: b'product bytes A', OTHER: b'other bytes A', KEYRING: b'keyring bytes A',
         'dists/stable/InRelease': b'new index'}
HELD = dict(BUILT, **{'dists/stable/InRelease': b'old index'})
IMMUTABLE = ['--cache-control', 'public, max-age=31536000, immutable']

with tempfile.TemporaryDirectory() as temp:
    work = Path(temp)
    (work / 'bin').mkdir()
    (work / 'bin/aws').symlink_to(root / 'tests/fixtures/publish/aws.py')
    (work / 'tmp').mkdir()
    env = dict(os.environ, PATH=str(work / 'bin') + ':' + os.environ['PATH'], TMPDIR=str(work / 'tmp'),
               AWS_ACCESS_KEY_ID='fixture', AWS_SECRET_ACCESS_KEY='fixture',
               AWS_ENDPOINT_URL='https://r2.invalid', BUCKET=str(work / 'bucket'),
               FAKE_BUCKET=str(work / 'bucket'), AWS_STATE=str(work / 'state'),
               AWS_CALLS=str(work / 'aws-calls'), AWS_WRITES=str(work / 'writes'))

    def publish(held, built=BUILT, extra=None):
        for directory in ('public', 'bucket'):
            shutil.rmtree(work / directory, ignore_errors=True)
            (work / directory).mkdir()
        for name in ('state', 'aws-calls', 'writes'):
            (work / name).unlink(missing_ok=True)
        for key, value in built.items():
            put(work / 'public', key, value, 2000)
        for key, value in held.items():
            put(work / 'bucket', key, value, 1000)
        result = subprocess.run(['bash', str(root / 'scripts/publish/sync-archive.sh')], cwd=work,
                                env=dict(env, **(extra or {})), capture_output=True, text=True)
        check(not list((work / 'tmp').iterdir()), 'the downloaded pool is removed')
        return result

    def records(name):
        path = work / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def refused(result, held, keys, label):
        check(result.returncode == 1, label + ': the publish fails')
        for key in keys:
            check(f'::error::{key} is already in the bucket with other bytes' in result.stdout,
                  label + f': {key} is named')
        check(result.stdout.count('::error::') == len(keys), label + ': and nothing else is')
        check(not records('writes') and tree(work / 'bucket') == held, label + ': nothing is written')

    result = publish(HELD)
    check(result.returncode == 0 and tree(work / 'bucket') == BUILT, 'identical pool bytes publish')
    check('::warning::' not in result.stdout and not [c for c in records('aws-calls') if c[:2] == ['s3', 'cp']],
          'and no pool object is uploaded by name')

    result = publish(HELD, dict(BUILT, **{ADDED: b'a new release'}))
    check(result.returncode == 0 and tree(work / 'bucket') == dict(BUILT, **{ADDED: b'a new release'}),
          'a name the bucket does not hold is uploaded')
    result = publish({})
    check(result.returncode == 0 and tree(work / 'bucket') == BUILT, 'an empty bucket publishes')

    for size, value in (('the same size', b'product bytes B'), ('another size', b'longer product bytes')):
        held = dict(HELD, **{PRODUCT: value})
        refused(publish(held), held, [PRODUCT], 'a product package of ' + size + ' with other bytes')
    held = dict(HELD, **{PRODUCT: b'product bytes B', OTHER: b'other bytes B', KEYRING: b'keyring bytes B'})
    result = publish(held)
    refused(result, held, [PRODUCT, OTHER], 'two packages and the keyring differ')
    check('::warning::' not in result.stdout, 'the keyring is not uploaded beside a refused package')

    for size, value in (('the same size', b'keyring bytes B'), ('another size', b'a longer keyring')):
        label = 'a rebuilt keyring of ' + size
        result = publish(dict(HELD, **{KEYRING: value}))
        check(result.returncode == 0 and tree(work / 'bucket') == BUILT, label + ': the built bytes are served')
        check(f'::warning::{KEYRING} was rebuilt with other bytes under the same name' in result.stdout,
              label + ': it is reported')
        check([c for c in records('aws-calls') if c[:2] == ['s3', 'cp']]
              == [['s3', 'cp', 'public/' + KEYRING, 's3://glyndor-apt/' + KEYRING, '--no-progress'] + IMMUTABLE],
              label + ': uploaded once, with the cache header of the pool')
        check(records('writes')[0] == [0, 'upload', KEYRING], label + ': before the index that declares it')

    result = publish(HELD, extra={'FAIL_DOWNLOAD': '1'})
    check(result.returncode != 0 and 'injected download failure' in result.stderr,
          'a pool that cannot be read fails the publish')
    check(not records('writes') and tree(work / 'bucket') == HELD and len(records('aws-calls')) == 1,
          'and nothing is written')

print(f'{passed} passed, 0 failed')
print(f'DONE settle-pool-bytes.test.sh {passed} 0')
PY
