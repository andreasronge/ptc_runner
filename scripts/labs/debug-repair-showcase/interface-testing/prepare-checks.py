#!/usr/bin/env python3
"""Prepare the deterministic probe and corrected fixtures outside model authority."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'self-improvement'))
from support import ROOT, write_json

os.umask(0o077)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sheet-run', required=True, help='captured sheet run ID obtained through PTC')
args = parser.parse_args()
out = ROOT / 'tmp/nav-interface-testing'
if (out / 'probe').exists() or (out / 'oracle-fixtures').exists():
    raise SystemExit('Checks were already prepared; do not overwrite them.')
(out / 'probe').mkdir()
shutil.copyfile(Path(__file__).with_name('probe.clj'), out / 'probe/main.clj')
write_json(out / 'probe/ptc.json', {
    'version': 1,
    'workflow': {'components': [{'id': 'main', 'path': 'main.clj', 'dependencies': ['kernel']}, {'library': 'kernel'}], 'entry': 'main/run'},
    'missions': {'evidence': {'components': [{'library': 'debug.nav'}], 'providers': ['debug.nav', 'failed-run-traces']}},
    'providers': {'mission': [{'name': 'debug.nav'}, {'name': 'failed-run-traces', 'config': {'expose': False}}]},
    'input': {'value': {'run_id': args.sheet_run}}, 'events': {'policy': 'private'},
})
for arm in ['baseline', 'recovery', 'docs']:
    (out / f'probe-{arm}').mkdir()
    write_json(out / f'probe-{arm}.ptc-project.json', {'kind': 'ptc-project', 'version': 1, 'application': {'path': 'probe/ptc.json'}, 'host': {'path': 'control-sheet.host.json'}, 'artifacts': {'root': f'probe-{arm}/.ptc', 'trace': True, 'inspection': True, 'result': True, 'envelope': True}})
for case in ['sheet', 'meter', 'record']:
    destination = out / 'oracle-fixtures' / case
    shutil.copytree(out / 'incidents' / case, destination, ignore=shutil.ignore_patterns('.ptc'))
    if case == 'sheet':
        source = destination / 'sheet.area.clj'
        source.write_text(source.read_text().replace('(+ (get request "width") (get request "height"))', '(* (get request "width") (get request "height"))'))
    elif case == 'meter':
        source = destination / 'main.clj'
        source.write_text(source.read_text().replace('(mapv #(- % offset) corrected)', 'corrected'))
    else:
        source = destination / 'ptc.json'
        manifest = json.loads(source.read_text())
        manifest['input']['value']['expected'] = 'green'
        write_json(source, manifest)
    subprocess.run(['ptc', 'run', str(destination / 'ptc.json'), '--private-output', str(destination / 'result.private.json')], check=True)
