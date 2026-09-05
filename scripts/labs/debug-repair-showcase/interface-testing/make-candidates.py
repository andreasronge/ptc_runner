#!/usr/bin/env python3
"""Create single-change overrides from PTC-exported installed source."""
import json
import os
from pathlib import Path
import subprocess

os.umask(0o077)
root = Path(__file__).resolve().parents[4]
out = root / 'tmp/nav-interface-testing'
original = (out / 'original.clj').read_text()
doc = 'Read one native evidence page. Put collection and advertised filters directly in options; do not nest them under filters. Obtain identifiers from returned records, never from example constants. Example using a run-id already returned by runs: (let [item (first (get (debug.nav/read run-id {"collection" "generated_sources" "limit" 1}) "items"))] (when item (debug.nav/read run-id {"collection" "generated_sources" "evaluation_id" (get item "evaluation_id")}))).'
lines = original.splitlines(keepends=True)
indices = [i for i, line in enumerate(lines) if line.startswith('  "Read one native evidence page.')]
assert len(indices) == 1
lines[indices[0]] = '  ' + json.dumps(doc) + '\n'
(out / 'docs.clj').write_text(''.join(lines))
recovery = original.replace('cannot be followed and calling follow on it fails the program instead of returning a page.', 'cannot be followed. Calling follow on such a relationship returns navigation_error with page nil; choose a different complete relationship or explain the missing evidence. It does not abort the program or fetch substitute evidence.')
old = '(fail "cannot follow an unavailable or filterless relationship")'
new = '''{"relationship" relationship
         "page" nil
         "navigation_error"
         {"kind" "relationship_unavailable"
          "recoverable" true
          "message" "No evidence was read. Select another complete relationship with filters, or report the missing evidence."}}'''
assert recovery.count(old) == 1
(out / 'recovery.clj').write_text(recovery.replace(old, new))
for arm in ['docs', 'recovery']:
    subprocess.run(['ptc', 'materialize', str(out / 'control-sheet.ptc-project.json'), '--target-mission', 'evidence', '--component', 'debug.nav', '--source', str(out / f'{arm}.clj'), '--out', str(out / f'{arm}-override')], check=True)
