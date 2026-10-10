#!/usr/bin/env python3
"""Call a gateway tool using the stateless MCP HTTP profile."""
import json
import os
import sys
import urllib.request

endpoint, name = sys.argv[1:3]
arguments = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
request = urllib.request.Request(endpoint, data=json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
    "params": {"name": name, "arguments": arguments, "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}}}
}).encode(), headers={
    "Authorization": "Bearer " + os.environ["GATEWAY_TOKEN"],
    "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
    "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": name})
with urllib.request.urlopen(request, timeout=180) as response:
    body = response.read().decode()
result = json.loads(next(line[6:] for line in body.splitlines() if line.startswith("data: ")))
assert not result.get("error"), result
assert not result["result"].get("isError"), result
print(json.dumps(result["result"]["structuredContent"]))
