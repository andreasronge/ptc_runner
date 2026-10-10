#!/usr/bin/env python3
"""Merge reviewed discovery output into a gateway document."""
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
pins = json.load(sys.stdin)
config = json.loads(path.read_text())
assert set(pins) == {tool["name"] for tool in config["tools"]}
for tool in config["tools"]:
    tool.update(pins[tool["name"]])
path.write_text(json.dumps(config, indent=2) + "\n")
