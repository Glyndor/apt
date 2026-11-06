#!/usr/bin/env bash
# Exercise the shipped sync and purge steps against a readable local origin/edge.
# No credentials, sockets or real AWS/Cloudflare calls are involved.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import hashlib
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


def archive(generation):
    result = {'pool/shared.deb': b'reproducible keyring'}
    packages = [f'pool/product_{generation}_{arch}.deb' for arch in ('amd64', 'arm64', 'all')]
    result.update({key: key.encode() for key in packages})
    for arch in ('amd64', 'arm64'):
        prefix = f'dists/stable/main/binary-{arch}/'
        result[prefix + 'Packages'] = ''.join(
            f'Filename: {key}\n\n' for key in packages + ['pool/shared.deb']).encode()
        result[prefix + 'Packages.gz'] = b'compressed ' + result[prefix + 'Packages']
        result[prefix + 'Release'] = f'architecture {arch} generation {generation}'.encode()
    release = b'SHA256:\n' + b''.join(
        f' {hashlib.sha256(value).hexdigest()} {len(value)} {key.removeprefix("dists/stable/")}\n'.encode()
        for key, value in result.items() if key.startswith('dists/'))
    result.update({'dists/stable/Release': release,
                   'dists/stable/InRelease': b'signed fixture ' + release,
                   'dists/stable/Release.gpg': f'signature {generation}'.encode(),
                   'glyndor-archive-keyring.deb': f'keyring {generation}'.encode(),
                   'glyndor-archive-keyring.deb.asc': f'keyring signature {generation}'.encode(),
                   'install/product': f'installer {generation}'.encode(),
                   'index.html': f'page {generation}'.encode()})
    return result


old, new = archive('old'), archive('new')
retired = 'dists/stable/retired-index'
old[retired] = b'allowed residual metadata'
old_pool = {key for key in old if key.startswith('pool/') and key not in new}
new_pool = {key for key in new if key.startswith('pool/') and key not in old}
mutable = {key for key in new if not key.startswith('pool/')}

# Extract the actual block bodies, so fail-fast and delegation are exercised too.
lines = (root / '.github/workflows/publish.yml').read_text().splitlines()


def step(name):
    start = next(i for i, line in enumerate(lines) if line.startswith('      - name: ' + name))
    run = next(i for i in range(start + 1, len(lines)) if lines[i] == '        run: |')
    body = []
    for line in lines[run + 1:]:
        if line.strip() and not line.startswith(' ' * 10):
            break
        body.append(line[10:])
    return '\n'.join(body) + '\n'


publish = step('Publish to R2')
purge = step('Purge Cloudflare cache')
check('./scripts/publish/sync-archive.sh' in publish, 'workflow delegates to the script under test')
check('./scripts/publish/purge-cache.sh' in purge, 'workflow delegates to the real purge script')
expected_calls = []
for number in (1, 2, 3):
    args = ['s3', 'sync', 'public/', 's3://glyndor-apt/', '--endpoint-url', 'https://r2.invalid']
    if number == 3:
        args += ['--delete']
    args += ['--no-progress']
    if number != 2:
        args += ['--size-only', '--exclude', '*', '--include', 'pool/*']
    else:
        args += ['--exclude', 'pool/*']
    args += ['--cache-control', 'public, max-age=86400' if number == 2
             else 'public, max-age=31536000, immutable']
    expected_calls.append(args)

