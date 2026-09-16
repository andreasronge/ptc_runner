# Serve a workflow over MCP

You end with a local MCP server that exposes one workflow as a tool, and a
client call that returns its result.

The gateway binds to loopback only, so reach it from the same machine or
through a tunnel you control.

## Publish the example

```console
ptc init orders-gateway --example kernel-tutorial
```

The `01-orders` step declares an input contract, a result contract, and a read
effect. A served workflow needs all three.

## Pin the application

```console
ptc validate orders-gateway/01-orders/ptc.json
```

Copy the `application_content_digest` value from the line it prints. The
gateway refuses to start once the application bytes stop matching that pin.

## Write the two documents

The host document holds the credential your bearer token comes from. Save it as
`ptc-gateway-host.json`:

```json
{
  "credentials": {
    "gateway_token": {"env": "PTC_GATEWAY_TOKEN"}
  },
  "install": {}
}
```

Put the token itself in `gateway.env`, using 32 or more ASCII bytes:

```console
echo 'PTC_GATEWAY_TOKEN=2f6c1d9a4b7e35c08d1f6a2b9c4e7d0a3b5f8e1c' > gateway.env
```

Then save the gateway document as `ptc-gateway.json`, pasting your pin into
`expected_application_content_digest`:

```json
{
  "version": 1,
  "listen": {"address": "127.0.0.1", "port": 8787, "path": "/mcp"},
  "authentication": {"bearer": {"binding": "gateway_token"}},
  "host": {"path": "./ptc-gateway-host.json"},
  "admission": {
    "max_inflight_requests": 8,
    "max_concurrent_runs": 2,
    "max_active_provider_calls": 1,
    "max_waiting_provider_calls": 0
  },
  "tools": [
    {
      "name": "summarize_orders",
      "title": "Summarize orders",
      "description": "Count orders, total the paid ones, and list the pending order ids.",
      "application": {"manifest": "./orders-gateway/01-orders/ptc.json"},
      "allow_write": false,
      "expected_application_content_digest": "sha256:b0f1e925d0fdeac3c24d86963ada724b7fbc4991040c93f5c568740f3146d717",
      "installation_config_pins": {},
      "provider_snapshot_pins": {}
    }
  ]
}
```

A workflow that selects no model keeps both pin maps empty.

## Start the gateway

```console
ptc gateway ptc-gateway.json --env-file gateway.env
```

A successful start prints nothing. Ask a second terminal whether it is ready:

```console
curl -s http://127.0.0.1:8787/health/ready
```

```json
{"status":"ready"}
```

## Call the tool

Set the same token in this terminal, then send the order rows as the tool
arguments:

```console
PTC_GATEWAY_TOKEN=2f6c1d9a4b7e35c08d1f6a2b9c4e7d0a3b5f8e1c
curl -sN http://127.0.0.1:8787/mcp \
  -H "Authorization: Bearer $PTC_GATEWAY_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2026-07-28' \
  -H 'Mcp-Method: tools/call' \
  -H 'Mcp-Name: summarize_orders' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"summarize_orders","arguments":{"orders":[{"id":"A-100","customer":"Ada","total":125.5,"status":"paid"},{"id":"A-101","customer":"Linus","total":89.0,"status":"pending"}]},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

The reply arrives as one server-sent event:

```console
: accepted

event: message
data: {"id":1,"jsonrpc":"2.0","result":{"content":[{"text":"{\"order_count\":2,\"paid_count\":1,\"paid_total\":125.5,\"pending_ids\":[\"A-101\"]}","type":"text"}],"isError":false,"resultType":"complete","structuredContent":{"order_count":2,"paid_count":1,"paid_total":125.5,"pending_ids":["A-101"]}}}
```

`structuredContent` carries the workflow result, and the text block repeats it
as JSON. Stop the gateway with Ctrl-C.

Use the [gateway reference](../reference/gateway.md) for every configuration
field, health response, and startup error. The
[application-manifest reference](../reference/application-manifest.md) covers
contracts and effects, and [Connect an MCP tool](connecting-tools-with-mcp.md)
goes the other way, letting a workflow call someone else's MCP server.
