#!/usr/bin/env python3
"""Run three fixed navigation interfaces; inspect all captures with PTC."""
import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
import hashlib
import json
import os
from pathlib import Path
import subprocess

os.umask(0o077)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--env-file', type=Path, required=True)
args = parser.parse_args()
if not args.env_file.is_file():
    parser.error('the environment file must exist')
out = Path(__file__).resolve().parents[4] / 'tmp/nav-interface-testing'
if (out / 'comparison.json').exists():
    raise SystemExit('This comparison was already started; do not overwrite it.')
for arm in ['docs', 'recovery']:
    if not (out / f'{arm}-override/descriptor.json').is_file():
        raise SystemExit('Materialize both candidate overrides first.')
plan = {'samples_per_cell': 3, 'arms': ['control', 'docs', 'recovery'], 'cases': ['sheet', 'meter', 'record'],
        'model': 'openrouter:deepseek/deepseek-v4-flash', 'max_concurrent_runs': 6,
        'source_sha256': {arm: hashlib.sha256((out / (('original' if arm == 'control' else arm) + '.clj')).read_bytes()).hexdigest() for arm in ['control', 'docs', 'recovery']},
        'selection': 'single fixed candidate per intervention; all outcomes retained; no whole-run retries'}
(out / 'comparison.json').write_text(json.dumps(plan, indent=2) + '\n')


def run(job):
    arm, case, sample = job
    name = f'{arm}-{case}'
    cell = out / name
    command = ['ptc', 'run', str(out / f'{name}.ptc-project.json'), '--env-file', str(args.env_file.resolve()), '--progress', '--private-output', str(cell / f'sample-{sample}.private.json')]
    if arm != 'control':
        command += ['--component-override-descriptor', str(out / f'{arm}-override/descriptor.json')]
    with (cell / f'sample-{sample}.stdout').open('wb') as stdout, (cell / f'sample-{sample}.stderr').open('wb') as stderr:
        result = subprocess.run(command, stdout=stdout, stderr=stderr)
    print(f'{name} sample {sample}: exit {result.returncode}', flush=True)
    return job


# A cell never overlaps itself. Requeue it after other waiting cells so no arm
# waits for every run in an earlier arm to finish before receiving a turn.
ready = deque((arm, case, 1) for case in plan['cases'] for arm in plan['arms'])
with ThreadPoolExecutor(max_workers=6) as pool:
    active = set()
    while ready or active:
        while ready and len(active) < 6:
            active.add(pool.submit(run, ready.popleft()))
        done, active = wait(active, return_when=FIRST_COMPLETED)
        for future in done:
            arm, case, sample = future.result()
            if sample < 3:
                ready.append((arm, case, sample + 1))
