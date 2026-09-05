#!/usr/bin/env python3
"""Prepare one-call experiments; PTC alone reads and transforms captured requests."""
import json
from pathlib import Path
import shutil
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'self-improvement'))
from support import ROOT, write_json
out = ROOT / 'tmp/nav-decision-replay'
source = Path(__file__).resolve().parent
if (out / 'plan.json').exists():
    raise SystemExit('Existing comparison is immutable; use a fresh experiment directory.')
for cell in ['recovery-terse', 'recovery-actionable', 'ambiguity-control', 'ambiguity-reminder']:
    directory = out / cell
    directory.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / 'main.clj', directory / 'main.clj')
    write_json(directory / 'ptc.json', {
        'version': 1,
        'workflow': {'components': [{'id':'main','path':'main.clj','dependencies':['llm']},{'library':'llm'}], 'entry':'main/run'},
        'providers': {'workflow':[{'name':'deepseek'}]},
        'events': {'policy':'private'},
        'limits': {'run_duration_ms':600000,'workflow_timeout_ms':540000,'evaluation_timeout_ms':480000,'llm_request_output_tokens':4096},
        'input': {'value': {}},
    })
    host=json.loads((ROOT / 'examples/debug-a-failed-run/ptc-host.json').read_text())
    host['install']={'deepseek':host['install']['deepseek']}
    write_json(out / f'{cell}.host.json', host)
    write_json(out / f'{cell}.ptc-project.json', {
        'kind':'ptc-project','version':1,'application':{'path':f'{cell}/ptc.json'},
        'host':{'path':f'{cell}.host.json'},
        'artifacts':{'root':f'{cell}/.ptc','trace':True,'inspection':True,'result':True,'envelope':True}})
