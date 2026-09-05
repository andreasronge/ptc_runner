#!/usr/bin/env python3
"""Prepare fresh incidents and isolated documentation/recovery override trials."""
import json
import os
from pathlib import Path
import shutil
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'self-improvement'))
from support import ROOT, write_json

os.umask(0o077)
OUT = ROOT / 'tmp/nav-interface-testing'
if (OUT / 'incidents').exists():
    raise SystemExit('Use a fresh experiment directory; do not overwrite captures.')
OUT.mkdir(exist_ok=True)


def fixture(name, sources, missions, data):
    directory = OUT / 'incidents' / name
    directory.mkdir(parents=True)
    for component, source in sources.items():
        (directory / (component + '.clj')).write_text(source)
    manifest = {'version': 1, 'workflow': {'components': [{'id': 'main', 'path': 'main.clj', 'dependencies': ['kernel']}, {'library': 'kernel'}], 'entry': 'main/run'}, 'missions': missions, 'input': {'value': data}, 'events': {'policy': 'private'}, 'labels': {'name': 'interface-holdout-' + name}}
    write_json(directory / 'ptc.json', manifest)
    write_json(OUT / f'{name}.ptc-project.json', {'kind': 'ptc-project', 'version': 1, 'application': {'path': f'incidents/{name}/ptc.json'}, 'artifacts': {'root': f'incidents/{name}/.ptc', 'trace': True, 'inspection': True, 'result': True, 'envelope': True}})


fixture('sheet', {
'main': '''(ns main "Check the area required by a sheet request." {:visibility :prompt})
(defn run "Evaluate the requested sheet area." {:signature "(input :map) -> :map"} [input]
  (let [source (str "(let [actual (sheet.plan/run " (pr-str (get input "request")) ")] (if (= actual " (pr-str (get input "expected")) ") (return {\\\"area\\\" actual}) (fail {\\\"kind\\\" \\\"sheet-area-mismatch\\\" \\\"actual\\\" actual})))")
        outcome (kernel/eval-source "sheet" source)]
    (if (= :returned (get outcome :outcome)) (return (get outcome :value)) (fail {:kind "sheet-area-mismatch"}))))
''',
'sheet.plan': '''(ns sheet.plan "Plan required sheet area." {:visibility :prompt})
(defn run "Return the required area including allowance." {:signature "(request :map) -> :float"} [request] (sheet.surface/run request))
''',
'sheet.surface': '''(ns sheet.surface "Combine rectangle area and cutting allowance." {:visibility :prompt})
(defn run "Add the rectangle area to the cutting allowance." {:signature "(request :map) -> :float"} [request] (+ (sheet.area/run request) (sheet.allowance/run request)))
''',
'sheet.area': '''(ns sheet.area "Rectangle area." {:visibility :prompt})
(defn run "Multiply width by height to obtain the rectangle area." {:signature "(request :map) -> :float"} [request] (+ (get request "width") (get request "height")))
''',
'sheet.allowance': '''(ns sheet.allowance "Cutting allowance." {:visibility :prompt})
(defn run "Return the requested extra area unchanged." {:signature "(request :map) -> :float"} [request] (get request "allowance"))
''',
'sheet.label': '''(ns sheet.label "A display label." {:visibility :prompt})
(defn run "Format width for display." {:signature "(request :map) -> :string"} [request] (str (get request "width")))
''',
}, {'sheet': {'components': [
    {'id': 'sheet.plan', 'path': 'sheet.plan.clj', 'dependencies': ['sheet.surface']},
    {'id': 'sheet.surface', 'path': 'sheet.surface.clj', 'dependencies': ['sheet.allowance', 'sheet.area']},
    {'id': 'sheet.area', 'path': 'sheet.area.clj'}, {'id': 'sheet.allowance', 'path': 'sheet.allowance.clj'}, {'id': 'sheet.label', 'path': 'sheet.label.clj'}]}},
{'request': {'width': 4, 'height': 7, 'allowance': 3}, 'expected': 31})

