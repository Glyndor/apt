#!/usr/bin/env python3
"""Fake purge transport. Successful API requests evict precisely their URL list."""
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit

args = sys.argv[1:]
assert args[args.index('-X') + 1] == 'POST', args
assert any('/zones/test-zone/purge_cache' in arg for arg in args), args
urls = json.loads(args[args.index('--data') + 1])['files']
log = Path(os.environ['PURGE_CALLS'])
number = len(log.read_text().splitlines()) + 1 if log.exists() else 1
with log.open('a') as out:
    out.write(json.dumps(urls) + '\n')
if number == int(os.environ.get('FAIL_PURGE', '0')):
    print(json.dumps({'success': False, 'errors': [{'message': 'injected purge failure'}]}))
else:
    for url in urls:
        path = Path(os.environ['EDGE']) / urlsplit(url).path.lstrip('/')
        path.unlink(missing_ok=True)
    print(json.dumps({'success': True, 'errors': []}))
