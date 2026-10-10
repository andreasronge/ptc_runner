#!/usr/bin/env python3
"""Run the shipped gateway example through an assembled ptc executable."""
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

command = str(pathlib.Path(sys.argv[1]).resolve())
model = "--model" in sys.argv[2:]
if not model:
    os.environ.pop("OPENROUTER_API_KEY", None)
project = pathlib.Path(__file__).resolve().parent.parent


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def call(root, endpoint, name, arguments=None):
    result = subprocess.run([sys.executable, str(root / "call.py"), endpoint, name,
                             json.dumps(arguments or {})], capture_output=True, text=True, timeout=200)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)["value"]


def start(root, name):
    path = root / name
    config = json.loads(path.read_text())
    config["listen"]["port"] = port()
    path.write_text(json.dumps(config))
    discovered = subprocess.run([command, "gateway", str(path), "--print-pins"],
                                capture_output=True, text=True, timeout=180)
    assert discovered.returncode == 0, discovered.stderr
    pinned = subprocess.run([sys.executable, str(root / "pin.py"), str(path)],
                            input=discovered.stdout, capture_output=True, text=True)
    assert pinned.returncode == 0, pinned.stderr
    stderr = open(root / (name + ".stderr"), "w+")
    process = subprocess.Popen([command, "gateway", str(path)], stdout=subprocess.PIPE, stderr=stderr)
    endpoint = f'http://127.0.0.1:{config["listen"]["port"]}'
    deadline = time.monotonic() + 180
    try:
        while time.monotonic() < deadline:
            assert process.poll() is None, pathlib.Path(stderr.name).read_text()
            try:
                with urllib.request.urlopen(endpoint + "/health/ready", timeout=1) as response:
                    if json.load(response)["status"] == "ready":
                        return process, stderr, endpoint + "/mcp"
            except OSError:
                pass
            time.sleep(0.1)
        raise AssertionError("Gateway did not become ready")
    except BaseException:
        stop(process, stderr)
        raise


def stop(process, stderr):
    process.terminate()
    try:
        stdout, _ = process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise AssertionError("Gateway failed to drain")
    finally:
        stderr.close()
    assert process.returncode == 0, pathlib.Path(stderr.name).read_text()
    assert stdout == b""


os.environ["GATEWAY_TOKEN"] = "gateway-example-test-token-32-bytes"
with tempfile.TemporaryDirectory(prefix="ptc-gateway-example-") as tmp:
    root = pathlib.Path(tmp) / "example"
    shutil.copytree(project / "examples/gateway-mcp", root)
    # Keep the model path independent of any locally pinned example documents.
    processes = []
    try:
        process, stderr, endpoint = start(root, "gateway-agent.json" if model else "gateway.json")
        processes.append((process, stderr))
        expected = (root / "notes/brief.txt").read_text() + (root / "policy/brief.txt").read_text()
        if not model:
            request = urllib.request.Request(endpoint, data=json.dumps({
                "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {"_meta": {
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities": {}}}}).encode(), headers={
                "Authorization": "Bearer " + os.environ["GATEWAY_TOKEN"],
                "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"})
            with urllib.request.urlopen(request) as response:
                tools = json.load(response)["result"]["tools"]
            assert [tool["name"] for tool in tools] == ["published_briefs"]
            assert tools[0]["annotations"]["readOnlyHint"] is True
        assert call(root, endpoint, "agent_briefs" if model else "published_briefs") == expected
        if not model:
            process, stderr, debug = start(root, "gateway-analysis.json")
            processes.append((process, stderr))
            query = '(return (count (get (history/runs {}) "items")))'
            before = int(call(root, debug, "analysis_eval", {"source": query}))
            assert before >= 1
            assert "history/runs" in call(root, debug, "analysis_api")
            assert call(root, endpoint, "published_briefs") == expected
            assert int(call(root, debug, "analysis_eval", {"source": query})) == before + 1
            assert list((root / "debug-artifacts/traces").glob("*.jsonl"))
            assert list((root / "artifacts/events").glob("*.jsonl"))
    finally:
        for process, stderr in reversed(processes):
            stop(process, stderr)
print("Gateway example passed" + (" with live model" if model else " offline"))
