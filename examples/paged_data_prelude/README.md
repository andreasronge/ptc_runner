# Paged Data Prelude

This is an experimental human-written prelude for bounded analysis over
paginated upstream tools. It is intentionally generic: the upstream may be an
MCP server, HTTP/OpenAPI tool, or local test fixture, as long as it returns one
bounded page per call.

The namespace is `paged`, not `data`, because `data` is currently a reserved
host namespace in `ptc_runner`.

## Source Specs

A source spec describes how to call a paginated tool and where rows live in the
tool result:

```clojure
(def trips
  {:server "files"
   :tool "read_lines"
   :args {:path "/corpus/trips.jsonl"}
   :page {:mode :offset
          :limit 1000
          :offset-arg :offset
          :limit-arg :limit
          :rows-at [:value "rows"]
          :max-pages 25
          :max-entries 5000}})
```

The page position is written into `:args`; only `:server`, `:tool`, and `:args`
are sent to `tool/call`.

Supported modes:

- `:offset` increments the position by the number of returned rows.
- `:token` reads the next cursor from `:token-at`.
- `:chunk-index` increments the position by one chunk and stops at
  `:total-pages-at`. If the backend returns overlapping chunk boundaries,
  provide `:start-line-at`; rows before the expected start line are dropped.

For `@willianpinho/large-file-mcp`, the source shape is backend-specific but
does not require changing the prelude:

```clojure
(def trips
  {:server "files"
   :tool "read_large_file_chunk"
   :args {:filePath "/absolute/path/to/trips.jsonl"}
   :page {:mode :chunk-index
          :limit 250
          :offset-arg :chunkIndex
          :limit-arg :linesPerChunk
          :rows-at [:value "content"]
          :parse :jsonl
          :total-pages-at [:value "totalChunks"]
          :start-line-at [:value "startLine"]
          :max-pages 100
          :max-entries 10000}})
```

## API

```clojure
(paged/fold-pages source init step-fn)
(paged/sample source n)
(paged/field-presence source)
(paged/group-count source fields)
(paged/key-collisions source fields)
(paged/profile source opts)
```

`paged/fold-pages` is the generic escape hatch. The other helpers are
domain-blind analysis primitives intended for smoke testing the next `data/`
prelude shape. Prefer `paged/profile` when several summaries are needed from
the same source: it fuses sampling, selected field-presence counts,
string-field counts, and one exact composite-key collision count into one page
scan.

Example:

```clojure
(paged/profile
  trips
  {:sample 3
   :presence-fields ["end_station_id"]
   :string-fields ["duration_min"]
   :collision-fields ["bike_id" "start_time"]})
```

## Bounds

The prelude bounds page loops with `:max-pages` and O(n) accumulators with
`:max-entries`. It still relies on the upstream tool to return page payloads
small enough for the sandbox to parse.

For repeated page folds over local `tool/call` fixtures, keep the retained
tool-call preview smaller than the default. A realistic smoke over
`/Users/andreasronge/ptc-bench-comparison` passed all eight planted base seeds
with `paged/profile`, `PAGE_LIMIT=250`, and `max_tool_call_result_bytes: 2048`.
The fused helper reduced the smoke from 40 tool calls to 13. The default 16 KB
ledger cap still failed on the larger/easier seeds under the default heap,
because exact composite-key counting keeps a high-cardinality accumulator while
page previews are retained.

```sh
cd /Users/andreasronge/ptc-bench-comparison
for seed in 1 2 3 4 5 6 7 8; do
  SEED=$seed MAX_TOOL_CALL_RESULT_BYTES=2048 scripts/smoke-paged-prelude.sh
done
```
