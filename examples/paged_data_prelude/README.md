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
(def records
  (paged/offset-source
    "files"
    "read_lines"
    {:path "/corpus/records.jsonl"}
    {:rows-at [:value "rows"]
     :limit 1000
     :max-pages 25
     :max-entries 5000}))
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
(def records
  {:server "files"
   :tool "read_large_file_chunk"
   :args {:filePath "/absolute/path/to/records.jsonl"}
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

Pagination options must be nested under `:page`. A flattened source like this
is rejected before the upstream is called:

```clojure
{:server "files"
 :tool "read_large_file_chunk"
 :args {:filePath "/absolute/path/to/records.jsonl"}
 :page-mode :chunk-index
 :limit 250
 :rows-at [:value "content"]}
```

The diagnostic uses a recoverable PTC-Lisp fail signal:

```clojure
{:reason "paged_source_config_error"
 :message "Pagination options must be nested under :page."
 :misplaced_keys ["page-mode" "limit" "rows-at"]
 :example {:server "files" :tool "read_large_file_chunk" :args {...} :page {...}}}
```

## API

```clojure
(paged/offset-source server tool args opts)
(paged/fold-pages source init step-fn)
(paged/sample source n)
(paged/inspect source opts)
(paged/field-presence source)
(paged/group-count source fields)
(paged/key-collisions source fields)
(paged/field-cardinality source)
(paged/duplicate-records source opts)
(paged/reconcile-totals source opts)
(paged/profile source opts)
```

`paged/fold-pages` is the generic escape hatch. Its callback is per row:
`(step acc row)`. Despite the name, `row` is one parsed record, not a page
batch; a callback that treats the second argument as a collection of rows can
silently count a record's fields instead of counting records. The other helpers
are domain-blind analysis primitives intended for smoke testing the next
`data/` prelude shape. Prefer `paged/profile` when several summaries are needed
from the same source: it fuses sampling, selected field-presence counts,
string-field counts, total row count, and one exact count of composite keys with
collisions into one page scan.

```clojure
(paged/fold-pages records 0 (fn [acc _row] (inc acc)))
(paged/fold-pages records [] (fn [acc row]
                               (if (= "open" (get row "status"))
                                 (conj acc row)
                                 acc)))
```

Use `paged/offset-source` for tools that accept offset and limit arguments. It
constructs the nested source map and avoids mixing offset pagination with
chunk-index pagination.

Use `paged/duplicate-records` when a near-unique identifier may hide repeated
record content. It uses `paged/field-cardinality` to exclude near-unique fields
from the default content key and reports duplicate groups plus `excess_rows`.

Prefer `paged/reconcile-totals`, not hand-rolled summation, when a declared or
control summary should match a paginated detail source. It classifies grouped
totals as `over`, `under`, or `match`. On overage, it emits an `overage_cue`:
identifier uniqueness does not settle whether the detailed source is complete
or inflated, so rule out repeated content before assigning blame. When a `[:sum
field]` measure coerces string-typed numeric values, it also emits
`coerced_measures`; a matching total then means the reconciliation used lenient
numeric parsing, not that strict or non-coercing consumers are unaffected.

The same caution applies when reconciliation is hand-rolled with `fold-pages`.
If detail rows exceed a declared/control total, do not treat the detail source
as authoritative until duplicate or inflated content under fresh identifiers is
ruled out. A unique `record_id` only proves the identifier is unique; it does
not prove the excess rows are real. Run `paged/duplicate-records` with the
identifier ignored on the relevant overage group before assigning
source-direction blame.

Use `paged/inspect` first when the exact row field names are not already known.
It reads a bounded sample and runs the built-in `describe` over that sample, so
the caller can choose exact field names before profiling:

```clojure
(paged/inspect records {:sample 5})
```

Then pass those exact field names to `paged/profile`:

Example:

```clojure
(def records
  (paged/offset-source
    "pages"
    "read_lines"
    {:path "/data/events.jsonl"}
    {:rows-at [:value "content"]
     :parse :jsonl
     :limit 500
     :max-pages 20
     :max-entries 10000}))

(paged/profile
  records
  {:sample 3
   :presence-fields ["status"]
   :string-fields ["amount"]
   :collision-fields ["entity_id" "event_time"]})

(paged/duplicate-records records {})

(paged/reconcile-totals
  records
  {:group-by (fn [row] (subs (get row "event_time") 0 10))
   :measures {"count" :count "amount" [:sum "amount"]}
   :declared declared-by-day
   :id-field "record_id"})
```

`paged/profile` returns `row_count`; use it as `line_count` for JSONL sources
where each parsed row is one input line.

## Bounds

The prelude bounds page loops with `:max-pages` and O(n) accumulators with
`:max-entries`. It still relies on the upstream tool to return page payloads
small enough for the sandbox to parse.

For repeated page folds over local `tool/call` fixtures, keep retained
tool-call previews small. Exact composite-key and cardinality helpers can keep
high-cardinality accumulators; use bounded page sizes, lower preview caps, or a
larger local heap for large smoke fixtures.
