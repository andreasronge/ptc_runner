# Root Upstream Runtime

The root `ptc_runner` library owns the upstream runtime used by both
`mix ptc.repl` and `ptc_runner_mcp`. It lets PTC-Lisp programs call
configured upstream tools with `(tool/call ...)` and inspect them with
`(tool/servers)`, `(dir ...)`, `(doc ...)`, `(meta ...)`, and
`(apropos ...)`.

Use this when you want local REPL programs or embedded Elixir callers
to use the same OpenAPI/MCP upstream machinery without running the MCP
server process.

## REPL Usage

```bash
mix ptc.repl --upstreams-config upstreams.json
mix ptc.repl --upstreams-config upstreams.json -e "(tool/servers)"
mix ptc.repl --upstreams-config upstreams.json \
  --catalog-snapshot-mode frozen \
  -e "(dir \"github\")"
```

The REPL resolves the config path from `--upstreams-config` first, then
`PTC_RUNNER_UPSTREAMS`. If neither is set, it starts a plain PTC-Lisp
REPL with no upstream tools.

Useful options:

| Option | Default | Meaning |
|---|---:|---|
| `--max-tool-calls` | `50` | Per-evaluation `(tool/call ...)` budget. |
| `--max-catalog-ops` | `25` | Per-evaluation discovery form budget. |
| `--upstream-call-timeout-ms` | `5000` | Per-upstream-call timeout. |
| `--max-upstream-response-bytes` | `2097152` | Per-response cap before decode. |
| `--catalog-mode` | `auto` | `auto`, `inline`, or `lazy` catalog text exposure. |
| `--catalog-snapshot-mode` | `live` | `live` or `frozen` catalog population. |

## Config Format

The config format is shared with `ptc_runner_mcp`. Use explicit
transport names:

- `"openapi"` for curated read-only JSON OpenAPI `GET` operations.
- `"mcp_stdio"` for external MCP servers launched over stdio.
- `"mcp_http"` for external MCP servers reached over Streamable HTTP.

Old transport names such as `"stdio"` and `"http"` are rejected. See
[`aggregator-mode.md`](aggregator-mode.md) for complete JSON examples,
credential bindings, static-header restrictions, OpenAPI validation,
and the `(tool/call ...)` authoring model.

## Snapshot Modes

`live` mode is the root REPL default. MCP stdio/http clients are not
started or listed at runtime startup; discovery and `(tool/call ...)`
attempt to start/list them when needed. This keeps REPL startup fast
when a configured MCP upstream is down or expensive to launch.

`frozen` mode starts and lists MCP stdio/http upstreams during runtime
startup. The scrubbed snapshot is then reused for catalog text and
discovery. Startup fails if a configured MCP upstream cannot start or
answer `tools/list`. The MCP server uses frozen mode by default so its
advertised tool surface is stable for the lifetime of the server
process.

OpenAPI schemas are loaded during runtime startup in both modes because
the runtime compiles the explicitly included operations before exposing
them. Prefer `schema_file` for production so startup does not depend on
a schema host.

## Redaction

Credential values from `env`, `file`, and `literal` bindings are
resolved when the root upstream runtime starts. They are stored only in
the runtime credential struct and scrub set, not in upstream config
maps, call records, traces, or catalog snapshots. Rotate an env var or
credential file by restarting the REPL or MCP server process.

Catalog and discovery output is scrubbed through the runtime redactor
before it reaches REPL output, MCP tool descriptions, traces, debug
records, or session history.

When the MCP server embeds the root runtime, it also registers the
runtime's secret set with the MCP server redactor so existing trace,
debug, session, log, and agentic prompt scrub paths remain active.
