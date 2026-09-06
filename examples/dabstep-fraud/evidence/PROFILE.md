# Repeated CSV scanning profile

The original investigation below is retained as its historical baseline.
The measured runtime fix is recorded in
[Optimization measurements for #1845](#optimization-measurements-for-1845).

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

## Optimization measurements for #1845

Measured on 2026-09-06 against merged baseline `0ea718e40` (PR #1846), on
Apple ARM64, Elixir 1.20.2, OTP 29.0.3 / ERTS 17.0.3, 10 online schedulers,
and 8-byte words. The same pinned CSV, MCP 0.3.0, replay fixture, prompts,
and 5,000,000-word mission heap were used throughout. These are local
diagnostics, not portable timing gates. Individual samples and provenance
are retained in [PERFORMANCE.json](PERFORMANCE.json).

### Selected changes

1. `Prelude.Compiler` tags the private namespace's top-level closures once
   when capturing it. Direct and higher-order prelude calls reuse that
   immutable environment. Public export binding removes the internal marker;
   private environments still never travel in public closure metadata.
2. `Eval.Apply` skips return-type updates when the call restores an earlier
   namespace: those updates were immediately discarded. Calls whose namespace
   survives still use the original tracking, including all matching aliases
   and updates across turns. No closure identity index or new cache is needed.
3. Direct closure calls change only the caller context's namespace, lexical
   environment, and locals. Previously they allocated a default child context
   and then restored every inherited field. The simpler path preserves the
   same effects, heap limits, deadlines, and worker budgets.

The second allocation profile identified context construction as the next
large allocation source, motivating change 3. Higher-order callback context
construction retains its separate semantics.

### Measurements

Wall-time runs use normal execution with capability telemetry and GC counters,
without function tracing. Medians exclude the cold page/scan evaluation;
replays each create fresh providers and include project loading and recording.

| Workload | Before | Final | Reduction |
| --- | ---: | ---: | ---: |
| Warm 2,847-row page, five samples | 880.8 ms | 431.2 ms | 51.0% |
| Count-only 138,236-row scan, two warm samples | 51.0 s | 18.7 s | 63.4% |
| Complete replay, two samples | 138.0 s | 95.9 s | 30.5% |
| Reclaimed heap words per warm page, median | 89.10 million | 37.08 million | 58.4% |
| Allocated words in separate page/open/close profile | 105.10 million | 47.62 million | 54.7% |

The staged warm-page medians were 635.0 ms with namespace preparation alone,
513.1 ms after also skipping discarded return-type updates, and 431.2 ms
with direct-context inheritance. These are sequential experiments; do not
interpret the differences as portable additive component costs. A later
process loading the original three runtime modules still took 946–1,068 ms
per warm page, supporting the direction of the result despite timing noise.

Every full scan returned exactly 138,236 rows in 49 reads. Both final replays
returned the same complete result, including the reviewer caveat, and consumed
all 11 recorded model responses. Baseline replays made 172 filesystem calls;
final replays made 169. The retain-all attempt's heap-kill point can vary with
GC, changing how many pages it reaches before failure. All three independent
complete traversals and the recorded correction remain. The fixed-work scan
comparison establishes cheaper processing separately from this variation.

Direct MCP scans took 3.96 s including `npx`/server startup, then 1.91 and
1.92 s in the same server. They transferred 23.58 MB of source as about
48.49 MB of protocol JSON in 49 calls. Replay capability time was 14.2 s
before and 15.1–15.4 s after; it did not decrease with the runtime speedup.
Capability time is nested inside wall time, not an additional duration.

The page allocation profile's `tag_internal/2` calls fell from 827,186 to
218, all remaining calls belonging to preparation. `new_child/4` calls fell
from 48,657 to 11,631. The sampled maximum sandbox `total_heap_size` for a
scan was essentially unchanged: 364,845 versus 364,949 words. Sampling every
2 ms misses short peaks, includes baseline/capacity, and excludes off-heap
binaries; it does not establish a lower charged memory requirement. GC
reclaimed words are VM-wide pressure diagnostics, not exact allocations.

### Reproduction and remaining work

From the repository root after preparing the example data:

```console
python3 bench/dabstep_mcp.py
mix run bench/dabstep.exs --mode page --samples 5
mix run bench/dabstep.exs --mode scan --samples 2
mix run bench/dabstep.exs --mode replay --samples 2
mix run bench/dabstep.exs --mode page --profile memory
mix run bench/dabstep.exs --mode scan --profile heap
```

The profiling modes create and close their session inside the profiling
callback to respect ownership. Their measurements include preparation;
unprofiled runs report session opening separately. This separation follows
OTP's [profiling guidance](https://www.erlang.org/doc/system/profiling.html)
and [`tprof`'s allocation and tracing caveats](https://www.erlang.org/docs/29/apps/tools/tprof.html).

### Prioritized follow-up investigations

The subsequent [experiment report](FOLLOWUP.md) measures these candidates,
including larger inputs and bounded trace navigation.

These are experiments, not promised speedups. The remaining 18.7-second
count-only traversal versus 1.9-second direct MCP traversal identifies a
combined processing cost; it does not isolate any one layer. Continue tracking
the broader investigation in #1845.

1. **Prepare column types per page.** `payments.clj` already prepares column
   positions once, but `typed-cell` calls type-set helpers for every cell.
   Extend each selector with its conversion kind once per page. Compare the
   same projections and rows, including empty cells and malformed values,
   using warm-page allocation and timing measurements. The repeated work is
   known from source; its remaining wall-time share is unmeasured.
2. **Separate parsing, dispatch, validation, and recording.** Replay the same
   captured page through a controlled benchmark ladder: split/project/type
   alone, Lisp helper execution, then the full capability path. Measure
   effect-context handling and inspection separately, keeping normal
   validation and capture enabled in production. The host already uses
   `digest_results`, so simply selecting digest capture is not a new fix.
   Use unprofiled timings to validate anything suggested by profiler counts.
3. **Measure ordinary user return-type scans.** The surviving-namespace path
   still scans all bindings. Hold call count fixed while varying the number
   of user bindings and aliases. If material, test an index or binding-aware
   update while preserving all alias updates, rebinding, closures, and last
   observed return types across turns. This cost remains in source but was
   not isolated by the prelude-heavy page benchmark.
4. **Evaluate a bounded streaming fold.** Keep one page and a compact
   accumulator to avoid retain-all failures and pagination mistakes. Measure
   fixed-work CPU separately from retries/read calls saved. Preserve all
   three independent analyses; a fold is chiefly a reliability and memory
   improvement until per-row savings are demonstrated.
5. **Test scaling before introducing a parsed cache.** Use larger synthetic
   inputs and wider projections with the mission heap unchanged and explicit
   bounded server hashing ceilings. Page through growing trace cohorts with
   compact summaries. Measure heap peaks, throughput, and recording growth;
   do not load a whole dataset or trace archive into the analysis heap.

This change addresses the measured runtime bottleneck; it does not complete
every investigation checkbox in #1845.

Raw/parsed-page caching was deferred: the example already uses digest-only
inspection, and reducing filesystem time cannot explain the measured gain.
A parsed cache would need content identity, projection/parser-version keys,
authorization scoping, eviction, and preserved mutation checks. The
[MCP caching operations](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching)
do not include this `tools/call` path. No cache, larger heap, changed prompts,
or removal of an independent measurement was necessary for the selected fix.

### Validation

The focused prelude and function suite passed, including public/private
closure authority and visibility, return contracts, aliases across turns,
and repeated use of immutable namespace state. The complete core CI gate
(`scripts/ci/core-tests.sh`, with its 300-case property setting),
`mix precommit`, and `mix docs --warnings-as-errors` passed. The benchmark
also completed two fresh-provider replays with the unchanged recording.
The complete `mix nightly` suite passed, including identical-file replacement,
changed-byte rejection, all three seeded reviewer regressions, reviewer
correction/exhaustion, and downstream-project startup.