with tempfile.TemporaryDirectory() as temp:
    work = Path(temp)
    (work / 'scripts').symlink_to(root / 'scripts', target_is_directory=True)
    (work / 'bin').mkdir()
    for command in ('aws', 'curl'):
        (work / 'bin' / command).symlink_to(root / 'tests/publish/fixtures' / (command + '.py'))
    for name, body in [('publish', publish), ('purge', purge)]:
        (work / (name + '.sh')).write_text(body)
    # Separate bash -e processes match Actions steps. A failed step stops the job.
    (work / 'job.sh').write_text('bash -e publish.sh\nbash -e purge.sh\necho PUBLICATION_COMPLETE\n')
    env = dict(os.environ, PATH=str(work / 'bin') + ':' + os.environ['PATH'],
               AWS_ACCESS_KEY_ID='fixture', AWS_SECRET_ACCESS_KEY='fixture',
               GLYNDOR_APT_R2_ENDPOINT='https://r2.invalid', CF_TOKEN='fixture', CF_ZONE='test-zone',
               ARCHIVE_URL='https://apt.invalid', CF_API_BASE='https://cloudflare.invalid',
               BUCKET=str(work / 'bucket'), EDGE=str(work / 'edge'),
               AWS_STATE=str(work / 'state'), AWS_CALLS=str(work / 'aws-calls'),
               AWS_WRITES=str(work / 'writes'), PURGE_CALLS=str(work / 'purges'))

    def reset():
        for directory in ('public', 'bucket', 'edge'):
            shutil.rmtree(work / directory, ignore_errors=True)
            (work / directory).mkdir()
        for key, value in new.items():
            put(work / 'public', key, value, 2000)
        for key, value in old.items():
            put(work / 'bucket', key, value, 1000)
            if not key.startswith('pool/'):
                put(work / 'edge', key, value, 1000)
        put(work / 'edge', 'pool/shared.deb', b'bad cached copy', 1000)

    def run(fail_pass=0, after=0, fail_purge=0, order='forward', missing=None):
        for name in ('state', 'aws-calls', 'writes', 'purges'):
            (work / name).unlink(missing_ok=True)
        current = dict(env, FAIL_PASS=str(fail_pass), FAIL_AFTER=str(after),
                       FAIL_PURGE=str(fail_purge), OBJECT_ORDER=order)
        if missing:
            current.pop(missing)
        return subprocess.run(['bash', '-e', 'job.sh'], cwd=work, env=current,
                              capture_output=True, text=True)

    def records(name):
        path = work / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def converged(result, label):
        check(result.returncode == 0 and 'PUBLICATION_COMPLETE' in result.stdout, label + ': retry succeeds')
        check(tree(work / 'bucket') == dict(new, **{retired: old[retired]}),
              label + ': origin converges, with allowed residual metadata')
        edge = tree(work / 'edge')
        check(all(edge.get(key, tree(work / 'bucket').get(key)) == value for key, value in new.items()),
              label + ': all published URLs are readable through the edge with correct bytes')
        check(records('aws-calls') == expected_calls, label + ': exact AWS argv and pass order')
        check(len(records('purges')) == 2, label + ': content and index purges both execute')

    reset()
    converged(run(), 'positive control')
    # All credentials must fail before the first write, not merely at fake AWS.
    for credential in ('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'GLYNDOR_APT_R2_ENDPOINT'):
        reset()
        result = run(missing=credential)
        check(result.returncode != 0 and credential + ' is not configured.' in result.stdout,
              credential + ': named credential rejection')
        check(not records('aws-calls') and tree(work / 'bucket') == old, 'credential rejection writes nothing')

    for order in ('forward', 'reverse'):
        for phase, count in ((1, len(new_pool)), (2, len(mutable)), (3, len(old_pool))):
            for after in range(1, count + 1):
                label = f'{order} pass {phase} after {after}/{count}'
                reset()
                result = run(phase, after, order=order)
                check(result.returncode == 42 and f'injected aws failure: pass {phase} after {after} writes'
                      in result.stderr, label + ': preserves the injected failure')
                check('PUBLICATION_COMPLETE' not in result.stdout and not records('purges'),
                      label + ': no success or purge after failed sync')
                check(records('aws-calls') == expected_calls[:phase], label + ': no later sync executes')
                writes = records('writes')
                last = [entry for entry in writes if entry[0] == phase]
                check(len(last) == after, label + ': failure occurs after N visible mutations')
                expected = dict(old)
                if phase >= 2:
                    expected.update({key: new[key] for key in new_pool})
                if phase == 3:
                    expected.update({key: new[key] for key in mutable})
                for _, action, key in last:
                    if action == 'upload':
                        expected[key] = new[key]
                    else:
                        expected.pop(key)
                check(tree(work / 'bucket') == expected, label + ': exact accessible keys and bytes')
                # Pass 2 may mix metadata generations; all referenced pool versions still exist.
                if phase <= 2:
                    indices = [value for key, value in expected.items() if key.endswith('/Packages')]
                    check(all(line.split()[1] in expected for value in indices
                              for line in value.decode().splitlines() if line.startswith('Filename:')),
                          label + ': every visible Packages reference remains accessible')
                else:
                    check(len(old_pool - expected.keys()) == after,
                          label + ': stale edge indices can reference already deleted packages')
                check(tree(work / 'edge').get('dists/stable/InRelease') == old['dists/stable/InRelease'],
                      label + ': failed sync leaves the previous cached index')
                check('upload: ' in result.stdout, label + ': AWS output remains visible')
                converged(run(order=order), label)

    for batch, group in ((1, 'content'), (2, 'index')):
        reset()
        result = run(fail_purge=batch)
        label = f'purge {group} failure'
        check(result.returncode != 0 and f'Cloudflare purge failed on {group} batch {batch}' in result.stdout
              and 'injected purge failure' in result.stdout, label + ': real purge rejects API response')
        check('PUBLICATION_COMPLETE' not in result.stdout and 'Cloudflare cache purged,' not in result.stdout,
              label + ': no success declared')
        check(tree(work / 'bucket') == dict(new, **{retired: old[retired]}), label + ': origin already replaced')
        check(len(records('purges')) == batch, label + ': no subsequent purge batch')
        edge = tree(work / 'edge')
        check(edge['dists/stable/InRelease'] == old['dists/stable/InRelease'], label + ': stale index stays cached')
        check(all(key not in tree(work / 'bucket') for key in old_pool),
              label + ': stale index references missing origin packages; no rollback')
        check(('install/product' in edge) == (batch == 1), label + ': exact partial content eviction')
        converged(run(), label)

print(f'{passed} passed, 0 failed')
print(f'DONE sync-archive.test.sh {passed} 0')
PY