fixture('meter', {
'main': '''(ns main "Calibrate raw measurements exactly once, then average the corrected values." {:visibility :prompt})
(defn run "Remove the calibration offset once before computing the mean." {:signature "(input :map) -> :map"} [input]
  (let [offset (get input "offset")
        calibration (kernel/eval-source "calibration" (str "(return (meter.calibrate/run " (pr-str (get input "readings")) " " (pr-str offset) "))"))
        corrected (get calibration :value)
        summary (kernel/eval-source "summary" (str "(return (meter.mean/run " (pr-str (mapv #(- % offset) corrected)) "))"))
        actual (get summary :value)]
    (if (= actual (get input "expected")) (return {"mean" actual}) (fail {"kind" "calibrated-mean-mismatch" "actual" actual}))))
''',
'meter.calibrate': '''(ns meter.calibrate "Apply calibration to raw measurements." {:visibility :prompt})
(defn run "Subtract offset exactly once from each supplied reading." {:signature "(readings :any, offset :float) -> :any"} [readings offset] (mapv #(- % offset) readings))
''',
'meter.mean': '''(ns meter.mean "Mean of already corrected values." {:visibility :prompt})
(defn run "Return the arithmetic mean of the supplied nonempty sequence without further calibration." {:signature "(readings :any) -> :float"} [readings] (/ (reduce + readings) (count readings)))
''',
}, {'calibration': {'components': [{'id': 'meter.calibrate', 'path': 'meter.calibrate.clj'}]}, 'summary': {'components': [{'id': 'meter.mean', 'path': 'meter.mean.clj'}]}},
{'readings': [15, 20], 'offset': 5, 'expected': 12.5})

fixture('record', {
'main': '''(ns main "Compare combined metadata with the caller's expected label." {:visibility :prompt})
(defn run "Check the caller's requested combined label." {:signature "(input :map) -> :map"} [input]
  (let [source (str "(let [actual (record.combine/run)] (if (= (get actual \\\"label\\\") " (pr-str (get input "expected")) ") (return actual) (fail {\\\"kind\\\" \\\"metadata-label-mismatch\\\" \\\"actual\\\" actual})))")
        outcome (kernel/eval-source "metadata" source)]
    (if (= :returned (get outcome :outcome)) (return (get outcome :value)) (fail {:kind "metadata-label-mismatch"}))))
''',
'record.combine': '''(ns record.combine "Combine proposed metadata." {:visibility :prompt})
(defn run "Combine metadata supplied by the two sources." {:signature "() -> :map"} [] (merge (record.left/run) (record.right/run)))
''',
'record.left': '''(ns record.left "One metadata source." {:visibility :prompt})
(defn run "Provide a proposed label." {:signature "() -> :map"} [] {"label" "blue"})
''',
'record.right': '''(ns record.right "Another metadata source." {:visibility :prompt})
(defn run "Provide a proposed label." {:signature "() -> :map"} [] {"label" "green"})
''',
}, {'metadata': {'components': [{'id': 'record.combine', 'path': 'record.combine.clj', 'dependencies': ['record.left', 'record.right']}, {'id': 'record.left', 'path': 'record.left.clj'}, {'id': 'record.right', 'path': 'record.right.clj'}]}}, {'expected': 'blue'})

base = json.loads((ROOT / 'examples/debug-a-failed-run/debugger-agent/ptc.json').read_text())
base['input']['value']['agent']['max_observation_chars'] = 2048
base['limits']['llm_request_output_tokens'] = 4096
base['labels']['name'] = 'navigation-interface-trial'
for arm in ['control', 'docs', 'recovery']:
    for case in ['sheet', 'meter', 'record']:
        name = f'{arm}-{case}'
        cell = OUT / name
        cell.mkdir()
        write_json(cell / 'ptc.json', base)
        shutil.copyfile(ROOT / 'examples/debug-a-failed-run/debugger-agent/report.schema.json', cell / 'report.schema.json')
        host = json.loads((ROOT / 'examples/debug-a-failed-run/ptc-host.json').read_text())
        host['install']['failed-run-traces']['directory'] = f'incidents/{case}/.ptc/traces'
        host['install']['debug.nav']['directory'] = f'incidents/{case}/.ptc/inspection'
        write_json(OUT / f'{name}.host.json', host)
        write_json(OUT / f'{name}.ptc-project.json', {'kind': 'ptc-project', 'version': 1, 'application': {'path': f'{name}/ptc.json'}, 'host': {'path': f'{name}.host.json'}, 'artifacts': {'root': f'{name}/.ptc', 'trace': True, 'inspection': True, 'result': True, 'envelope': True}})
write_json(OUT / 'oracle.json', {'sheet': {'decision': 'diagnosed', 'component_id': 'sheet.area'}, 'meter': {'decision': 'diagnosed', 'component_id': 'main'}, 'record': {'decision': 'insufficient-evidence'}})
print(OUT)
