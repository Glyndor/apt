#!/usr/bin/env bash
# Execute the shipped publish/purge bodies against local origin and edge trees.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import quote
import yaml

root = Path.cwd()
steps = yaml.safe_load((root / '.github/workflows/publish.yml').read_text())['jobs']['publish']['steps']
publish = next(s for s in steps if s.get('name') == 'Publish to R2')
purge = next(s for s in steps if s.get('name', '').startswith('Purge Cloudflare cache'))
passed = 0


def check(ok, message):
    global passed
    assert ok, message
    passed += 1
    print('ok   ', message, flush=True)


with tempfile.TemporaryDirectory() as temp:
    work = Path(temp)
    (work / 'bin').mkdir()
    (work / 'scripts').symlink_to(root / 'scripts', target_is_directory=True)
    for command in ('aws', 'curl'):
        (work / 'bin' / command).symlink_to(root / 'tests/fixtures/publish' / (command + '.py'))
    env = dict(os.environ, PATH=str(work / 'bin') + ':' + os.environ['PATH'],
               BUCKET=str(work / 'bucket'), FAKE_BUCKET=str(work / 'bucket'), EDGE=str(work / 'edge'),
               AWS_STATE=str(work / 'state'), AWS_CALLS=str(work / 'calls'),
               AWS_WRITES=str(work / 'writes'), DELETE_STATE=str(work / 'deletes'),
               PURGE_CALLS=str(work / 'purges'), ARCHIVE_URL='https://apt.invalid',
               CF_TOKEN='fixture', CF_ZONE='test-zone', CF_API_BASE='https://cloudflare.invalid',
               AWS_ACCESS_KEY_ID='fixture', AWS_SECRET_ACCESS_KEY='fixture',
               GLYNDOR_APT_R2_ENDPOINT='https://r2.invalid')
    # Read the workflow's actual hand-off, so dropping or misnaming it is observable.
    pruned = purge.get('env', {}).get('PRUNED_PATHS')
    if pruned:
        env['PRUNED_PATHS'] = pruned
    journal = work / 'pruned-installers.txt'
    removed = ['install/retired', 'install/retired panel', 'install/odd?#%name']

    def put(directory, key, value='fixture'):
        path = work / directory / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        os.utime(path, (1000, 1000))

    def records(name):
        path = work / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def reset():
        for directory in ('public', 'bucket', 'edge'):
            shutil.rmtree(work / directory, ignore_errors=True)
            (work / directory).mkdir()
        journal.unlink(missing_ok=True)
        put('public', 'dists/stable/main/binary-amd64/Packages', 'Filename: pool/current.deb\n')
        put('public', 'dists/stable/Release', 'SHA256:\n hash 1 main/binary-amd64/Packages\n')
        for key in ('dists/stable/InRelease', 'dists/stable/Release.gpg', 'pool/current.deb',
                    'glyndor-archive-keyring.deb', 'glyndor-archive-keyring.deb.asc',
                    'index.html', 'install/epistle', 'install/epistle-panel'):
            put('public', key)
        for key in removed + ['dists/stable/Release', 'pool/obsolete.deb']:
            put('bucket', key, 'old cached bytes')
            put('edge', key, 'old cached bytes')
        put('bucket', 'outside/sentinel', 'untouched')
        put('edge', 'outside/sentinel', 'untouched')

    def run(body, **overrides):
        return subprocess.run(['bash', '-e', '-c', body], cwd=work, env=dict(env, **overrides),
                              capture_output=True, text=True)

    def job(**overrides):
        for name in ('calls', 'writes', 'deletes', 'state', 'purges'):
            (work / name).unlink(missing_ok=True)
        first = run(publish['run'], **overrides)
        if first.returncode:
            return first
        return run(purge['run'], **overrides)

    def covered(result, label):
        check(result.returncode == 0 and 'Cloudflare cache purged,' in result.stdout,
              label + ': workflow publication and purge succeed: ' + result.stderr)
        urls = [u for batch in records('purges') for u in batch]
        check(all('https://apt.invalid/' + quote(k, safe='/') in urls for k in removed),
              label + ': payload covers every removed URL, with path encoding')
        check(all(not (work / 'bucket' / k).exists() and not (work / 'edge' / k).exists() for k in removed),
              label + ': removed origin and cached copies are both gone')
        check((work / 'bucket/install/epistle').exists() and (work / 'bucket/install/epistle-panel').exists(),
              label + ': built sibling installers remain readable')
        check((work / 'bucket/outside/sentinel').read_text() == 'untouched'
              and (work / 'edge/outside/sentinel').read_text() == 'untouched',
              label + ': origin and edge outside install remain intact')
        check(not any(u == 'https://apt.invalid/' for u in urls), label + ': never purges archive root')
        calls = records('calls')
        delete_at = next(i for i, record in enumerate(calls) if record[1] == 'delete-object')
        check(len([c for c in calls[:delete_at] if c[:2] == ['s3', 'sync']]) == 3
              and (work / 'bucket/dists/stable/Release').read_bytes()
              == (work / 'public/dists/stable/Release').read_bytes(),
              label + ': metadata published before the first installer delete')
        check(all('/dists/' not in u for u in records('purges')[0])
              and all('/dists/' in u for u in records('purges')[-1]),
              label + ': content purged before metadata')

    reset()
    covered(job(), 'positive control')
    reset()
    result = job(FAIL_DELETE_AFTER='1')
    check(result.returncode == 42 and 'injected delete failure' in result.stderr,
          'partial prune fails the actual publish step')
    check(not records('purges') and all((work / 'edge' / k).exists() for k in removed),
          'failed prune stops the job before any purge')
    covered(job(), 'retry after partial prune')
    reset()
    result = job(FAIL_PASS='2', FAIL_AFTER='1')
    check(result.returncode == 42 and not any(c[1] == 'delete-object' for c in records('calls')),
          'metadata failure prevents installer pruning')
    check(not records('purges'), 'metadata failure prevents purge')

    reset()
    result = run(publish['run'])
    check(result.returncode == 0, 'origin prepared for purge rejection controls')
    for bad, reason in [('missing', 'missing'), ('directory', 'missing'),
                        ('outside', 'not under install/'), ('traversal', "containing '..'")]:
        if journal.is_dir():
            journal.rmdir()
        else:
            journal.unlink(missing_ok=True)
        if bad == 'directory':
            journal.mkdir()
        elif bad == 'outside':
            journal.write_text('pool/obsolete.deb\n')
        elif bad == 'traversal':
            journal.write_text('install/../index.html\n')
        (work / 'purges').unlink(missing_ok=True)
        result = run(purge['run'])
        check(result.returncode != 0 and reason in result.stdout + result.stderr,
              'purge rejects journal: ' + bad)
        check(not records('purges'), 'invalid journal fails before any edge request: ' + bad)
    journal.write_text('')
    result = run(purge['run'])
    check(result.returncode == 0, 'existing empty journal permits ordinary purge')
    check(not any(u == 'https://apt.invalid/' for b in records('purges') for u in b),
          'empty journal never becomes archive root URL')
    journal.write_text('install/retired\n')
    (work / 'purges').unlink(missing_ok=True)
    result = run(purge['run'], FAIL_PURGE='1')
    check(result.returncode != 0 and 'installers this publish removed were not purged' in result.stdout,
          'failed API purge reports that removed installer copies can remain cached')
    check('Cloudflare cache purged,' not in result.stdout, 'failed purge never declares success')

print(f'{passed} passed, 0 failed')
print(f'DONE purge-cache-pruned.test.sh {passed} 0')
PY
