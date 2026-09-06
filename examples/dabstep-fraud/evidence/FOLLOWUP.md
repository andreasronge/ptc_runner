# Remaining experiments for #1845

These experiments continue [the first optimization](PROFILE.md#optimization-measurements-for-1845)
on `ea7d40033242fb83659fbd1d3696f3a11759cd59` (PR #1848), on 2026-09-06.
They use the same pinned CSV, `ptc-fs-mcp@0.3.0`, Erlang 29.0.3 and Elixir
1.20.2. They retain benchmark variants and one further runtime fix: compute trace-run
sort keys once per summary. They add no production API or prompt changes.
Individual measurements and provenance are retained in `FOLLOWUP.json`.

## Findings and decisions

1. **Interpreted projection remains the main dataset-processing cost.**
   Preparing column types once per page is a small improvement, not an order
   of magnitude change. Investigate a generic bounded native projection or
   pure-builtin execution path before adding a parsed-page cache.
2. **Trace sorting had a cheap, measurable fix.** Computing timestamp sort
   keys once per summary reduced the 1,000-run query from 859 to 235 ms. The
   fix is included. Broad queries still rebuild summaries on every page;
   selected-run loading and a bounded snapshot index address different parts
   of the remaining cost.
3. **Ordinary user-namespace scans scale with unrelated bindings.**
   The prelude optimization does not remove these scans. Measure workloads
   with large ordinary namespaces before selecting an alias-aware index.
4. **A row fold is not a CPU optimization.** The prototype is slower than the
   equivalent manual reduction. It centralizes pagination but still requires
   a compact accumulator; accepting an arbitrary reducer does not make an
   unbounded accumulator safe.
5. **Validation and digest inspection are a minority of page processing.**
   Keep them enabled. Full inspection increases recording volume; the example
   already selects digest capture.

## Controlled page and dispatch experiments

The first MCP response contains 485,376 source bytes and 2,847 complete data
rows. The harness captures this response and the server's actual tool schemas.
It compares every projected row, not just the row count, against the native
reference. Additional cases check integer/float/Boolean conversion, empty
cells, and identical malformed-value failure reasons and columns.

`project` splits the captured text and calls the existing private projection
through a benchmark-only export. `read_page_stub` runs the complete Lisp
reader with a callback returning the captured text. Both retain the
5,000,000-word execution heap. Prelude compilation is outside timing;
`Lisp.run` setup, source analysis, execution and result projection are inside.

| Layer | Current median | Prepared-type median |
| --- | ---: | ---: |
| Lisp split/project/type, first order | 384.9 ms | 364.9 ms |
| Lisp split/project/type, reverse order | 375.0 ms | 357.0 ms |
| Complete Lisp reader, stub provider, first order | 389.7 ms | 371.1 ms |
| Complete Lisp reader, stub provider, reverse order | 378.1 ms | 362.7 ms |
| Allocated words, split/project/type | 36,197,080 | 34,622,544 |
| Allocated words, stub reader | 38,191,568 | 36,364,899 |

The native split/project/type loop takes 2.4–2.5 ms and allocates 369,804 words.
It is a lower bound on this particular valid input: it omits sandbox setup,
Lisp execution, capability semantics, and the reader's cursor/header checks.
It is not a compatible replacement or a promised end-to-end speedup.

The all-column control compares the same 2,847 rows across all 21 columns:
Lisp projection takes 2.03 seconds versus 7.2 ms for the native valid-input
reference. The prepared projection takes 1.93 seconds, but the corresponding
stub-reader series is noisy and does not show a gain. A stronger alternating
A/B check of the complete stub reader uses six measured pairs after a warm-up
pair, reversing variant order each time. Median paired time ratios are 0.959
for three columns and 0.975 for all 21: about 4.1% and 2.5% less time. One wide
pair is slightly slower. This supports a modest candidate, not a large fix.

The following is a separate fixed-response Dispatcher experiment. Each timing
sample makes 20 calls; the table divides the median by 20. It includes normal
capability admission and result handling, but no MCP process or transport.
The schema variants use the actual advertised input and output schemas.
Production validation is never disabled; omission is only a benchmark control.

| Dispatcher control | Median per call |
| --- | ---: |
| No output schema, no sinks | 1.48 ms |
| Input/output schemas, no sinks | 3.09 ms |
| Schemas and canonical event sink | 3.10 ms |
| Schemas, events, digest inspection | 5.54 ms |
| Schemas, events, full inspection | 6.16 ms |

These timings are nested costs from different harnesses, not additive pieces
of one measured replay. The stub does not emit the MCP adapter's protocol
exchange records. Inspection appends are included; final sealing/fsync is
outside per-call timing. The full-capture diagnostic uses a 200 MB inspection
ceiling so its repeated page payloads fit; this is not a production-limit change.
For the same 120 calls and 240 inspection records, sealed artifacts occupy
91,300 bytes with digest capture versus 59,639,140 bytes with full capture.
These are capability records, not the additional raw MCP protocol records.

## User namespace and effect-context controls

Each namespace experiment holds work at 1,000 calls and prepares definitions
and aliases before timing. Both columns still include per-evaluation setup.
The builtin loop uses the same memory grant and avoids closure return-type
tracking, providing a control for setup and binding-count overhead.

| Unrelated bindings | Builtin loop | User closure loop | Closure with 20 aliases |
| --- | ---: | ---: | ---: |
| 0 | 3.88 ms | 5.29 ms | 9.04 ms |
| 100 | 3.74 ms | 6.15 ms | 9.97 ms |
| 1,000 | 4.29 ms | 23.70 ms | 26.45 ms |
| 5,000 | 7.68 ms | 69.19 ms | 86.76 ms |

`Eval.Apply.update_closure_return_type/3` visits all bindings and updates every
matching closure, including aliases. An index must preserve alias updates,
rebinding, captured environments, and last observed return types across turns.
Skipping updates merely because the called closure already has that type can
miss another matching binding introduced since the previous call.

The isolated no-effect `HostContext.run_value/3` control takes about 21 ms for
100,000 callbacks versus 0.55 ms for plain callbacks. Existing prelude-count
maps of 0, 3 or 100 entries do not materially change that control. This is not
a measurement of callbacks that create effects or nested interpreter execution.
A further control nests the same no-effect callbacks inside an outer capture:
100,000 calls take about 51–52 ms with any of those count-map sizes. There is
measurable wrapper cost, but these controls do not justify bypassing effect
capture or assign its exact share inside the real interpreter.

## Full traversal, fold and replay

The prototype folds rows through a scalar counter, carrying one page, a cursor
and the counter. The manual reduction uses the same per-row increment; the
count-only scan instead adds each page's row count. All cases finish with
138,236 rows and 49 pages. There are no LLM calls or retry passes in these scans.

| Fixed work | Current | Prepared types |
| --- | ---: | ---: |
| Count-only scan | 20.12 s | 18.44 s |
| Manual per-row reduction | 19.33 s | 18.23 s |
| Prelude row-fold prototype | 22.33 s | 21.57 s |

These are medians of two warm scans after one first evaluation. The current
manual reduction being faster than its count-only control shows the timing
noise; do not treat small differences as exact speedups. The small-page Kernel
runs were noisier still and did not establish an improvement. The isolated
page runs, reverse order and allocation profiles provide the stronger evidence
for the modest type-preparation gain.

The prepared-type variant completed full replays in 90.47 and 89.71 seconds,
with all 11 recorded model responses and the same agreed `B. BE` result and
reviewer caveat. The second run replaced the CSV with identical bytes on a new
inode. A subsequent EOF-byte mutation was rejected with `explicit_failure`.
The deliberately recorded retain-all attempt still hits the heap limit before
the recorded correction succeeds. No prompt or fixture response was changed,
and analysis, recheck and review remain independent.

The earlier current-code replay median was 95.89 seconds. That comparison is
across measurement sessions; it is supporting evidence, not a paired replay
speedup estimate. This report keeps type preparation as a small candidate and
does not promote the benchmark fold to a production API.

## Larger inputs and heap

The synthetic generator streams rows directly to disk. It uses the same
21-column header, valid conversions, deterministic varied values, and no
whole-table collection. Tests select either three columns or all 21 and fold
into a scalar count. Each projection has its own session to avoid consuming
another experiment's mission-call allowance. Session opening is reported
separately. The mission heap remains 5,000,000 words and other mission limits
remain unchanged; only the filesystem's explicit hash-byte ceiling is raised
when necessary to admit the larger file.

| Rows | Source bytes | Pages | Three columns, warm | All 21 columns, warm |
| --- | ---: | ---: | ---: | ---: |
| 20,000 | 5,588,717 | 12 | 3.44 s | 15.79 s |
| 80,000 | 22,354,117 | 46 | 15.27 s | 64.82 s |
| 320,000 | 89,415,717 | 184 | 57.12 s | 293.57 s |

Each cell has one first and one warm traversal, retained individually in the
raw data. The largest first traversals take 54.77 seconds (three columns) and
282.06 seconds (all columns). This is a scaling probe, not a stable portable
latency baseline. All expected rows/pages were consumed and the capability
collector independently reports the same number of reads.

The largest warm scans spend 13.50 and 13.32 seconds respectively inside
`workspace.read`. Selecting more columns does not reduce transferred input;
most of the extra time is downstream processing. Full-width GC reclaimed-word
counts are 1.454, 5.815 and 23.262 billion: nearly exact fourfold growth at each
fourfold input increase. Reclaimed volume is allocation pressure, not live
memory or a leak. Long-run wall times vary more than this work measure.

| Input rows | Sampled peak, three columns | Sampled peak, 21 columns |
| --- | ---: | ---: |
| 20,000 | 225,551 words | 955,195 words |
| 320,000 | 364,951 words | 955,504 words |

These are separate instrumented runs. The sampler observes armed
5,000,000-word sandboxes and takes the maximum individual process's
`total_heap_size`, including baseline/capacity and excluding off-heap storage.
It can miss short peaks and does not measure the whole runtime's live memory.
The full-width peak is nearly unchanged at 16 times as many rows. The narrow
peak increases, so this is not proof of constant total run memory: call ledgers,
canonical events, and GC capacity also matter and remain subject to their own
limits. No parsed table is retained between pages. The largest server hash
ceiling is explicitly 89,415,718 bytes; mission limits are unchanged.

## Trace collections

The generator creates canonical traces and private inspection through real
command runs. Queries use `mix ptc repl --profile private-run-analysis-v2
--private-unattended`; no benchmark parses or rewrites raw trace records.
Each query reduces pages of at most 50 run summaries to a count. It retains
24 bytes of user memory and 579 bytes of total continuation after three
queries, independent of cohort size.

| Runs | Canonical trace bytes | Session open | Warm complete query | Process peak RSS |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1,824 | 1.93 s | 1 ms | 119 MB |
| 10 | 18,233 | 2.06 s | 2 ms | 121 MB |
| 100 | 182,485 | 3.01 s | 6 ms | 136 MB |
| 1,000 | 1,826,787 | 5.40 s | 859 ms / 20 pages | 370 MB |
| 1,025 | 1,872,512 | refused | — | — |

Each run also has a 994-byte inspection artifact. Session-open timings include
Mix/VM startup through the CLI's `session-started` message. Warm query timings
are the CLI's evaluation durations, after the first query. RSS is the maximum
for the complete fresh CLI process, measured by macOS `/usr/bin/time -l`; it
includes VM/code, capture owners and allocator capacity, not just live data or
the analysis heap. Values are medians from three fresh CLI sessions.

The 1,025-file cohort hits the 1,024-trace-file admission ceiling. Selecting a
known run with `--run` works in both the 1,000- and 1,025-file directories:
opening is about 1.6 seconds, warm queries 1–2 ms, peak process RSS 121 MB.
This does not establish unlimited directory scalability; other admission
limits still apply.

The selected change replaces `Enum.sort/2`'s repeated timestamp conversions
with `Enum.sort_by/3`, retaining the same descending instant and run-ID keys.
The query harness was rerun against the exact same immutable cohorts:

| Runs | Warm complete query before | After sort-key change |
| --- | ---: | ---: |
| 1 | 1 ms | 1 ms |
| 10 | 2 ms | 2 ms |
| 100 | 6 ms | 5 ms |
| 1,000 | 859 ms | 234.5 ms |

The 1,000-run query takes about 73% less time. Its session opening remains
5.53 seconds; whole-process peak RSS is 282 MB in these samples. The 1,025-file
cohort is still refused. This changes query computation, not capture policy,
admission ceilings, cursor identity, or retained evidence. A directory-query
regression checks microsecond ordering, equivalent timestamp spellings and
run-ID ties across page boundaries; trace and snapshot suites pass before and
after the change.

The source still explains a repeated-work candidate: `TraceSnapshot.snapshot_query/5`
passes the captured events to `TraceLog.query_loaded/8`; `:list_runs` calls
`runs/2`, which groups every event, builds every run's metadata, and sorts all
runs before pagination, on every page. Source-kind validation also walks the
events. With fixed page size, increasing the cohort increases both page count
and per-page work. The observed curve is consistent with that mechanism,
although this experiment does not assign exact time shares to its individual
steps.

A concrete solution to test next is a precomputed, sorted run-summary index in
the immutable snapshot owner, charged to retained-memory limits. Queries should
reuse that index and preserve public/private projections, all filters, cursor
binding to the immutable snapshot, isolated-run reporting and bounded outputs.
Selected-run capture is the tested workaround when the run ID is known.
The index targets repeated query work; it does not by itself fix capture-time
RSS or raise admission ceilings. For broad archives, separately investigate
metadata-only cohort admission with bounded on-demand evidence loading, or
partition archives while preserving immutable captures and source checks.

## Caching decision

Do not start with a raw-page cache. The same captured raw response still takes
hundreds of milliseconds through the Lisp reader, and the filesystem server
already reuses content digests for unchanged physical file identity. A cache
of parsed pages could avoid interpretation, but would add authorization scope,
content/projection/parser-version identity, eviction, and mutation-check work.
The experiments support first reducing repeated interpreted work and building
a trace-summary index, not adding a whole-table cache to a mission.

A bounded LRU also needs a useful hit rate. The retained hit-count model makes
three identical sequential passes with no mutations or authorization changes.
A 16-page cache misses all 147 reads of the 49-page input; a 49-page cache
hits 98 of them. At 184 pages per pass, that same 49-page cache misses all 552
reads. Different projections can lower reuse further. This is an optimistic
page-ID model, not a measured cache or a byte-budget estimate.

The [MCP caching specification](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching)
still lists discovery/list operations and `resources/read`, not this
`tools/call` path. HTTP ETags are not an existing stdio tool switch. Any cache
must preserve the tested identical-file and changed-byte behavior and must
not reuse results across authorization contexts.

## Reproduction and limitations

Commands are in [the benchmark README](../../../bench/README.md). Timing runs
are sequential and uninstrumented; `tprof` allocation and heap sampling run
separately. Treat VM-wide reclaimed GC words as allocation-pressure evidence,
not exact allocated/live words. The sampler's `total_heap_size` includes
baseline and capacity, excludes off-heap binaries and may miss short peaks.

The native parser and prepared-type functions are experimental controls for
the pinned unquoted input format. They are not a general CSV API. The row fold
only stays bounded with the tested compact accumulator. The first isolated
harness attempt granted thousands of pre-split line slices and hit setup's
160 MB ceiling; the retained harness grants one captured text page and splits
inside the evaluator, matching the real read path more closely.

## Validation

The focused trace-log and snapshot suites pass before and after the sort-key
change. The retained original page and heap benchmark entry points also pass
after extracting shared helpers. Page variants compare complete rows and
conversion failures; traversal and replay assertions check results and limits.
The synthetic scans, heap profiles and bounded CLI cohort queries all completed
with their expected success or admission-refusal outcomes. The full `mix nightly` suite also passed, including identical-file replacement,
changed-byte rejection, reviewer correction/exhaustion and downstream startup.

PR review found and corrected two harness defects: the kernel page heap probe
assumed a scan-summary map instead of its integer count, and the trace probe
accepted arbitrary failures at 1,025 runs. The latter now requires the specific
unselected admission refusal and success for selected runs. Boundary regression
checks cover false-positive trace outcomes; the heap command reproduced the
integer-access failure before correction. These fixes do not change the raw
measurements above.
