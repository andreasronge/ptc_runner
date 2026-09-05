#!/usr/bin/env python3
"""Prepare a coach with only one failed navigation capture; never parse logs."""
import copy
import json
import os
from support import ROOT, OUT, write_json as write
import shutil

os.umask(0o077)

TRAIN_ID = 'cmd-3c1q7epwzdvf0y7m3nf98xfhm5'
CAPTURE = ROOT / 'tmp/repair-showcase/debug-final-workflow-control/.ptc'


if OUT.exists():
    raise SystemExit('Use a fresh tmp/nav-self-improvement directory; existing experiments are immutable.')

for directory in ['coach', 'training/traces', 'training/inspection', 'frozen']:
    (OUT / directory).mkdir(parents=True, exist_ok=True)
for kind, extension in [('traces', '.private.jsonl'), ('inspection', '.ptcins')]:
    shutil.copyfile(CAPTURE / kind / (TRAIN_ID + extension), OUT / 'training' / kind / (TRAIN_ID + extension))
base = json.loads((ROOT / 'examples/debug-a-failed-run/debugger-agent/ptc.json').read_text())
manifest = copy.deepcopy(base)
manifest['input']['value'] = {
    'task': '''Investigate why the captured navigation agent failed to finish. This is an investigation of the agent's execution strategy, not of the application it was debugging.
List and open the captured run. Read its turns in bounded pages, including generated programs and feedback. Inspect the original request instructions and relevant frozen agent source if needed. Cite exact turn numbers and observed consequences. Distinguish execution mistakes from capability limitations and do not claim missing features without evidence.
Propose ONE short, domain-blind instruction addendum that can be appended to the existing debugging task. It must improve how an agent uses PTC-Lisp and evidence navigation across unrelated applications. Do not include incident values, application component names, diagnoses, expected answers, test domains, or a solution to the captured application. Do not change the tools, result contract, budget, model, or existing instructions. The addendum must be at most 1800 characters. You will not see the evaluation incidents. No retries or competing candidates will be selected based on their evaluation performance.
Return exactly instruction_addendum (string), findings (array of objects with turns: array of integers, problem: string, evidence: string), and rationale (string). Finish once you have enough evidence for a bounded useful change.''',
    'agent': {'max_turns': 16, 'max_observation_chars': 16000, 'mission': 'evidence', 'consolidate_at_turns_remaining': 4}
}
manifest['limits']['llm_request_output_tokens'] = 4096
manifest['labels']['name'] = 'navigation-coach'
write(OUT / 'coach/ptc.json', manifest)
write(OUT / 'coach/report.schema.json', {
    'type': 'object', 'additionalProperties': False,
    'required': ['instruction_addendum', 'findings', 'rationale'],
    'properties': {
        'instruction_addendum': {'type': 'string', 'minLength': 1, 'maxLength': 1800},
        'rationale': {'type': 'string'},
        'findings': {'type': 'array', 'minItems': 1, 'items': {
            'type': 'object', 'additionalProperties': False,
            'required': ['turns', 'problem', 'evidence'],
            'properties': {'turns': {'type': 'array', 'items': {'type': 'integer'}}, 'problem': {'type': 'string'}, 'evidence': {'type': 'string'}}}}
    }
})
host = json.loads((ROOT / 'examples/debug-a-failed-run/ptc-host.json').read_text())
host['install']['failed-run-traces']['directory'] = 'training/traces'
host['install']['debug.nav']['directory'] = 'training/inspection'
host['install']['deepseek']['model'] = 'openrouter:google/gemini-3.8-flash'
host['install']['deepseek']['installation_revision'] = 'navigation-coach-v1'
write(OUT / 'coach.host.json', host)
write(OUT / 'coach.ptc-project.json', {
    'kind': 'ptc-project', 'version': 1, 'application': {'path': 'coach/ptc.json'},
    'host': {'path': 'coach.host.json'},
    'artifacts': {'root': 'coach/.ptc', 'trace': True, 'inspection': True, 'result': True, 'envelope': True}
})
# Export the coach's exact addendum into a ready-to-run input using PTC later.
original = base['input']['value']['task']
expression = '(let [run-id (get (first (get (analysis/runs {"limit" 1}) "items")) "run_id") candidate (get-in (analysis/open run-id) ["result" "value" "instruction_addendum"])] (if (string? candidate) {"task" (str ' + json.dumps(original) + ' "\\n\\n" candidate) "agent" {"max_turns" 20 "max_observation_chars" 2048 "mission" "evidence"}} (fail "coach has no candidate")))\n'
(OUT / 'export-candidate.clj').write_text(expression)
write(OUT / 'frozen/control.input.json', {'task': original, 'agent': {'max_turns': 20, 'max_observation_chars': 2048, 'mission': 'evidence'}})
print(OUT)
