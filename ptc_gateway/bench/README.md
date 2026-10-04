# Gateway load measurements

The in-process probe (`mix run bench/gateway_load.exs` from `ptc_gateway/`)
reports admission, mailbox and residue measurements. Its clients share the
server's BEAM schedulers, so throughput and latency include competition from
the generator. Use a separate client process for absolute HTTP measurements.

## External HTTP/1.1 client (optional)

Install [oha](https://github.com/hatoo/oha) separately. This benchmark is not a
test gate. Use a provider-free read deployment with a known bearer credential;
record its admission settings, machine, scheduler count and client version
alongside the results. The fixture in `support/gateway_fixture.exs` can create
such a deployment for a local measurement.

From the repository root, start the source gateway in one terminal, supplying
absolute paths to your deployment and environment file:

```sh
scripts/run_gateway_source.sh /absolute/path/gateway.json --env-file /absolute/path/credentials.env
```

In another terminal, set `GATEWAY_TOKEN` to that deployment's bearer value and
`GATEWAY_URL` to its loopback MCP URL (for example
`http://127.0.0.1:4000/mcp`). Run a catalog sweep:

```sh
oha --version
for concurrency in 1 2 4 8 16 32 64; do
  oha --no-tui --http-version 1.1 -n 2000 -c "$concurrency" -m POST \
    -H "authorization: Bearer $GATEWAY_TOKEN" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -H 'mcp-protocol-version: 2026-07-28' \
    -H 'mcp-method: tools/list' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
    "$GATEWAY_URL"
done
```

Keep-alive is enabled by default. Read the status distribution alongside
requests per second and latency percentiles: refusals are cheaper than useful
work. `tools/list` measures the transport/catalog path; to measure execution,
change both method fields to `tools/call`, add `mcp-name`, and supply the tool's
`name` and valid `arguments` in `params`. Check a single response for a successful
JSON-RPC result before each sweep. HTTP 200 alone does not prove workflow success.

The client now runs outside the server BEAM, but it still competes for host CPU.
These measurements remain machine-specific. Stop the gateway with SIGTERM when
finished. No throughput baseline or threshold is enforced.
