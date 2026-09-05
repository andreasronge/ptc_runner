#!/usr/bin/env python3
"""Prepare a bounded continuation; PTC exports all captured data."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import os
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'self-improvement'))
from support import ROOT,write_json
os.umask(0o077)
out=ROOT/'tmp/nav-decision-continuation'
if out.exists():
    raise SystemExit('Use a fresh experiment directory.')
for name in ['traces','inspection','inputs','app']:
    (out/name).mkdir(parents=True)
original='cmd-62ttx8bbg3dwsvkw6g6jnx6c1p'
trials={
 'control-inspect':'cmd-25ca6ffhcbnfqvtdr6jz2kraqe',
 'control-diagnose':'cmd-3tzxsj952b487yxrpfmdsjfe9a',
 'control-incomplete':'cmd-1svct5cg6e1c6x751fsy28a8hx',
 'reminder-metadata':'cmd-7fgyyrcgrg0rppd2n7ande0xvs',
 'reminder-inspect-1':'cmd-23x03gp2wd4pggjhfxgw27js51',
 'reminder-inspect-2':'cmd-4nhej599s8a1wkxfb06hbhpn98',
}
for label,id in [('original',original),*trials.items()]:
    path=ROOT/'tmp/nav-interface-testing/control-record/.ptc' if label=='original' else ROOT/('tmp/nav-decision-replay/ambiguity-'+('control' if label.startswith('control') else 'reminder')+'/.ptc')
    for kind,ext in [('traces','.private.jsonl'),('inspection','.ptcins')]:
        shutil.copyfile(path/kind/(id+ext),out/kind/(id+ext))
write_json(out/'trials.json',trials)
for label,id in trials.items():
    expression='''(let [p (analysis/read "%s" {"collection" "model_exchanges" "limit" 30})
          original-xs (get p "items")
          trial-xs (get (analysis/read "%s" {"collection" "model_exchanges" "limit" 2}) "items")
          x (first trial-xs)]
      (if (and (= 19 (count original-xs)) (nil? (get p "next_cursor"))
               (= 1 (count trial-xs)) (every? #(get %% "complete?") original-xs) (get x "complete?"))
        {"parent_trial" "%s"
         "prefix" (mapv #(get-in %% ["result" "value" "tool_calls" 0 "args" "program"]) (take 18 original-xs))
         "request" (get x "arguments") "response" (get-in x ["result" "value"])}
        (fail "incomplete replay input")))''' % (original,id,id)
    subprocess.run(['ptc','repl','--profile','private-run-analysis-v2','--resource',f'traces={out}/traces','--resource',f'inspection={out}/inspection','--private-unattended','--preview-chars','64','--private-output',str(out/'inputs'/f'{label}.json'),'-e',expression],cwd=ROOT,check=True)
manifest=json.loads((ROOT/'tmp/nav-decision-replay/check/ptc.json').read_text())
manifest['workflow']['components']=[{'id':'main','path':'main.clj','dependencies':['agent.feedback','kernel','llm']},{'library':'agent.feedback'},{'library':'kernel'},{'library':'llm'}]
manifest['providers']['workflow']=[{'name':'deepseek'}]
manifest['limits']={'normal_event_count':1024,'run_duration_ms':600000,'workflow_timeout_ms':540000,'evaluation_timeout_ms':480000,'llm_request_output_tokens':4096}
write_json(out/'app/ptc.json',manifest)
shutil.copyfile(Path(__file__).with_name('main.clj'),out/'app/main.clj')
host=json.loads((ROOT/'tmp/nav-decision-replay/check.host.json').read_text())
host['credentials']={'openrouter_key':{'env':'OPENROUTER_API_KEY'}}
host['install']['deepseek']=json.loads((ROOT/'tmp/nav-decision-replay/ambiguity-control.host.json').read_text())['install']['deepseek']
write_json(out/'host.json',host)
for label in trials:
    (out/label).mkdir()
    write_json(out/f'{label}.ptc-project.json',{'kind':'ptc-project','version':1,'application':{'path':'app/ptc.json'},'host':{'path':'host.json'},'artifacts':{'root':f'{label}/.ptc','trace':True,'inspection':True,'result':True,'envelope':True}})
