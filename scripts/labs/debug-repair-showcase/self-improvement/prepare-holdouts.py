#!/usr/bin/env python3
"""Prepare new deterministic incidents and a fixed, paired prompt comparison."""
import copy
import json
import os
from support import ROOT, OUT, write_json as write
import shutil

os.umask(0o077)



def component(name, body, description, signature, args, dependencies=()):
    text = f'(ns {name} {json.dumps(description)} {{:visibility :prompt}})\n\n'
    text += f'(defn run\n  {json.dumps(description)}\n  {{:signature {json.dumps(signature)}}}\n  [{args}]\n  {body})\n'
    return {'id': name, 'path': name + '.clj', **({'dependencies': list(dependencies)} if dependencies else {})}, text


cases = {}
span = OUT / 'incidents/span'
span.mkdir(parents=True, exist_ok=False)
components = []
for name, body, description, dependencies in [
    ('page.index', '(page.window/run request)', 'Build the page sequence for the requested half-open interval.', ['page.window']),
    ('page.window', '(vec (range (page.start/run request) (page.stop/run request)))', 'Enumerate pages using the supplied start and exclusive stop.', ['page.start', 'page.stop']),
    ('page.start', '(get request "first")', 'Return the first included page unchanged.', []),
    ('page.stop', '(inc (get request "end"))', 'Return the exclusive end page unchanged; the end page must not be included.', []),
    ('page.label', '(str "Page " (get request "first"))', 'Format a page label for display.', []),
]:
    declaration, source = component(name, body, description, '(request :map) -> :any', 'request', dependencies)
    components.append(declaration)
    (span / (name + '.clj')).write_text(source)
span_source = '''(ns main "Check the requested half-open page sequence." {:visibility :prompt})
(defn run "Build and check the page sequence." {:signature "(input :map) -> :map"} [input]
  (let [source (str "(let [actual (page.index/run " (pr-str (get input "request")) ")] (if (= actual " (pr-str (get input "expected")) ") (return {\\\"pages\\\" actual}) (fail {\\\"kind\\\" \\\"page-sequence-mismatch\\\" \\\"actual\\\" actual})))")
        result (kernel/eval-source "pages" source)]
    (if (= :returned (get result :outcome)) (return (get result :value)) (fail {:kind "page-sequence-mismatch"}))))
'''
(span / 'main.clj').write_text(span_source)
cases['span'] = {'missions': {'pages': {'components': components}}, 'input': {'request': {'first': 3, 'end': 6}, 'expected': [3, 4, 5]}}

queue = OUT / 'incidents/queue'
queue.mkdir(parents=True, exist_ok=False)
for name, description, body in [
    ('queue.rank', 'Order requests by increasing deadline, earliest first.', '(vec (sort-by #(get % "deadline") requests))'),
    ('queue.emit', 'Emit request IDs in exactly the order received; do not reorder.', '(mapv #(get % "id") requests)'),
]:
    declaration, source = component(name, body, description, '(requests :any) -> :any', 'requests')
    (queue / (name + '.clj')).write_text(source)
(queue / 'main.clj').write_text('''(ns main "Rank requests by earliest deadline and preserve that order in the emitted batch." {:visibility :prompt})
(defn run "Emit the ranked sequence without reordering it." {:signature "(input :map) -> :map"} [input]
  (let [ranking (kernel/eval-source "ranking" (str "(return (queue.rank/run " (pr-str (get input "requests")) "))"))
        ranked (get ranking :value)
        emission (kernel/eval-source "emission" (str "(return (queue.emit/run " (pr-str (vec (reverse ranked))) "))"))
        actual (get emission :value)]
    (if (= actual (get input "expected")) (return {"batch" actual}) (fail {"kind" "batch-order-mismatch" "actual" actual}))))
''')
cases['queue'] = {'missions': {mission: {'components': [{'id': name, 'path': name + '.clj'}]} for mission, name in [('ranking', 'queue.rank'), ('emission', 'queue.emit')]}, 'input': {'requests': [{'id': 'last', 'deadline': 30}, {'id': 'urgent', 'deadline': 4}, {'id': 'later', 'deadline': 12}], 'expected': ['urgent', 'later', 'last']}}

