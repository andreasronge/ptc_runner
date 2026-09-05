#!/usr/bin/env python3
"""Prepare the recovery-to-diagnosis bridge; PTC transforms the capture."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import os
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'self-improvement'))
from support import ROOT,write_json
os.umask(0o077)
out=ROOT/'tmp/nav-recovery-story'
if out.exists():
    raise SystemExit('Use a fresh story directory.')
for name in ['app','inputs','baseline','recovery']:
    (out/name).mkdir(parents=True)
for arm in ['baseline','recovery']:
    transform='request' if arm=='baseline' else '(update request "system" replace "fails the program instead of returning a page" "returns navigation_error with page nil; the program continues")'
    expression='''(let [p (analysis/read "cmd-17033yrda5qey49sg31kvwm9mn" {"collection" "model_exchanges" "limit" 10})
        xs (get p "items") x (last xs) request (get x "arguments")]
      (if (and (= 6 (count xs)) (nil? (get p "next_cursor")) (every? #(get %% "complete?") xs))
        {"prefix" (mapv #(get-in %% ["result" "value" "tool_calls" 0 "args" "program"]) (take 5 xs))
         "request" %s "response" (get-in x ["result" "value"]) "remaining" 14}
        (fail "incomplete capture")))''' % transform
    subprocess.run(['ptc','repl','--project',str(ROOT/'tmp/nav-self-improvement/candidate-span.ptc-project.json'),'--profile','private-run-analysis-v2','--private-unattended','--preview-chars','64','--private-output',str(out/'inputs'/f'{arm}.json'),'-e',expression],cwd=ROOT,check=True)
manifest=json.loads((ROOT/'tmp/nav-decision-continuation/app/ptc.json').read_text())
manifest['workflow']={'components':[{'id':'resume','path':'resume.clj','dependencies':['agent.feedback','agent.native','kernel','llm']},{'library':'agent.feedback'},{'library':'agent.native'},{'library':'kernel'},{'library':'llm'}],'entry':'resume/run'}
write_json(out/'app/ptc.json',manifest)
shutil.copyfile(Path(__file__).with_name('resume.clj'),out/'app/resume.clj')
host=json.loads((ROOT/'tmp/nav-decision-continuation/host.json').read_text())
for provider,kind in [('debug.nav','inspection'),('failed-run-traces','traces')]:
    host['install'][provider]['directory']=str(ROOT/f'tmp/nav-self-improvement/incidents/span/.ptc/{kind}')
write_json(out/'host.json',host)
for arm in ['baseline','recovery']:
    write_json(out/f'{arm}.ptc-project.json',{'kind':'ptc-project','version':1,'application':{'path':'app/ptc.json'},'host':{'path':'host.json'},'artifacts':{'root':f'{arm}/.ptc','trace':True,'inspection':True,'result':True,'envelope':True}})
subprocess.run(['ptc','materialize',str(out/'recovery.ptc-project.json'),'--target-mission','evidence','--component','debug.nav','--source',str(ROOT/'tmp/nav-interface-testing/recovery.clj'),'--out',str(out/'override')],cwd=ROOT,check=True)
