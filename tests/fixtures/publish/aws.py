#!/usr/bin/env python3
"""Small S3 filesystem model: filters, size-only, upload/delete and partial failure.

Sorted and reverse ordering are deterministic probes, not promises of AWS order.
Every successful mutation is immediately readable, including the last before exit.
"""
import fnmatch
import json
import os
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
if args == ['--version']:
    print(os.environ.get('FAKE_AWS_VERSION', 'aws-cli/2.31.0 Python/3.13.7 Linux/6.8.0 exe/x86_64.ubuntu.26'))
    sys.exit(0)
# The endpoint arrives in the environment, never in argv.
assert '--endpoint-url' not in args, args
assert os.environ.get('AWS_ENDPOINT_URL') == 'https://r2.invalid', os.environ.get('AWS_ENDPOINT_URL')
# The script under test assigns BUCKET; keep the model's root independent.
bucket = Path(os.environ.get('FAKE_BUCKET', os.environ['BUCKET']))
assert bucket.is_dir(), bucket
with open(os.environ['AWS_CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\n')


def files(root):
    return {p.relative_to(root).as_posix(): p for p in root.rglob('*') if p.is_file()}


if args[:1] == ['s3api']:
    assert args[args.index('--bucket') + 1] == 'glyndor-apt', args
    if args[1] == 'list-objects-v2':
        prefix = args[args.index('--prefix') + 1]
        keys = sorted(key for key in files(bucket) if key.startswith(prefix))
        result = {'IsTruncated': os.environ.get('LIST_TRUNCATED') == '1',
                  'Contents': [{'Key': key} for key in keys]}
        # LIST_RESPONSE_AFTER answers the second listing of a run, the read-back after the deletes.
        listings = sum(1 for line in Path(os.environ['AWS_CALLS']).read_text().splitlines() if '"list-objects-v2"' in line)
        if os.environ.get('LIST_RESPONSE_AFTER') and listings >= 2:
            print(Path(os.environ['LIST_RESPONSE_AFTER']).read_text())
            sys.exit(0)
        if os.environ.get('LIST_RESPONSE'):
            print(Path(os.environ['LIST_RESPONSE']).read_text())
            sys.exit(0)
        print(json.dumps(result))
    elif args[1] == 'delete-object':
        key = args[args.index('--key') + 1]
        assert key.startswith('install/') and '..' not in key.split('/'), key
        if os.environ.get('IGNORE_DELETE') != '1':
            (bucket / key).unlink(missing_ok=True)
        if os.environ.get('DROP_BUILT_AFTER_DELETE'):
            (bucket / os.environ['DROP_BUILT_AFTER_DELETE']).unlink(missing_ok=True)
        with open(os.environ['AWS_WRITES'], 'a') as log:
            log.write(json.dumps([0, 'delete', key]) + '\n')
        deletes = Path(os.environ['DELETE_STATE']) if 'DELETE_STATE' in os.environ else None
        if deletes:
            count = int(deletes.read_text()) + 1 if deletes.exists() else 1
            deletes.write_text(str(count))
            if count == int(os.environ.get('FAIL_DELETE_AFTER', '0')):
                print('injected delete failure after visible mutation', file=sys.stderr)
                sys.exit(42)
    else:
        raise AssertionError(args)
    sys.exit(0)

# settle-pool-bytes.sh reads pool/ out of the bucket, and uploads one object by name.
if args[:3] == ['s3', 'sync', 's3://glyndor-apt/pool/']:
    assert args[4:] == ['--no-progress'] and args[3].endswith('/pool/'), args
    if os.environ.get('FAIL_DOWNLOAD') == '1':
        print('injected download failure', file=sys.stderr)
        sys.exit(42)
    for key, src in files(bucket).items():
        if key.startswith('pool/'):
            dst = Path(args[3]) / key.removeprefix('pool/')
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
    sys.exit(0)
if args[:2] == ['s3', 'cp']:
    key = args[2].removeprefix('public/')
    assert args[2] == 'public/' + key and key.startswith('pool/') and args[3] == 's3://glyndor-apt/' + key, args
    (bucket / key).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args[2], bucket / key)
    with open(os.environ['AWS_WRITES'], 'a') as log:
        log.write(json.dumps([0, 'upload', key]) + '\n')
    sys.exit(0)

assert args[:4] == ['s3', 'sync', 'public/', 's3://glyndor-apt/'], args
state = Path(os.environ['AWS_STATE'])
number = int(state.read_text()) + 1 if state.exists() else 1
state.write_text(str(number))
filters = []
for i, arg in enumerate(args):
    if arg in ('--include', '--exclude'):
        filters.append((arg == '--include', args[i + 1]))


def selected(key):
    include = True
    for value, pattern in filters:
        if fnmatch.fnmatchcase(key, pattern):
            include = value
    return include


source = files(Path('public'))
remote = files(bucket)
operations = []
for key, src in source.items():
    if not selected(key):
        continue
    dst = remote.get(key)
    if dst and src.stat().st_size == dst.stat().st_size:
        if '--size-only' in args or src.stat().st_mtime <= dst.stat().st_mtime:
            continue
    operations.append(('upload', key))
if '--delete' in args:
    operations.extend(('delete', key) for key in remote if key not in source and selected(key))
operations.sort(reverse=os.environ.get('OBJECT_ORDER') == 'reverse')
for count, (action, key) in enumerate(operations, 1):
    if action == 'upload':
        dst = bucket / key
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source[key], dst)
    else:
        remote[key].unlink()
    print(f'{action}: {key}', flush=True)
    with open(os.environ['AWS_WRITES'], 'a') as log:
        log.write(json.dumps([number, action, key]) + '\n')
    if number == int(os.environ.get('FAIL_PASS', '0')) and count == int(os.environ.get('FAIL_AFTER', '0')):
        print(f'injected aws failure: pass {number} after {count} writes', file=sys.stderr)
        sys.exit(42)
