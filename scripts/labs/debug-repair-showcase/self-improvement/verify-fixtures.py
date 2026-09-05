#!/usr/bin/env python3
"""Capture deliberate failures and check corrected fixtures outside agent authority."""
import json
import os
from support import OUT as root
import shutil
import subprocess

os.umask(0o077)
if (root / 'oracle-fixtures').exists():
    raise SystemExit('Fixtures were already checked; do not add duplicate captures.')
for case in ['span', 'queue', 'text']:
    failure = subprocess.run(['ptc', 'run', str(root / f'{case}.ptc-project.json')])
    if failure.returncode != 5:
        raise SystemExit(f'{case}: expected deliberate failure exit 5, got {failure.returncode}')
    destination = root / 'oracle-fixtures' / case
    shutil.copytree(root / 'incidents' / case, destination, ignore=shutil.ignore_patterns('.ptc'))
    if case == 'span':
        source = destination / 'page.stop.clj'
        source.write_text(source.read_text().replace('(inc (get request "end"))', '(get request "end")'))
    elif case == 'queue':
        source = destination / 'main.clj'
        source.write_text(source.read_text().replace('(vec (reverse ranked))', 'ranked'))
    else:
        source = destination / 'ptc.json'
        manifest = json.loads(source.read_text())
        manifest['input']['value']['expected'] = 'alpha beta'
        source.write_text(json.dumps(manifest, indent=2) + '\n')
    subprocess.run(['ptc', 'run', str(destination / 'ptc.json'), '--private-output', str(destination / 'result.private.json')], check=True)
