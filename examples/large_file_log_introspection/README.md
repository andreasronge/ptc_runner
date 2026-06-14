# Large-File Log Introspection Prelude

This example shows how to expose the same `log/` API as
`PtcRunner.TraceLog.Introspection.prelude_source/0`, but backed by an upstream
large-file MCP server instead of host-bound Elixir tools.

The upstream server is expected to be named `logs` and provide the
`read_large_file_chunk` tool from `@willianpinho/large-file-mcp`.

Example upstream config:

```json
{
  "upstreams": {
    "logs": {
      "transport": "mcp_stdio",
      "command": "npx",
      "args": ["-y", "@willianpinho/large-file-mcp"],
      "env": {
        "OVERLAP_LINES": "0",
        "CACHE_ENABLED": "false"
      },
      "handshake_timeout_ms": 60000
    }
  }
}
```

Before loading `large_file_log_introspection.clj`, edit the `log-files` vector
near the top of the file to contain the absolute JSONL turn-log paths to read.
The exported API is:

```clojure
(log/sessions)
(log/sessions {:limit 20})
(log/turns session-id)
(log/turns session-id {:limit 20})
(log/programs session-id)
(log/programs session-id {:limit 20})
(log/tool-calls session-id)
(log/tool-calls session-id {:limit 20})
```

Each function returns a page map:

```clojure
{"items" [...]
 "next_cursor" "opaque-cursor"
 "has_more" true
 "limit" 20}
```

Pass the returned cursor to continue:

```clojure
(let [page (log/sessions {:limit 20})]
  (log/sessions {:limit 20 :cursor (get page "next_cursor")}))
```

Treat cursors as opaque. The large-file backend stops as soon as a page is
full; if the remaining source has no later matching items, a continuation page
may be empty.

There are also compatibility helpers:

```clojure
(log/turns-page session-id page page-size)
(log/programs-page session-id page page-size)
(log/tool-calls-page session-id page page-size)
(log/sessions-all)
(log/turns-all session-id)
(log/programs-all session-id)
(log/tool-calls-all session-id)
```

## Operational Notes

This prelude uses `read_large_file_chunk` internally. Each configured file costs
one upstream call for its first page, plus one call for every remaining chunk
needed by the requested `log/` export.

For realistic corpora, tune both:

- `lines-per-page` in the prelude.
- The PTC upstream call budget, for example `max_tool_calls` when running
  through `PtcRunner.Upstream.Eval.run_lisp/3`.

The checked-in e2e smoke over local benchmark logs uses `lines-per-page` of `5`
and `max_tool_calls: 200`. With the default call cap of `50`, that realistic
multi-file corpus hits `cap_exhausted` before completing. That is expected
behavior: the prelude is intentionally explicit about the cost of scanning
remote/disk-backed logs.

Prefer the cursor-paged exports for larger logs. The `*-all` helpers are
convenient for small fixtures and exact API parity, but can become whole-corpus
scans when backed by a remote file server.

## Tests

The default test suite does not start the external MCP server:

```sh
mix test test/ptc_runner/upstream_runtime_test.exs
```

Opt-in e2e coverage starts `@willianpinho/large-file-mcp` through `npx`:

```sh
mix test --include e2e test/ptc_runner/upstream_runtime_test.exs
```

One e2e test uses synthetic canonical turn-log rows. Another uses a local
realistic corpus when available:

```text
/Users/andreasronge/ptc-bench-comparison/agent-runs/planted-ptc/run-logs/turn-log
```

That local-corpus test samples the largest planted PTC turn-log files, reads
them through the large-file MCP upstream, and compares the resulting `log/`
projections against `PtcRunner.TraceLog.Introspection.tools/1` over the same
events. If the directory is missing, the test skips the local-corpus assertions.

This is intentionally a prelude-only experiment. If this shape proves useful,
`ptc_runner` can later generate the same prelude from Elixir options.
