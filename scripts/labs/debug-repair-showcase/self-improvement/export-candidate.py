#!/usr/bin/env python3
"""Let PTC export the coach's exact candidate into an agent input artifact."""
from support import OUT as root
import subprocess

subprocess.run([
    'ptc', 'repl', '--project', str(root / 'coach.ptc-project.json'),
    '--profile', 'private-run-analysis-v2', '--private-unattended',
    '--preview-chars', '1000', '--private-output', str(root / 'frozen/candidate.input.json'),
    '-e', (root / 'export-candidate.clj').read_text(),
], check=True)
