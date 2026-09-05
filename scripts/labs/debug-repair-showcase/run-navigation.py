#!/usr/bin/env python3
"""Run navigation comparisons; analyze captures through ptc repl, never here."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess

VARIANTS = {
    "deepseek-2k-view": ("deepseek/deepseek-v4-flash", 2048, None),
    "deepseek-8k": ("deepseek/deepseek-v4-flash", 8192, None),
    "deepseek-8k-consolidate": ("deepseek/deepseek-v4-flash", 8192, 6),
    "gemini-8k-consolidate": ("google/gemini-3.8-flash", 8192, 6),
}
TARGETS = {"component": "", "ambiguous": "-ambiguous", "workflow": "-workflow-control"}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("example", type=Path, help="example with all three failed captures")
    parser.add_argument("out", type=Path, help="new experiment directory")
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=3, choices=range(1, 11))
    parser.add_argument("--jobs", type=int, default=6, choices=range(1, 7))
    parser.add_argument("--variant", action="append", choices=VARIANTS)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    example, out, env = args.example.resolve(), args.out.resolve(), args.env_file.resolve()
    if not env.is_file():
        parser.error("the environment file must exist")
    for suffix in TARGETS.values():
        for resource in ["traces", "inspection"]:
            if not (example / f"target{suffix}/.ptc/{resource}").is_dir():
                parser.error(f"capture target{suffix} before starting")
    out.mkdir(parents=True, exist_ok=False)
    # Freeze the same evidence for every cell. Copy bytes without interpreting them.
    for suffix in TARGETS.values():
        shutil.copytree(example / f"target{suffix}/.ptc", out / f"target{suffix}/.ptc")
    base = json.loads((example / "debugger-agent/ptc.json").read_text())
    schema = example / "debugger-agent/report.schema.json"
    cells = []
    for variant in args.variant or VARIANTS:
        model, observation, consolidation = VARIANTS[variant]
        for target, suffix in TARGETS.items():
            name = f"{variant}-{target}"
            cell = out / name
            cell.mkdir()
            manifest = copy.deepcopy(base)
            config = manifest["input"]["value"]["agent"]
            config["max_observation_chars"] = observation
            config.pop("consolidate_at_turns_remaining", None)
            if consolidation is not None:
                config["consolidate_at_turns_remaining"] = consolidation
            manifest["limits"]["normal_event_count"] = 1024
            manifest["limits"]["llm_request_output_tokens"] = 4096
            if variant.endswith("-view"):
                shutil.copyfile(Path(__file__).with_name("debug.view.clj"), cell / "debug.view.clj")
                manifest["missions"]["evidence"]["components"].append({
                    "id": "debug.view", "path": "debug.view.clj", "dependencies": ["debug.nav"]
                })
                manifest["input"]["value"]["task"] += (
                    "\nUse debug.view/read and debug.view/follow for readable evidence pages. "
                    "They retain exact sources, hashes, relationships, and page completeness. "
                    "Use debug.nav/read only if you need the omitted item bookkeeping."
                )
            write_json(cell / "ptc.json", manifest)
            shutil.copyfile(schema, cell / "report.schema.json")
            host = json.loads((example / f"ptc-host{suffix}.json").read_text())
            host["install"]["deepseek"]["model"] = "openrouter:" + model
            host["install"]["deepseek"]["installation_revision"] = variant + "-v1"
            write_json(out / f"{name}.host.json", host)
            project = {
                "kind": "ptc-project", "version": 1,
                "application": {"path": f"{name}/ptc.json"},
                "host": {"path": f"{name}.host.json"},
                "artifacts": {"root": f"{name}/.ptc", "trace": True,
                              "inspection": True, "result": True, "envelope": True},
            }
            project_path = out / f"{name}.ptc-project.json"
            write_json(project_path, project)
            cells.append((name, project_path, cell))
    write_json(out / "experiment.json", {
        "runtime": subprocess.check_output(["ptc", "--version"], text=True).strip(),
        "samples": args.samples,
        "cells": [name for name, _, _ in cells],
        "note": "Alias deepseek is held constant across models; inspect resolved model with ptc models.",
    })
    if args.prepare_only:
        print(out)
        return

    def run_cell(entry):
        name, project, cell = entry
        validation = subprocess.run(["ptc", "validate", str(project)], capture_output=True)
        (cell / "validation.stdout").write_bytes(validation.stdout)
        (cell / "validation.stderr").write_bytes(validation.stderr)
        if validation.returncode:
            print(f"{name}: validation exit {validation.returncode}", flush=True)
            return
        for sample in range(1, args.samples + 1):
            with (cell / f"sample-{sample}.stdout").open("wb") as stdout, \
                 (cell / f"sample-{sample}.stderr").open("wb") as stderr:
                result = subprocess.run([
                    "ptc", "run", str(project), "--env-file", str(env), "--progress",
                    "--private-output", str(cell / f"sample-{sample}.private.json"),
                ], stdout=stdout, stderr=stderr)
            print(f"{name} sample {sample}: exit {result.returncode}", flush=True)

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(run_cell, cells))


if __name__ == "__main__":
    main()
