#!/usr/bin/env python3
"""Run the fixed twelve one-call trials without inspecting their outputs."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
os.umask(0o077)
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--env-file',type=Path,required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[4]
out=root/'tmp/nav-decision-replay'
cells=['recovery-terse','recovery-actionable','ambiguity-control','ambiguity-reminder']
plan=out/'plan.json'
with plan.open('x') as f:
    json.dump({'samples':3,'model':'openrouter:deepseek/deepseek-v4-flash','input_sha256':{c:hashlib.sha256((out/'inputs'/f'{c}.json').read_bytes()).hexdigest() for c in cells},'evaluation':'next action only; no generated program execution; all failures retained'},f,indent=2)
def run(cell):
    for sample in range(1,4):
        with (out/cell/f'{sample}.stdout').open('xb') as stdout, (out/cell/f'{sample}.stderr').open('xb') as stderr:
            r=subprocess.run(['ptc','run',str(out/f'{cell}.ptc-project.json'),'--private-input',str(out/'inputs'/f'{cell}.json'),'--env-file',str(a.env_file.resolve()),'--private-output',str(out/cell/f'{sample}.private.json')],cwd=root,stdout=stdout,stderr=stderr)
        print(f'{cell} {sample}: exit {r.returncode}',flush=True)
with ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(run,cells))