textcase = OUT / 'incidents/text'
textcase.mkdir(parents=True, exist_ok=False)
components = []
for name, body, description, dependencies in [
    ('text.canonical', '(case.fold/run (space.fold/run text))', 'Produce the canonical representation of supplied text.', ['case.fold', 'space.fold']),
    ('case.fold', '(lower-case text)', 'Apply canonical casing to supplied text.', []),
    ('space.fold', '(trim text)', 'Apply canonical spacing to supplied text.', []),
    ('text.width', '(count text)', 'Measure text width.', []),
]:
    declaration, source = component(name, body, description, '(text :string) -> :any', 'text', dependencies)
    components.append(declaration)
    (textcase / (name + '.clj')).write_text(source)
(textcase / 'main.clj').write_text('''(ns main "Compare canonical text with the caller's expected representation." {:visibility :prompt})
(defn run "Check the caller's required canonical text." {:signature "(input :map) -> :map"} [input]
  (let [source (str "(let [actual (text.canonical/run " (pr-str (get input "text")) ")] (if (= actual " (pr-str (get input "expected")) ") (return {\\\"text\\\" actual}) (fail {\\\"kind\\\" \\\"canonical-text-mismatch\\\" \\\"actual\\\" actual})))")
        result (kernel/eval-source "canonical" source)]
    (if (= :returned (get result :outcome)) (return (get result :value)) (fail {:kind "canonical-text-mismatch"}))))
''')
cases['text'] = {'missions': {'canonical': {'components': components}}, 'input': {'text': '  ALPHA BETA  ', 'expected': 'Alpha Beta'}}

for name, case in cases.items():
    manifest = {'version': 1, 'workflow': {'components': [{'id': 'main', 'path': 'main.clj', 'dependencies': ['kernel']}, {'library': 'kernel'}], 'entry': 'main/run'}, 'missions': case['missions'], 'input': {'value': case['input']}, 'events': {'policy': 'private'}, 'labels': {'name': 'holdout-' + name}}
    write(OUT / f'incidents/{name}/ptc.json', manifest)
    write(OUT / f'{name}.ptc-project.json', {'kind': 'ptc-project', 'version': 1, 'application': {'path': f'incidents/{name}/ptc.json'}, 'artifacts': {'root': f'incidents/{name}/.ptc', 'trace': True, 'inspection': True, 'result': True, 'envelope': True}})

base = json.loads((ROOT / 'examples/debug-a-failed-run/debugger-agent/ptc.json').read_text())
base['limits']['llm_request_output_tokens'] = 4096
for name in cases:
    for arm in ['control', 'candidate']:
        cell = f'{arm}-{name}'
        directory = OUT / cell
        directory.mkdir()
        write(directory / 'ptc.json', base)
        shutil.copyfile(ROOT / 'examples/debug-a-failed-run/debugger-agent/report.schema.json', directory / 'report.schema.json')
        host = json.loads((ROOT / 'examples/debug-a-failed-run/ptc-host.json').read_text())
        host['install']['failed-run-traces']['directory'] = f'incidents/{name}/.ptc/traces'
        host['install']['debug.nav']['directory'] = f'incidents/{name}/.ptc/inspection'
        write(OUT / f'{cell}.host.json', host)
        write(OUT / f'{cell}.ptc-project.json', {'kind': 'ptc-project', 'version': 1, 'application': {'path': f'{cell}/ptc.json'}, 'host': {'path': f'{cell}.host.json'}, 'artifacts': {'root': f'{cell}/.ptc', 'trace': True, 'inspection': True, 'result': True, 'envelope': True}})
write(OUT / 'oracle.json', {'span': {'decision': 'diagnosed', 'component_id': 'page.stop'}, 'queue': {'decision': 'diagnosed', 'component_id': 'main'}, 'text': {'decision': 'insufficient-evidence'}})
print('Prepared three incidents and six comparison cells. Oracle is outside agent authority.')
