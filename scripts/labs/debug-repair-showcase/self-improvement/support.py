"""Shared paths and static-configuration writing for the dated experiment."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
OUT = ROOT / 'tmp/nav-self-improvement'


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')
