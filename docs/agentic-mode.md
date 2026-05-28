# Agentic Mode

Reference for the experimental `lisp_task` MCP tool that lets clients
delegate a natural-language task to a server-side planner.

## Overview

Agentic mode is an experimental layer on top of [aggregator
mode](aggregator-mode.md). It adds a second MCP tool, `lisp_task`, for
clients that want to ask for a natural-language task instead of
authoring PTC-Lisp directly. The server uses the configured planner
model to run a SubAgent in explicit completion mode with one MCP-owned
tool available inside the planner: `tool/call`. The planner may
call upstream MCP servers, inspect the tagged result, and must finish
with `(return ...)` or `(fail ...)`. Successful answers are intended to
be human-readable text.

`lisp_task` does not replace `lisp_eval`. Both tools are
advertised when all of these are true:

- at least one upstream MCP server is configured;
- `--agentic` or `PTC_RUNNER_MCP_AGENTIC=true` is set;
- the aggregator posture is read-only, or
  `--agentic-allow-writes` / `PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES=true`
  is set explicitly.

For background on the broader MCP server, see
[mcp-server.md](mcp-server.md). Full flag reference lives in
[mcp-server-configuration.md](mcp-server-configuration.md).

## Quick start

Use the same upstream config as aggregator mode, then enable agentic
mode and provide an LLM key for the planner provider. The default
`gemini-flash-lite` alias resolves inside PtcRunner to
`openrouter:google/gemini-3.1-flash-lite`.

```bash
export OPENROUTER_API_KEY=...
export PTC_RUNNER_MCP_UPSTREAMS="$HOME/ptc-mcp-sandbox/upstreams.json"
export PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY=true
export PTC_RUNNER_MCP_AGENTIC=true
export PTC_RUNNER_MCP_AGENTIC_MODEL=gemini-flash-lite

cd /absolute/path/to/ptc_runner/mcp_server
mix run --no-halt --no-compile
```

Equivalent release-binary args:

```json
"args": [
  "start",
  "--upstreams-config", "/absolute/path/to/upstreams.json",
  "--aggregator-read-only",
  "--agentic",
  "--agentic-model", "gemini-flash-lite"
]
```

Once enabled, clients call:

```json
{
  "name": "lisp_task",
  "arguments": {
    "task": "Read README.md and return the first 5 non-empty lines.",
    "constraints": {
      "max_items": 5
    }
  }
}
```

The response includes:

- `status`: `"ok"` or `"error"`;
- `answer`, a human-readable text response;
- `program`, unless `--agentic-include-program=false`;
- `upstream_calls`, the ledger of MCP calls made by the planner;
- `planner` metadata, including model, turn count, duration, and token
  fields when the provider reports them.

## Turns and write safety

By default `lisp_task` runs with `max_turns: 1` and `retry_turns: 0`.
That keeps the planner cheap and predictable, but a model may fail if
it needs feedback to correct a generated program. Raise
`--agentic-max-turns` for multi-turn planner repair. Read-only
continuations may use parser/runtime/validation feedback. After any
write-capable or unknown-effect upstream call, `lisp_task` blocks
further continuation unless the planner returns or fails in the same
turn; this avoids retrying after partial side effects.

`--agentic-allow-writes` is intentionally separate from
`--aggregator-read-only`. If the aggregator is not asserted read-only,
agentic boot fails unless writes are explicitly allowed. Upstream
servers still own the real permission boundary.

## SubAgent config file

For deployment-specific prompt guidance, use a small JSON file:

```json
{
  "max_turns": 2,
  "retry_turns": 1,
  "system_prompt": {
    "prefix": "Prefer read-only tools and keep answers concise.",
    "suffix": "Return JSON only when the task asks for JSON."
  }
}
```

Pass it with `--agentic-subagent-config /path/to/agentic.json` or
`PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG=/path/to/agentic.json`.
Allowed keys are `max_turns`, `retry_turns`, and `system_prompt` with
`prefix` / `suffix`. Reserved keys such as `tools`, `completion_mode`,
`signature`, and `ptc_transport` fail boot because the MCP server owns
those parts of the SubAgent contract.

## Capability summary

`lisp_task` advertises a compact capability summary instead of the full
aggregator authoring card. By default this is generated from the
frozen upstream catalog at boot, capped by
`--agentic-capability-summary-max-bytes`, and logged only as byte
count plus SHA-256 hash. To provide your own wording, set
`--agentic-capability-summary /path/to/summary.md`.

## Configuration flags

