#!/usr/bin/env python3
"""Run each nonterminal sampled continuation once; PTC owns all analysis."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
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
out=root/'tmp/nav-decision-continuation'
labels=['control-inspect','control-incomplete','reminder-metadata','reminder-inspect-1','reminder-inspect-2']
with (out/'plan.json').open('x') as f:
    json.dump({'labels':labels,'additional_calls_per_trial':1,'original_terminal_trial':'control-diagnose, replayed without an additional model call','input_sha256':{label:hashlib.sha256((out/'inputs'/f'{label}.json').read_bytes()).hexdigest() for label in labels},'model':'openrouter:deepseek/deepseek-v4-flash','output_tokens':4096,'selection':'all nonterminal parent trials; no retries'},f,indent=2)
def run(label):
    with (out/label/'stdout').open('xb') as stdout, (out/label/'stderr').open('xb') as stderr:
        r=subprocess.run(['ptc','run',str(out/f'{label}.ptc-project.json'),'--private-input',str(out/'inputs'/f'{label}.json'),'--env-file',str(a.env_file.resolve()),'--private-output',str(out/label/'result.private.json')],cwd=root,stdout=stdout,stderr=stderr)
    print(f'{label}: exit {r.returncode}',flush=True)
with ThreadPoolExecutor(max_workers=3) as pool:
    list(pool.map(run,labels))
