# MCP Getting Started

This guide walks from installing `ptc_runner_mcp` to making your first
signature-validated call. We use raw JSON-RPC frames so you can see
exactly what the server consumes and emits; in practice your MCP
client (Claude Desktop, Cursor, Cline, …) hides this layer.

For the conceptual overview, see
[`docs/mcp-server.md`](../mcp-server.md). For full client wiring,
see [`mcp_server/README.md`](../../mcp_server/README.md).

## 1. Install

Build the Mix release from the repo:

```bash
git clone https://github.com/andreasronge/ptc_runner
cd ptc_runner/mcp_server
mix deps.get
MIX_ENV=prod mix release
```

The release lives at
`_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp`. Smoke-test it:

```bash
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp version
# → ptc_runner_mcp 0.1.0
```

For Claude Desktop / Cursor / Cline / Claude Code wiring, use the
ready-to-paste snippets in
[`mcp_server/README.md`](../../mcp_server/README.md). The rest of this
guide drives the server with raw JSON-RPC frames piped into the
release; that lets us inspect every byte.

## 2. Hello world: `(+ 1 2)`

Pipe a small JSON-RPC session into the server. The session must
include `initialize` and the `notifications/initialized` notification
before any `tools/call`.

```bash
cat <<'EOF' | _build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp start
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"hello","version":"0.0.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"lisp_eval","arguments":{"program":"(+ 1 2)"}}}
EOF
```

The third frame is the call. The server's response (one NDJSON line on
stdout, formatted here for readability) wraps the R22 success payload
in the standard MCP `tools/call` envelope:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "isError": false,
    "structuredContent": {
      "status": "ok",
      "result": "user=> 3",
      "prints": [],
      "feedback": "...",
      "truncated": false
    },
    "content": [
      { "type": "text", "text": "{\"status\":\"ok\",\"result\":\"user=> 3\",...}" }
    ]
  }
}
```

The `result` field (`"user=> 3"`) is an LLM-facing preview — an
EDN/Clojure rendering of the program's final expression, not a
programmatic value. To get a typed value back, supply an
`output_schema` (step 4 below).

Note: each MCP `tools/call` is one-shot — `defn`'d names do NOT
persist into the next call. The response intentionally omits any
`memory` field so callers don't infer state from a single program's
local definitions (issue #879).

The `content[0].text` block carries the same JSON as a string, for
clients that read content blocks instead of `structuredContent`.

## 3. Add `context`: bind values under `data/`

The `context` field is a JSON object whose keys become bindings under
the `data/` namespace inside the program. There is no `context`
binding — you reference values as `data/<key>`.

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "lisp_eval",
    "arguments": {
      "program": "(reduce + (map #(get % \"value\") data/items))",
      "context": {
        "items": [
          {"label": "a", "value": 10},
          {"label": "b", "value": 20},
          {"label": "c", "value": 12}
        ]
      }
    }
  }
}
```

The server binds `data/items` to the JSON array, runs the program in
the sandbox, and returns `result: "user=> 42"` (same envelope shape as
step 2).

A few points worth knowing up front:

- Map keys stay as strings. To read `value` you write
  `(get % "value")`, not `(:value %)`. PTC-Lisp does not auto-convert
  string keys to keywords — that is intentional, to keep the
  JSON ↔ PTC-Lisp boundary honest.
- A program that references `data/foo` when `foo` is absent returns
  `reason: "runtime_error"` with a message naming the missing
  binding.
- Keys may not contain `/` (would shadow the namespace) or be empty;
  either causes `args_error`.

## 4. Add `output_schema`: get a typed `validated` value back

The `result` field is a preview string. To consume the program's
return value programmatically, pass JSON Schema in `output_schema`. On
match, the response carries a structured `validated` JSON value
alongside the preview.

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "lisp_eval",
    "arguments": {
      "program": "(let [vs (map #(get % \"value\") data/items)] {:total (reduce + vs) :count (count vs)})",
      "context": {
        "items": [
          {"label": "a", "value": 10},
          {"label": "b", "value": 20},
          {"label": "c", "value": 12}
        ]
      },
      "output_schema": {
        "type": "object",
        "properties": {
          "total": { "type": "integer" },
          "count": { "type": "integer" }
        },
        "required": ["total", "count"]
      }
    }
  }
}
```

Successful response:

```json
{
  "isError": false,
  "structuredContent": {
    "status": "ok",
    "result": "user=> {:total 42, :count 3}",
    "validated": { "total": 42, "count": 3 },
    "prints": [],
    "feedback": "...",
    "truncated": false
  }
}
```

`validated.total` is a real JSON `42` — your client can read it
directly; no parsing of the preview string. If the program returned a
shape that did not match the schema (e.g. `:total` was a string),
the response would have `isError: true` and `reason:
"validation_error"`, with a `feedback` string the calling LLM can use
to self-correct.

`output_schema` is the path to programmatic data on this surface.
Without it, the response carries the LLM-readable preview only — by
design, to keep the boundary between LLM-facing text and machine-facing
JSON sharp.

## 5. Inspect a trace file

Tracing is opt-in and off by default. To turn it on, pass
`--trace-dir`:

```bash
mkdir -p /tmp/ptc-traces
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp start \
  --trace-dir /tmp/ptc-traces
```

(You can append the flag to the `args` array in any client config —
e.g. `"args": ["start", "--trace-dir", "/tmp/ptc-traces"]`.)

After running a `tools/call`, one JSONL file appears under the trace
directory, one line per telemetry event:

```bash
ls /tmp/ptc-traces/
# → 2026-05-07T12-34-56_<uuid>.jsonl
```

```bash
head -1 /tmp/ptc-traces/*.jsonl
# {"event":"trace.start","trace_kind":"mcp_call","ts":"2026-05-07T12:34:56Z",...}
```

A typical trace contains, in chronological order:

- `trace.start` — header with the trace UUID.
- `[:ptc_runner_mcp, :call, :start]` — the MCP call began.
- `[:ptc_runner, :lisp, :execute, :start]` — the sandbox started.
- `[:ptc_runner, :lisp, :execute, :stop]` — the sandbox finished.
- `[:ptc_runner_mcp, :call, :stop]` — the MCP call returned.
- `trace.stop` — footer.

Two flags shape what gets written:

- `--trace-payloads summary` (default when tracing is on) — records
  sizes and SHA-256 digests of `program` / `context` / `result` bytes.
  Safe for shared logs.
- `--trace-payloads full` — includes verbatim bytes. Use only when
  actively debugging a specific reproduction.
- `--trace-max-files 1000` (default) — rolling-deletion cap on the
  trace directory.

To browse traces interactively, point the trace viewer at the
directory:

```bash
mix ptc.viewer --trace-dir /tmp/ptc-traces
```

## What's next

- [`docs/mcp-server.md`](../mcp-server.md) — security model, comparison
  with Python / JS execution servers, architecture diagram.
- [`docs/ptc-lisp-specification.md`](../ptc-lisp-specification.md) —
  the PTC-Lisp language reference (a Clojure subset).
- [`docs/function-reference.md`](../function-reference.md) — every
  built-in function with its signature.