These are the agentic-specific flags. See
[mcp-server-configuration.md](mcp-server-configuration.md) for the
full reference, including framing, tracing, and session limits.

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--agentic` | `PTC_RUNNER_MCP_AGENTIC` | `false` | Expose the experimental `lisp_task` tool when aggregator mode is active. |
| `--agentic-model` | `PTC_RUNNER_MCP_AGENTIC_MODEL` | `gemini-flash-lite` | Planner model alias or provider-qualified model id. |
| `--agentic-task-timeout-ms` | `PTC_RUNNER_MCP_AGENTIC_TASK_TIMEOUT_MS` | `45000` | Wall-clock cap for one `lisp_task` request. |
| `--agentic-planner-timeout-ms` | `PTC_RUNNER_MCP_AGENTIC_PLANNER_TIMEOUT_MS` | `15000` | Per-planner-call timeout. |
| `--agentic-max-output-tokens` | `PTC_RUNNER_MCP_AGENTIC_MAX_OUTPUT_TOKENS` | `1200` | Planner output token cap. |
| `--agentic-max-result-bytes` | `PTC_RUNNER_MCP_AGENTIC_MAX_RESULT_BYTES` | `4096` | Maximum rendered answer bytes in the `lisp_task` response. |
| `--agentic-include-program` | `PTC_RUNNER_MCP_AGENTIC_INCLUDE_PROGRAM` | `true` | Include the generated PTC-Lisp program in `lisp_task` responses. |
| `--agentic-trace-prompts` | `PTC_RUNNER_MCP_AGENTIC_TRACE_PROMPTS` | `false` | Include agentic prompt snapshots in traces. Use only for local debugging. |
| `--agentic-max-turns` | `PTC_RUNNER_MCP_AGENTIC_MAX_TURNS` | `1` | Maximum SubAgent planner turns per `lisp_task`. |
| `--agentic-retry-turns` | `PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS` | `0` | Additional retry turns after parser/runtime/validation feedback. |
| `--agentic-allow-writes` | `PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES` | `false` | Permit `lisp_task` in write-capable or unknown-effect aggregator configurations. |
| `--agentic-subagent-config` | `PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG` | unset | JSON config file for `max_turns`, `retry_turns`, and prompt prefix/suffix. |
| `--agentic-capability-summary-max-bytes` | `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY_MAX_BYTES` | `800` | Byte cap for the auto-generated `lisp_task` capability summary. |
| `--agentic-capability-summary` | `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY` | unset | Path to an operator-supplied capability summary for `lisp_task`. |

## Prompt-size benchmark

Agentic mode has two separate prompt-cost surfaces:

- `lisp_task`'s MCP tool entry is paid by the client at `tools/list`
  time, once per session.
- The planner system prompt is paid server-side on every `lisp_task`
  invocation.

Run the deterministic tier-1 benchmark from `mcp_server/`:

```bash
mix run --no-start bench/agentic_prompt_bench.exs \
  --out=../tmp/agentic_prompt_bench.json
```

It makes no LLM calls. It freezes synthetic upstream catalogs and
routes through `Tools.list/0`, `Agentic.Prompt.system_prompt/1`,
`CatalogDescription.render/0`, and `CapabilitySummary.from_frozen/1`.
With the default `--agentic-capability-summary-max-bytes=800` and
default auto inline thresholds (`8` tools / `800` chars), the
current bench reports:

| Fleet | `:auto` effective mode | Planner prompt `:auto` | Planner prompt `:inline` | Planner prompt `:lazy` | `lisp_task` tool entry `:auto` | `lisp_task` tool entry `:inline` | `lisp_task` tool entry `:lazy` |
|---|---|---:|---:|---:|---:|---:|---:|
| small: 3 servers x 10 tools | inline | ~2.4 K tokens | ~2.4 K | ~0.7 K | ~0.7 K | ~1.1 K | ~0.6 K |
| medium: 5 servers x 30 tools | lazy | ~0.7 K | ~9.7 K | ~0.7 K | ~0.7 K | ~3.2 K | ~0.6 K |
| large: 10 servers x 100 tools | lazy | ~0.7 K | ~61.2 K | ~0.7 K | ~0.7 K | ~18.6 K | ~0.6 K |

For the large synthetic fleet, forced `:inline` adds roughly 60 K
estimated tokens to every planner invocation versus `:auto`/`:lazy`.
For the small fleet, `:auto` intentionally stays inline, and forcing
`:lazy` saves roughly 1.7 K estimated planner tokens per `lisp_task`
call at the cost of runtime REPL discovery.

When an upstream tool advertises `outputSchema`, the generated catalog
turns the supported JSON Schema subset into compact PTC-style output
hints, for example:

```text
list_entries(path: string) -> {entries [:string], truncated :bool?}
```

These hints are planner guidance, not runtime validation of upstream
results. Supported conversions include JSON Schema `string`,
`integer`, `number`, `boolean`, arrays with `items`, and objects with
`properties`; unknown or complex schemas fall back to `:any` or
`:map`. If an upstream omits `outputSchema`, the generated catalog
marks the tool as `-> :unknown_content`. That means the upstream did
not advertise a domain output schema; the planner should inspect the
tagged `tool/call` result's `:value` before assuming a shape.

## Real-provider smoke

From `mcp_server/`, with `OPENROUTER_API_KEY` available:

```bash
mix run --no-start bench/agentic_real_provider_smoke.exs \
  --model=gemini-flash-lite \
  --runs=1 \
  --fail-on-skip
```

The smoke starts a local filesystem upstream and exercises `lisp_task`
through the real planner provider. It exits non-zero on failures and
prints the generated program for failed cases.

## Real-provider eval

Issue #931's tier-2 harness runs a small real-LLM eval matrix against
OpenRouter and the local filesystem MCP upstream:

```bash
mix run --no-start bench/agentic_real_eval.exs \
  --runs=1 \
  --models=gemini-flash-lite \
  --catalog-modes=inline,lazy \
  --json-out=../tmp/agentic_real_eval.json \
  --md-out=../tmp/agentic_real_eval.md \
  --fail-on-skip
```

This is not deterministic and is not a default CI check. It exits
non-zero when any eval cell fails, writes JSON plus Markdown reports,
and records planner prompt/completion bytes, provider token counts,
upstream-call counts, and inferred catalog-operation mentions.

## See also

- [aggregator-mode.md](aggregator-mode.md) - the underlying
  programmatic aggregator that `lisp_task` builds on.
- [mcp-server.md](mcp-server.md) - conceptual overview of the MCP
  server.
- [mcp-server-configuration.md](mcp-server-configuration.md) - full
  flag and env var reference.
- [`../mcp_server/README.md`](../mcp_server/README.md) - onboarding
  and installation.
