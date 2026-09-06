"""Direct MCP traversal; run from the repository root with Python 3 and npx."""

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-page", type=Path)
    options = parser.parse_args()
    root = Path("examples/dabstep-fraud").resolve()
    env = os.environ.copy()
    env["DABSTEP_BENCH_CURSOR_KEY"] = (
        (root / "replay-cursor-key.txt").read_text().strip()
    )
    command = [
        shutil.which("npx"),
        "-y",
        "ptc-fs-mcp@0.3.0",
        "--root",
        str(root / "data"),
        "--include",
        "payments.csv",
        "--cursor-key-env",
        "DABSTEP_BENCH_CURSOR_KEY",
        "--max-cursor-hash-bytes",
        "24000000",
        "--max-read-bytes",
        "500000",
        "--max-result-bytes",
        "1000000",
    ]
    metadata = {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "dabstep-bench", "version": "1"},
        "io.modelcontextprotocol/clientCapabilities": {},
    }
    opening_started = time.perf_counter()
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        env=env,
        text=True,
        start_new_session=True,
    )
    request_id = 0
    try:
        if options.capture_page:
            request_id += 1
            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "method": "tools/list",
                        "params": {"_meta": metadata},
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            catalog = json.loads(process.stdout.readline())
            assert "error" not in catalog, catalog
            options.capture_page.with_suffix(".catalog.json").write_text(
                json.dumps(catalog["result"])
            )
            print(
                json.dumps(
                    {"catalog_open_ms": (time.perf_counter() - opening_started) * 1000}
                ),
                flush=True,
            )
        for sample in range(3):
            cursor = None
            calls = wire_bytes = source_bytes = 0
            started = time.perf_counter()
            while True:
                request_id += 1
                arguments = {"path": "payments.csv"}
                if cursor is not None:
                    arguments["cursor"] = cursor
                request = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": "tools/call",
                    "params": {
                        "name": "read_text_file",
                        "arguments": arguments,
                        "_meta": metadata,
                    },
                }
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()
                line = process.stdout.readline()
                response = json.loads(line)
                assert response["id"] == request_id and "error" not in response, (
                    response
                )
                assert not response["result"].get("isError", False), response
                value = response["result"]["structuredContent"]
                if options.capture_page and sample == 0 and calls == 0:
                    options.capture_page.write_text(json.dumps(value))
                calls += 1
                wire_bytes += len(line.encode())
                source_bytes += sum(
                    len(item["text"].encode()) for item in value["items"]
                )
                cursor = value["next_cursor"]
                if cursor is None:
                    break
            assert calls == 49 and source_bytes == 23_581_339
            print(
                json.dumps(
                    {
                        "sample": (
                            "first_after_catalog" if options.capture_page else "cold"
                        )
                        if sample == 0
                        else sample,
                        "wall_ms": (time.perf_counter() - started) * 1000,
                        "calls": calls,
                        "wire_bytes": wire_bytes,
                        "source_bytes": source_bytes,
                    }
                ),
                flush=True,
            )
    finally:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


if __name__ == "__main__":
    main()
