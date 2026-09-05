#!/usr/bin/env python3
"""Run the frozen control and candidate; PTC owns all capture interpretation."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import argparse
from support import OUT as root

os.umask(0o077)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--env-file', type=Path, required=True)
parser.add_argument('--coach-run', required=True, help='completed coach run ID, obtained through ptc repl')
args = parser.parse_args()
if (root / 'comparison.json').exists():
    raise SystemExit('This comparison was already started; use a new experiment directory.')
for arm in ['control', 'candidate']:
    assert (root / f'frozen/{arm}.input.json').is_file()
# Hash artifact bytes to identify the frozen input; do not parse derived results.
metadata = {'samples': 3, 'model': 'openrouter:deepseek/deepseek-v4-flash',
            'input_sha256': {arm: hashlib.sha256((root / f'frozen/{arm}.input.json').read_bytes()).hexdigest() for arm in ['control', 'candidate']},
            'coach_run': args.coach_run, 'training_run': 'cmd-3c1q7epwzdvf0y7m3nf98xfhm5',
            'selection': 'one coach candidate, frozen before evaluation; no retries'}
(root / 'comparison.json').write_text(json.dumps(metadata, indent=2) + '\n')
# Launch paired arms in each sample wave; do not run all controls first.
for sample in range(1, 4):
    cells = [(arm, case) for case in ['span', 'queue', 'text'] for arm in (['control', 'candidate'] if sample % 2 else ['candidate', 'control'])]
    def run(cell):
        arm, case = cell
        name = f'{arm}-{case}'
        output = root / name
        with (output / f'sample-{sample}.stdout').open('wb') as stdout, (output / f'sample-{sample}.stderr').open('wb') as stderr:
            result = subprocess.run(['ptc', 'run', str(root / f'{name}.ptc-project.json'), '--env-file', str(args.env_file.resolve()), '--input', str(root / f'frozen/{arm}.input.json'), '--progress', '--private-output', str(output / f'sample-{sample}.private.json')], stdout=stdout, stderr=stderr)
        print(f'{name} sample {sample}: exit {result.returncode}', flush=True)
    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(run, cells))
