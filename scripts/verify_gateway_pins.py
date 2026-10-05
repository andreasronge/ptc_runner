#!/usr/bin/env python3
"""Exercise pin discovery through the assembled executable, using local providers."""
import copy
import json
import pathlib
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

command, root = sys.argv[1], pathlib.Path(sys.argv[2])
project_root = pathlib.Path(__file__).resolve().parent.parent
root.mkdir()
requests = []


class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(body["method"])
        if body["method"] == "server/discover":
            result = {"resultType": "complete", "supportedVersions": ["2026-07-28"],
                      "capabilities": {"tools": {}}, "ttlMs": 0, "cacheScope": "private"}
        elif body["method"] == "tools/list":
            result = {"resultType": "complete", "tools": [{"name": "echo", "inputSchema": {"type": "object"}}],
                      "ttlMs": 0, "cacheScope": "private"}
        else:
            raise AssertionError("Discovery executed a tool")
        payload = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


def write(name, value):
    (root / name).write_text(json.dumps(value))


def invoke(config, status=0, env=True):
    write("gateway.json", config)
    args = [command, "gateway", str(root / "gateway.json"), "--print-pins"]
    if env:
        args += ["--env-file", "provider.env"]
    result = subprocess.run(args, cwd=root, capture_output=True, text=True, timeout=60)
    assert result.returncode == status, result.stderr
    assert not (root / "audit").exists()
    assert not (root / "artifacts").exists()
    with socket.socket() as probe:
        assert probe.connect_ex(("127.0.0.1", config["listen"]["port"])) != 0
    if status:
        assert result.stdout == "", result.stdout
        return json.loads(result.stderr)
    assert result.stderr == "", result.stderr
    return json.loads(result.stdout)


