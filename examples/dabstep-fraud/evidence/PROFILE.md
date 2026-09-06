# Repeated CSV scanning profile

Measured on 2026-09-06 at commit
`182037a4820501f68e30ae1700b04b31b052550b`, with `ptc-fs-mcp@0.3.0`.
These are local diagnostic measurements, not a portable benchmark baseline.
The mission heap remained 5,000,000 words (40 MB on this machine).

## Finding

The filesystem server is a minority of the replay's cost. The strongest
optimization lead is repeated Lisp helper execution and prelude environment
construction. A streaming fold can also prevent unnecessary scans caused by
retaining the whole table, but it does not automatically make each row cheaper.

| Measurement | Result |
| --- | ---: |
| Complete successful replay, including recorded corrections | 142.13 s |
| Its 171 `workspace.read` calls, summed elapsed time | 13.80 s |
| Analysis reads | 72 calls / 5.873 s |
| Recheck reads | 50 calls / 4.112 s |
| Review reads | 49 calls / 3.815 s |
| Its 11 replay-provider calls | 16 ms |
| Second complete replay, corrected telemetry collector | 134.27 s |
| Second replay's 171 `workspace.read` calls | 12.984 s |
| Direct MCP scan, first pass including server startup | 2.005 s |
| Direct MCP scan, second pass in the same server | 1.626 s |
| Direct MCP scan, third pass in the same server | 1.575 s |
| Warm `read-page`, three columns, 2,847 rows | 0.77–0.89 s |
| Full three-column `read-page` traversal, only counting rows | 36.625 s |

Capability time is nested inside evaluation time: do not add the two.
The replay used recorded model responses, so these timings exclude live model
latency. The runtime measurements include validation and recording overhead;
the direct MCP probe does not. Their difference is not a controlled estimate
of a single component's overhead. The server uses the operating system's
existing file cache; this was not a cold-disk experiment.

The CSV contains 138,236 rows and 23,581,339 bytes. Each complete pass takes
49 calls. Three passes require 147 calls; this recording makes 24 additional
calls during exploration and the failed retain-all attempt. The direct probe
received approximately 48.49 MB of JSON per pass, including the protocol's
response representations, for 23.58 MB of source data.

The count-only traversal returned all 138,236 rows over 49 pages under the
unchanged heap limit. It selected `ip_country`, `eur_amount`, and
`has_fraudulent_dispute`, retaining only the current cursor and row/page
counters between iterations. No model call or fraud aggregation was involved.
Its 36.6 seconds versus roughly 1.6–2.0 seconds for a direct server scan
reinforces that the shared page-processing/runtime path dominates.

## What the CPU profile found

An OTP `tprof` call-time profile of opening a mission REPL and reading one
three-column page completed successfully. It includes session setup and close;
it is not a parser-only profile. Instrumentation changes execution cost, so
its percentages must not be treated as uninstrumented wall-time savings.

Notable call counts were:

- 48,658 calls to `PreludeClosure.tag_internal_environment/2`.
- 827,186 calls to its per-entry `tag_internal/2` helper.
- 37,026 calls to `Eval.Apply.do_execute_closure/6`.
- 629,442 visits to the namespace entries in `update_closure_return_type/3`.
- 2,847 calls each to the Lisp CSV `split/2` and `parse_double/1` functions.

The source explains the amplification: `prelude_ns_env/2` maps and retags the
private environment when entering a prelude helper. Return-type tracking scans
the namespace again. `payments.clj` invokes several small helpers per selected
cell. Low-level splitting itself was a small portion of this profile.

## Where caching fits

The [MCP 2026-07-28 caching specification](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching)
defines `ttlMs` and `cacheScope` hints for discovery, lists, and
`resources/read`. It does not list `tools/call`, which is how this example
invokes `read_text_file`. This path uses stdio, so HTTP ETag/304 handling is
not an existing switch we can enable here.

Inspection of the released server also found an existing in-process digest
cache: unchanged physical file identity reuses its content digest. Repeated
pages do not rehash the entire file each time. The server still reads and
returns each requested page; it has no conditional-read argument on this tool.

Even eliminating all measured `workspace.read` time would save only about
9.7% of this replay's wall time. Caching raw responses would still leave Lisp
projection and typing work. Reusing parsed pages could address that work, but
requires a bounded host-owned cache, content identity, projection and parser
version keys, authorization scoping, eviction, and preserved mutation checks.
Keeping all parsed rows in the mission heap repeats the failure already
captured by this recording.

## Recommended order

1. Benchmark eliminating repeated prelude environment tagging and namespace
   scans. Preserve private-helper visibility and return-type behavior. The
   profile identifies a candidate; it does not establish a speedup yet.
2. Add a reusable bounded streaming fold if we want to reduce generated
   pagination mistakes and retain-all retries. Keep one page and a compact
   accumulator. Independent analysis and review would still scan separately.
3. Measure simpler per-page column/type preparation in `payments.clj` after
   the runtime overhead is understood.
4. Consider bounded parsed-page caching only if those measurements justify
   its added state and invalidation complexity. ETags alone would address
   transfer, not the current dominant processing cost.

The README could explain that `read-page` already centralizes CSV parsing,
that independent checks intentionally repeat traversal, and that collecting
all rows exceeds the intended memory model. Performance expectations should
separate replay execution from live model latency. No optimization or README
behavior change was made as part of this profiling pass.

## Method and friction

The replay was run with `Kernel.CommandEngine.dispatch/1` against
`ptc-project.replay.json`, using `inputs/luna.json`. Run
`cmd-00t65f7pangj7711qjksb1vds0` completed with exit status 0. Capability totals
were independently obtained through `private-run-analysis-v2`, selecting that
run and reducing `activity` pages of 100 events to counts and elapsed time.
No trace archive was loaded wholesale into the analysis heap.

The direct probe used one persistent Node server, the committed replay key,
the example's root and byte ceilings, and actual `tools/call` requests over
stdio. It followed every returned cursor to EOF three times, counted returned
bytes, and terminated its own server afterward. There were no live LLM calls.

Scratch reproduction programs and raw profiler output remain under ignored
`tmp/profiling/` and `/tmp/ptc-profile-*.log` in the profiling worktree.

- The first telemetry collector used ETS `bag`, which coalesced identical
  duration values. Those totals were discarded; the table was corrected to
  `duplicate_bag`, and canonical activity supplied the first run's totals.
  A second successful replay confirmed 171 reads and approximately the same
  9.7% share of elapsed time.
- `tprof.profile/2` executes its callback in another process. Passing an
  already-owned REPL session failed its ownership check. Creating and closing
  the session inside the callback produced the usable profile.
- A private-analysis aggregate using vector map keys failed JSON result
  serialization and reported `result_limit_exceeded`. String keys worked.
  The misleading diagnostic is a separate follow-up candidate; no runtime
  fix for it is included here.
