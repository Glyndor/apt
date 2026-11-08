#!/usr/bin/env bash
# Execute the real prune against the shared readable S3 filesystem model.
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


def check(ok, message):
    global passed
    assert ok, message
    passed += 1
    print('ok   ', message, flush=True)


with tempfile.TemporaryDirectory() as temp:
    work = Path(temp)
    (work / 'bin').mkdir()
    (work / 'bin/aws').symlink_to(root / 'tests/fixtures/publish/aws.py')
    env = dict(os.environ, PATH=str(work / 'bin') + ':' + os.environ['PATH'],
               BUCKET=str(work / 'bucket'), FAKE_BUCKET=str(work / 'bucket'), AWS_CALLS=str(work / 'calls'),
               AWS_WRITES=str(work / 'writes'), DELETE_STATE=str(work / 'deletes'))
    built, bucket, journal = (work / name for name in ('built', 'bucket', 'pruned'))

    def put(base, key):
        path = base / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('bytes for ' + key)

    def keys():
        return {p.relative_to(bucket).as_posix(): p.read_bytes()
                for p in bucket.rglob('*') if p.is_file()}

    def records():
        log = work / 'calls'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def reset(names=('epistle', 'epistle-panel', 'with space')):
        for path in (built, bucket):
            shutil.rmtree(path, ignore_errors=True)
            path.mkdir()
        for name in ('calls', 'writes', 'deletes', 'pruned'):
            (work / name).unlink(missing_ok=True)
        for name in names:
            put(built, name)
            put(bucket, 'install/' + name)
        for key in ('pool/old.deb', 'dists/stable/Release', 'index.html',
                    'install-sibling/product', 'installer/product'):
            put(bucket, key)

    def run(**overrides):
        return subprocess.run(['bash', str(root / 'scripts/publish/prune-installers.sh'),
                               str(built), 'glyndor-apt', 'https://r2.invalid', str(journal)],
                              env=dict(env, **overrides), capture_output=True, text=True)

    def refused(result, reason, before):
        check(result.returncode != 0 and reason in result.stdout + result.stderr,
              'named refusal: ' + reason)
        check(keys() == before and not any(c[1] == 'delete-object' for c in records()),
              'refusal makes no delete call and changes no origin bytes')

    reset()
    put(bucket, 'install/retired product')
    before = keys()
    result = run()
    check(result.returncode == 0, 'positive control: prune succeeds: ' + result.stderr)
    check(keys() == {k: v for k, v in before.items() if k != 'install/retired product'},
          'only retired installer removed; spaces, siblings and all other bytes intact')
    deletes = [c for c in records() if c[1] == 'delete-object']
    check(len(deletes) == 1 and deletes[0][deletes[0].index('--key') + 1] == 'install/retired product',
          'space-containing key is exactly one AWS argument')
    check(journal.read_text().splitlines() == ['install/retired product'], 'purge journal names removed key')
    check(all('--no-paginate' in c for c in records() if c[1] == 'list-objects-v2'),
          'single response exposes IsTruncated instead of CLI auto-pagination')
    for names, retired in ((('epistle-panel',), 'epistle'), (('epistle',), 'epistle-panel')):
        reset(names)
        put(bucket, 'install/' + retired)
        result = run()
        check(result.returncode == 0 and (bucket / ('install/' + names[0])).is_file()
              and not (bucket / ('install/' + retired)).exists(), 'sibling prefix safe: ' + retired)

    reset()
    shutil.rmtree(built)
    built.mkdir()
    refused(run(), 'no bootstrap installer was built', keys())
    reset()
    put(built, 'line\nbreak')
    refused(run(), 'invalid built installer name', keys())
    reset()
    refused(run(LIST_TRUNCATED='1'), 'not complete', keys())
    # Validate the entire response before deleting even its first valid stale key.
    for response, reason in [
        ({'Contents': []}, 'not complete'),
        ({'IsTruncated': 'false', 'Contents': []}, 'not complete'),
        ({'IsTruncated': False, 'Contents': 'wrong'}, 'invalid installer listing'),
        ({'IsTruncated': False, 'Contents': False}, 'invalid installer listing'),
        ({'IsTruncated': False, 'Contents': None}, 'invalid installer listing'),
        ({'IsTruncated': False, 'Contents': [{'Key': 42}]}, 'invalid installer listing'),
        ({'IsTruncated': False, 'Contents': [{}]}, 'invalid installer listing'),
        ({'IsTruncated': False, 'Contents': [{'Key': 'install/epistle'}, {'Key': 'install/epistle-panel'},
                                                   {'Key': 'install/with space'}, {'Key': 'install/retired'},
                                                   {'Key': 'pool/old.deb'}]},
         'not under install/'),
        ({'IsTruncated': False, 'Contents': [{'Key': 'install/retired\ninstall/epistle'}]},
         'invalid installer listing'),
        ({'IsTruncated': False, 'Contents': [{'Key': 'install/../index.html'}]},
         'unsafe installer key'),
    ]:
        reset()
        response_file = work / 'response.json'
        response_file.write_text(json.dumps(response))
        refused(run(LIST_RESPONSE=str(response_file)), reason, keys())

    # Empty listings (omitted Contents is legal) do not authorize any deletion.
    for response in ({'IsTruncated': False}, {'IsTruncated': False, 'Contents': []}):
        reset()
        response_file.write_text(json.dumps(response))
        refused(run(LIST_RESPONSE=str(response_file)), 'built installer is missing', keys())
    reset()
    (bucket / 'install/epistle').unlink()
    refused(run(), 'built installer is missing', keys())
    reset()
    put(bucket, 'install/retired')
    result = run(IGNORE_DELETE='1')
    check(result.returncode != 0 and 'still serves installers' in result.stderr,
          'read-back rejects acknowledged but ineffective delete')
    check('the bucket serves exactly the ' not in result.stdout, 'ineffective delete never declares success')

    reset()
    put(bucket, 'install/retired')
    result = run(DROP_BUILT_AFTER_DELETE='install/epistle')
    check(result.returncode != 0 and 'built installer is missing' in result.stderr,
          'read-back catches a built installer disappearing during pruning')
    check('the bucket serves exactly the ' not in result.stdout,
          'missing built installer never declares success')
    for text, reason in [('pool/old.deb\n', 'invalid removed paths journal'),
                         ('install/../index.html\n', 'unsafe removed paths journal'),
                         ('install/tab\tname\n', 'unsafe removed paths journal')]:
        reset()
        put(bucket, 'install/retired')
        journal.write_text(text)
        refused(run(), reason, keys())

    reset()
    put(bucket, 'install/retired-a')
    put(bucket, 'install/retired-b')
    result = run(FAIL_DELETE_AFTER='1')
    check(result.returncode == 42 and 'injected delete failure' in result.stderr,
          'partial delete failure propagates exact exit')
    check('the bucket serves exactly the ' not in result.stdout, 'partial failure never declares success')
    check(not (bucket / 'install/retired-a').exists() and (bucket / 'install/retired-b').exists(),
          'one visible delete happened before failure')
    check(set(journal.read_text().splitlines()) == {'install/retired-a', 'install/retired-b'},
          'purge journal exists before the first destructive call')
    result = run()
    check(result.returncode == 0 and not list(bucket.glob('install/retired-*')),
          'second run converges without rollback')
    check(set(journal.read_text().splitlines()) == {'install/retired-a', 'install/retired-b'},
          'retry retains first-run removals for edge purge')
    result = run()
    check(result.returncode == 0 and 'no installer to prune' in result.stdout,
          'third run is idempotent')
    reset()
    journal.mkdir()
    put(bucket, 'install/retired')
    refused(run(), 'removed paths', keys())

    shutil.rmtree(journal)
    reset()
    before = keys()
    result = subprocess.run(['bash', str(root / 'scripts/publish/prune-installers.sh'),
                             str(built), 'bad/bucket', 'https://r2.invalid', str(journal)],
                            env=env, capture_output=True, text=True)
    check(result.returncode == 2 and 'the bucket must be a plain name' in result.stderr,
          'a bucket name with a slash is refused with exit 2')
    check(keys() == before and not any(c[1] == 'delete-object' for c in records()),
          'the refused bucket name makes no delete call')

print(f'{passed} passed, 0 failed')
print(f'DONE prune-installers.test.sh {passed} 0')
PY
