#!/usr/bin/env python3
"""Prepare a model to inspect one failed investigator and propose a component edit."""
from pathlib import Path
import json
import shutil
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'self-improvement'))
from support import ROOT,write_json
out=ROOT/'tmp/nav-recovery-story'
for name in ['improver','training/traces','training/inspection']:
    (out/name).mkdir(parents=True,exist_ok=True)
id='cmd-17033yrda5qey49sg31kvwm9mn'
for kind,ext in [('traces','.private.jsonl'),('inspection','.ptcins')]:
    shutil.copyfile(ROOT/'tmp/nav-self-improvement/candidate-span/.ptc'/kind/(id+ext),out/'training'/kind/(id+ext))
manifest=json.loads((ROOT/'examples/debug-a-failed-run/debugger-agent/ptc.json').read_text())
manifest['input']['value']={
 'task': '''The captured run is a debugging agent that stopped before completing its investigation. Improve the investigator's reusable evidence-navigation component, not the application it was investigating.
Navigate the captured run, inspect the execution failure and relevant generated programs, and read the frozen source of debug.nav used by that agent. Propose the smallest complete replacement for that component that addresses the observed failure while preserving its component identity, existing exports, dependencies, successful evidence pages, and authority boundaries. Do not invent evidence, change query filters to find a preferred answer, hide failures as successful evidence, or add incident-specific rules. Keep invalid options distinguishable from unavailable evidence. If the evidence does not justify a reusable component change, abstain.
Return decision (propose or abstain), rationale, evidence (an array of strings citing the inspected records), and only for propose: component_id and candidate_source (the complete replacement source). Your proposal will be compiled and tested separately before any adoption. You cannot modify installed code.''',
 'agent':{'max_turns':12,'max_observation_chars':8192,'mission':'evidence'}}
manifest['limits']['llm_request_output_tokens']=8192
write_json(out/'improver/ptc.json',manifest)
write_json(out/'improver/report.schema.json',{'type':'object','required':['decision','rationale','evidence'],'properties':{'decision':{'type':'string','enum':['propose','abstain']},'rationale':{'type':'string'},'evidence':{'type':'array','items':{'type':'string'}},'component_id':{'type':'string'},'candidate_source':{'type':'string'}},'additionalProperties':False})
host=json.loads((out/'host.json').read_text())
for provider,kind in [('debug.nav','inspection'),('failed-run-traces','traces')]:
    host['install'][provider]['directory']=str(out/'training'/kind)
host['install']['deepseek']['model']='openrouter:google/gemini-3.8-flash'
host['install']['deepseek']['params']['max_tokens']=8192
write_json(out/'improver.host.json',host)
write_json(out/'improver.ptc-project.json',{'kind':'ptc-project','version':1,'application':{'path':'improver/ptc.json'},'host':{'path':'improver.host.json'},'artifacts':{'root':'improver/.ptc','trace':True,'inspection':True,'result':True,'envelope':True}})
