"""Query generated canonical cohorts through the private analysis CLI, never raw records."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time

QUERY = """(loop [cursor nil runs 0 pages 0 max-page 0]
  (let [page (analysis/runs (if cursor {"limit" 50 "cursor" cursor} {"limit" 50}))
        n (count (get page "items")) next (get page "next_cursor")]
    (if next (recur next (+ runs n) (inc pages) (max max-page n))
      {"runs" (+ runs n) "pages" (inc pages) "max_page" (max max-page n)})))"""

parser = argparse.ArgumentParser()
parser.add_argument("--selected-run")
options = parser.parse_args()

for size in [1000, 1025] if options.selected_run else [1, 10, 100, 1000, 1025]:
    root = Path(f"tmp/profiling/followup/trace-cohorts/{size}").resolve()
    for sample in range(3):
        args = [
            "mix",
            "ptc",
            "repl",
            "--profile",
            "private-run-analysis-v2",
            "--private-unattended",
            "--resource",
            f"traces={root / 'traces'}",
            "--resource",
            f"inspection={root / 'inspection'}",
            "--format",
            "jsonl",
        ]
        if options.selected_run:
            args.extend(["--run", options.selected_run])
        for _ in range(3):
            args.extend(["-e", QUERY])
        if sys.platform == "darwin":
            args = ["/usr/bin/time", "-l"] + args
        started = time.perf_counter()
        process = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        opened_ms = None
        evaluations = []
        diagnostics = []
        rss = None
        for line in process.stdout:
            match = re.search(r"(\d+)\s+maximum resident set size", line)
            if match:
                rss = int(match[1])
            if not line.startswith("{"):
                continue
            value = json.loads(line)
            if value.get("type") == "session-started":
                opened_ms = (time.perf_counter() - started) * 1000
            elif value.get("type") == "evaluation":
                result = value["result"]
                assert result["status"] == "ok", result
                summary = result["value"]
                assert (
                    summary["runs"] == (1 if options.selected_run else size)
                    and summary["max_page"] <= 50
                ), summary
                evaluations.append(
                    {
                        "duration_ms": result["duration_ms"],
                        "summary": summary,
                        "continuation": result["usage"]["continuation"],
                    }
                )
            elif value.get("type") != "session-closed":
                diagnostics.append(value)
        code = process.wait()
        if code == 0:
            assert len(evaluations) == 3
        else:
            assert size == 1025, (size, code, diagnostics)
        print(
            json.dumps(
                {
                    "cohort_runs": size,
                    "selected_run": options.selected_run,
                    "sample": sample,
                    "exit_code": code,
                    "process_wall_ms": (time.perf_counter() - started) * 1000,
                    "session_open_ms": opened_ms,
                    "process_peak_rss_bytes": rss,
                    "evaluations": evaluations,
                    "diagnostics": diagnostics,
                }
            ),
            flush=True,
        )
