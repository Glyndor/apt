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
