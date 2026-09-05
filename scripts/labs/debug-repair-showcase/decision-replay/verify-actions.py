#!/usr/bin/env python3
"""Export recovery actions with PTC and execute them on the frozen incident."""
from pathlib import Path
import json
import argparse
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'self-improvement'))
from support import ROOT,write_json
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--case',choices=['recovery','ambiguity'],default='recovery')
case=parser.parse_args().case
cells=['recovery-terse','recovery-actionable'] if case=='recovery' else ['ambiguity-control','ambiguity-reminder']
out=ROOT/'tmp/nav-decision-replay'
for cell in cells:
    expression='''(let [rs (get (analysis/runs {"limit" 10}) "items")]
      (if (not= 3 (count rs)) (fail "expected three samples")
        {"samples" (mapv (fn [r] {"run_id" (get r "run_id") "program" (get-in (analysis/open (get r "run_id")) ["result" "value" "tool_calls" 0 "args" "program"])}) rs)}))'''
    subprocess.run(['ptc','repl','--project',str(out/f'{cell}.ptc-project.json'),'--profile','private-run-analysis-v2','--private-unattended','--preview-chars','64','--private-output',str(out/'inputs'/f'{cell}-actions.json'),'-e',expression],cwd=ROOT,check=True)
verify='verify' if case=='recovery' else 'check'
(out/verify).mkdir(exist_ok=True)
source='''(ns main "Execute next actions on the frozen read-only evidence." {:visibility :prompt})
(defn run "Retain execution outcomes for each proposed action." [input]
  (return (mapv (fn [sample] {"run_id" (get sample "run_id") "evaluation" (kernel/eval-source "evidence" (get sample "program"))}) (get input "samples"))))
'''
if case=='ambiguity':
    source=source.replace('kernel/eval-source','kernel/check-source')
(out/verify/'main.clj').write_text(source)
manifest=json.loads((ROOT/'tmp/nav-interface-testing/probe/ptc.json').read_text())
manifest['input']={'value':{}}
write_json(out/verify/'ptc.json',manifest)
host=json.loads((ROOT/'tmp/nav-self-improvement/candidate-span.host.json').read_text())
host['install'].pop('deepseek')
for provider,kind in [('debug.nav','inspection'),('failed-run-traces','traces')]:
    incident='tmp/nav-self-improvement/incidents/span' if case=='recovery' else 'tmp/nav-interface-testing/incidents/record'
    host['install'][provider]['directory']=str(ROOT/f'{incident}/.ptc/{kind}')
write_json(out/f'{verify}.host.json',host)
for cell in cells:
    (out/f'verify-{cell}').mkdir(exist_ok=True)
    write_json(out/f'verify-{cell}.ptc-project.json',{'kind':'ptc-project','version':1,'application':{'path':f'{verify}/ptc.json'},'host':{'path':f'{verify}.host.json'},'artifacts':{'root':f'verify-{cell}/.ptc','trace':True,'inspection':True,'result':True,'envelope':True}})
    subprocess.run(['ptc','run',str(out/f'verify-{cell}.ptc-project.json'),'--private-input',str(out/'inputs'/f'{cell}-actions.json'),'--private-output',str(out/f'verify-{cell}/result.private.json')],cwd=ROOT,check=True)
