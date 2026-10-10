# Compose upstream MCP servers behind one tool

`published_briefs` reads one page from each of two `ptc-fs-mcp@0.3.0` stdio
servers and returns their combined text. The workflow declares `:effect :read`;
the gateway advertises `readOnlyHint: true`. It runs without a model or API key.
The roots contain small published fixtures, so both files fit in one page.

An aggregator exposes the upstream tool lists. This example exposes only the
task-level tool; its pinned program chooses the two reads inside a bounded run.
Each tool shares its upstream processes across calls. Use trusted servers that
keep no caller-sensitive state and honor cancellation.

## Run the offline gateway

You need the installed `ptc` executable, Node.js with `npx`, and Python 3.
The first acquisition downloads the pinned npm package; subsequent execution
needs neither a model nor a model key. Run from this directory:

```sh
export GATEWAY_TOKEN=local-gateway-example-token-32-bytes
ptc gateway gateway.json --print-pins > pins.json
cat pins.json
python3 pin.py gateway.json < pins.json
ptc gateway gateway.json
```

Discovery prints the content, installation, and provider snapshot pins keyed by
`published_briefs`. Review them before merging them into the gateway document.
Pins are machine-specific (including the stdio executable); rediscover them
when moving the example or changing its sources or host document. Discovery
accepts the unpinned documents shipped here; serving requires all three fields.

In another terminal, from this directory:

```sh
export GATEWAY_TOKEN=local-gateway-example-token-32-bytes
python3 call.py http://127.0.0.1:8765/mcp published_briefs
```

The result is:

```json
{"value": "A bounded program reads upstream files.\nOnly published files are available.\n"}
```

The gateway records canonical traces under `artifacts/traces` and bounded
operational JSON Lines under `artifacts/events`. Stop it with Ctrl-C.
The token protects the local endpoint; it is not an upstream credential.

## Optional: query canonical traces without a model

After the offline gateway has completed a call, leave it running and start a
second gateway in another terminal:

```sh
export GATEWAY_TOKEN=local-gateway-example-token-32-bytes
ptc gateway gateway-analysis.json --print-pins > analysis-pins.json
python3 pin.py gateway-analysis.json < analysis-pins.json
ptc gateway gateway-analysis.json
```

In a third terminal:

```sh
export GATEWAY_TOKEN=local-gateway-example-token-32-bytes
python3 call.py http://127.0.0.1:8766/mcp analysis_api
python3 call.py http://127.0.0.1:8766/mcp analysis_eval '{"source":"(return (count (get (history/runs {}) \"items\")))"}'
```

`analysis_api` returns the mission inventory. `analysis_eval` returns the count
as a string (for example `{"value": "1"}`). Its `history` facade offers
`runs`, `open`, `read`, and `counters` over normal canonical traces. Each call
captures the directory afresh, so subsequent main-gateway calls become visible.
Debug runs go to `debug-artifacts`, keeping them out of the captured directory.
Canonical traces show structure, timings and failure classes, not exact model
exchanges or capability payloads. The gateway refuses private snapshot sources.

## Optional: add a model-backed agent

`gateway-agent.json` replaces the deterministic workflow with `agent.core`.
The model is installed as `openrouter:deepseek/deepseek-v4-flash` in
`ptc-host.json`. Supply your own OpenRouter key in the environment:

```sh
export OPENROUTER_API_KEY=your-key
ptc gateway gateway-agent.json --print-pins > agent-pins.json
python3 pin.py gateway-agent.json < agent-pins.json
ptc gateway gateway-agent.json
```

Stop the offline gateway first because both use port 8765. Set `GATEWAY_TOKEN`
as above, then call `agent_briefs` with `call.py`. The agent asks the mission to
read the same briefs. Model calls have unknown effect, so this variant opts
into `allow_write` and private audit records under `audit`; it is not advertised
as read-only. Model output and availability can vary.

## Verification

The core release CI gate runs the offline example through `bin/ptc`, checks
the read-only annotation and exact result, and queries fresh traces using both
debug tools. To repeat against an assembled release:

```sh
python3 ../../scripts/verify_gateway_example.py /absolute/release/bin/ptc
```

The live model probe is tagged `:scheduled_e2e`:

```sh
mix test test/ptc_runner/gateway_example_test.exs --include scheduled_e2e
```

Run that last command from the repository root with `OPENROUTER_API_KEY` set.
See the [gateway reference](../../docs/reference/gateway.md) for pins, sharing,
refusals, shutdown and event log fields, and
[debug navigation](../../docs/reference/debug-navigation.md) for snapshot limits.
