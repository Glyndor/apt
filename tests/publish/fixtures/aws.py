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
assert args[:4] == ['s3', 'sync', 'public/', 's3://glyndor-apt/'], args
bucket = Path(os.environ['BUCKET'])
state = Path(os.environ['AWS_STATE'])
number = int(state.read_text()) + 1 if state.exists() else 1
state.write_text(str(number))
with open(os.environ['AWS_CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\n')
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


def files(root):
    return {p.relative_to(root).as_posix(): p for p in root.rglob('*') if p.is_file()}


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