server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    endpoint = f"http://127.0.0.1:{server.server_port}/mcp"
    host = {"credentials": {"selected": {"env": "GATEWAY_PIN_SELECTED"},
                            "unused": {"file": "never-read.key"},
                            "gateway": {"file": "bearer.key"}},
            "install": {
                "model": {"source": "llm", "model": "openai-compat:http://127.0.0.1:1/v1|fixture",
                          "credential": "selected", "structured_output_mode": "unsupported",
                          "usage_guarantees": {"tokens": False, "cost_currency": None},
                          "installation_revision": "v1"},
                "decision": {"source": "decision", "backend": "http", "endpoint": "http://127.0.0.1:1/decision",
                             "allow_insecure_loopback": True, "model": "fixture", "installation_revision": "v1",
                             "usage_guarantees": {"tokens": True, "cost_currency": None},
                             "max_cost_per_call": {"currency": "USD", "amount": "0"}, "max_total_tokens_per_call": 8000},
                "remote": {"source": "mcp", "installation_revision": "v1",
                           "transport": {"type": "streamable_http", "endpoint": endpoint, "allow_insecure_loopback": True},
                           "tools": {"echo": {"as": "remote.echo", "effect": "read"}}}}}
    write("host.json", host)
    (root / "provider.env").write_text("GATEWAY_PIN_SELECTED=selected-value\n")
    (root / "main.clj").write_text('(ns app) (defn run {:effect :write} [input] (fail {"message" "must never execute"}))')
    write("schema.json", {"type": "object"})
    base = {"version": 1, "workflow": {"components": [{"id": "app", "path": "main.clj"}], "entry": "app/run"},
            "input": {"path": "never-read.json"}, "contracts": {"input_schema": {"path": "schema.json"},
                                                                    "result_schema": {"path": "schema.json"}}}
    tools = []
    for name in ["remote", "model", "decision", "empty"]:
        manifest = copy.deepcopy(base)
        if name == "remote":
            manifest["missions"] = {"default": {"components": [], "providers": ["remote"]}}
            manifest["providers"] = {"mission": [{"name": "remote", "config": {"allow": ["remote.echo"]}}]}
        elif name != "empty":
            manifest["providers"] = {"workflow": [{"name": name}]}
        write(name + ".json", manifest)
        tools.append({"name": name, "title": name, "description": name,
                      "application": {"manifest": name + ".json"}, "allow_write": True})
    tools.append(dict(tools[1], name="second-model"))
    config = {"version": 1, "host": {"path": "host.json"}, "tools": tools,
              "authentication": {"bearer": {"binding": "gateway"}},
              "listen": {"address": "127.0.0.1", "port": port, "path": "/mcp"},
              "admission": {"max_inflight_requests": 4, "max_concurrent_runs": 2,
                            "max_active_provider_calls": 2, "max_waiting_provider_calls": 0},
              "private_audit": {"directory": "audit", "max_file_bytes": 1024, "max_retained_files": 2},
              "artifacts": {"root": "artifacts", "trace": True, "inspection": True}}
    pins = invoke(config)
    assert set(pins) == {"remote", "model", "second-model", "decision", "empty"}
    for name, value in pins.items():
        assert set(value) == {"expected_application_content_digest", "installation_config_pins", "provider_snapshot_pins"}
        assert set(value["installation_config_pins"]) == (set() if name == "empty" else {"model" if name == "second-model" else name})
    # Inspect restoration in the packaged VM, where the one-shot API returns.
    (root / "failure.env").write_text("GATEWAY_PIN_SELECTED=\nGATEWAY_PIN_EXTRA=temporary\n")
    eval_code = """
      [path, env_file, failure_file] = System.argv()
      PtcRunner.CLILogger.install_stderr_handler()
      {:ok, _} = Application.ensure_all_started(:ptc_gateway)
      System.put_env("GATEWAY_PIN_SELECTED", "original")
      System.delete_env("GATEWAY_PIN_EXTRA")
      case PtcGateway.PinDiscovery.discover(path, env_file: env_file) do
        {:ok, _} -> :ok
        {:error, code} -> raise "Environment capture discovery failed: #{code}"
      end
      "original" = System.get_env("GATEWAY_PIN_SELECTED")
      {:error, :internal_error} = PtcGateway.PinDiscovery.discover(path, env_file: env_file)
      "original" = System.get_env("GATEWAY_PIN_SELECTED")
      nil = System.get_env("GATEWAY_PIN_EXTRA")
      {:error, :credential_unavailable} = PtcGateway.PinDiscovery.discover(path, env_file: failure_file)
      "original" = System.get_env("GATEWAY_PIN_SELECTED")
      nil = System.get_env("GATEWAY_PIN_EXTRA")
    """
    restored = subprocess.run([str(pathlib.Path(command).with_name("ptc_runner")), "eval", eval_code,
                               str(root / "gateway.json"), str(root / "provider.env"), str(root / "failure.env")],
                              capture_output=True, text=True, timeout=60)
    assert restored.returncode == 0, restored.stderr
    assert restored.stdout == "", restored.stdout
    stale = copy.deepcopy(config)
    for tool in stale["tools"]:
        tool.update({"expected_application_content_digest": "sha256:" + "0" * 64,
                     "installation_config_pins": {}, "provider_snapshot_pins": {}})
    assert invoke(stale) == pins
    # Missing selected credentials must refuse the command without output.
    failure = copy.deepcopy(config)
    failure["tools"] = [dict(tools[0], name="a"), dict(tools[1], name="z")]
    assert invoke(failure, 78, env=False) == {"error": "credential_unavailable"}
    # Stdio acquisition cleanup is observable before command exit on both paths.
    remote_http = copy.deepcopy(host["install"]["remote"])
    marker = root / "stdio.log"
    script = project_root / "test/support/mcp_stdio_source_fixture.sh"
    host["install"]["remote"]["transport"] = {"type": "stdio", "command": "/bin/sh",
                                               "args": [str(script), str(marker), "mark-close"]}
    host["install"]["remote"]["tools"] = {"structured": {"as": "remote.echo", "effect": "read"}}
    write("host.json", host)
    invoke(dict(config, tools=[tools[0]]))
    assert marker.read_text().count("session-closed") == 1
    broken_marker = root / "broken.log"
    host["install"]["broken"] = copy.deepcopy(host["install"]["remote"])
    host["install"]["broken"]["transport"]["args"] = [str(script), str(broken_marker), "unsupported-version"]
    write("host.json", host)
    broken_manifest = copy.deepcopy(base)
    broken_manifest["missions"] = {"default": {"components": [], "providers": ["broken"]}}
    broken_manifest["providers"] = {"mission": [{"name": "broken", "config": {"allow": ["remote.echo"]}}]}
    write("broken.json", broken_manifest)
    late_failure = dict(config, tools=[dict(tools[0], name="a"), dict(tools[0], name="z", application={"manifest": "broken.json"})])
    assert "error" in invoke(late_failure, 78)
    assert marker.read_text().count("session-closed") == 2
    assert "session-closed" in broken_marker.read_text()
    del host["install"]["broken"]
    assert "tools/call" not in marker.read_text()
    host["install"]["remote"] = remote_http
    write("host.json", host)
    # Selected workflow catalog refusal also precedes acquisition of the earlier MCP tool.
    catalog_manifest = copy.deepcopy(base)
    catalog_manifest["providers"] = {"workflow": [{"name": "remote", "config": {"catalog": True}}]}
    write("catalog.json", catalog_manifest)
    catalog_config = copy.deepcopy(config)
    catalog_config["tools"] = [dict(tools[0], name="a"), dict(tools[0], name="z", application={"manifest": "catalog.json"})]
    before = len(requests)
    assert invoke(catalog_config, 78) == {"error": "provider_source_unsupported"}
    assert len(requests) == before
    before = len(requests)
    oauth = copy.deepcopy(host["install"]["remote"])
    oauth["transport"] = {"type": "streamable_http", "endpoint": "https://mcp.example.test/mcp",
                          "oauth": {"installation_id": "fixture", "issuer": "https://auth.example.test",
                                    "scope_ceiling": [], "client": {"registration": "pre_registered", "client_id": "fixture",
                                    "token_endpoint_auth_method": "client_secret_basic", "client_secret_binding": "unused",
                                    "grant_types": ["authorization_code"], "redirect_uris": ["https://client.example.test/callback"]}}}
    host["install"]["remote"] = oauth
    write("host.json", host)
    assert invoke(config, 78) == {"error": "provider_source_unsupported"}
    assert len(requests) == before
    host["install"]["remote"]["transport"] = {"type": "streamable_http", "endpoint": endpoint, "allow_insecure_loopback": True}
    write("host.json", host)
    for tool in config["tools"]:
        tool.update(pins[tool["name"]])
    write("gateway.json", config)
    (root / "bearer.key").write_text("gateway-pin-bearer-0123456789abcdef")
    # The exact discovered maps must pass real serving startup for all four kinds.
    process = subprocess.Popen([command, "gateway", str(root / "gateway.json"),
                                "--env-file", str(root / "provider.env")],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 30
        while True:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health/ready", timeout=1) as response:
                    assert response.status == 200
                    break
            except OSError:
                assert process.poll() is None, process.communicate()
                assert time.monotonic() < deadline, "Gateway did not become ready"
                time.sleep(0.05)
    finally:
        process.terminate()
        stdout, stderr = process.communicate(timeout=30)
    assert process.returncode == 0, stderr
    assert stdout == "", stdout
    print("Packaged gateway pin discovery verified")
finally:
    server.shutdown()
    server.server_close()
