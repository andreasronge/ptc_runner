# Runtime performance benchmarks

Micro-benchmarks and profiling for the PtcRunner PTC-Lisp runtime.

Focused on the cost of creating and running many **short** PTC-Lisp
programs, and how that cost scales under concurrency (the basis for
many concurrent multi-turn sessions).

## Scripts

| Script | What it measures | Tool |
|---|---|---|
| `mix bench.check` | Deterministic nightly/release gate for sandbox child eval reductions vs committed baseline; also prints the heap table informationally | custom Mix task |
| `mix bench.heap` / `heap_baseline.exs` | Heap cost of every embedding unit vs `baselines/heap.json`: idle floor without Mix, `Lisp.run`, `compile_bundle`, `Kernel.run`, concurrency 1..128 | custom Mix task |
| `prelude_bundle.exs` | Bundle preparation phases, composition vs aggregate recompilation, retained artifacts, 1..128-component scaling, identical/distinct preparations, and a shipped `agent.core` execution-overhead proxy | custom script |
| `dabstep.exs` / `dabstep_mcp.py` | Real CSV page processing, count-only traversal, complete recorded replay, and direct MCP traversal | custom script / OTP `:tprof` |
| `lisp_throughput.exs` | Per-program latency: parse / analyze / full run; per-archetype; latency under `parallel:` load | Benchee |
| `lisp_profile.exs` | Function-level call_time + call_count, aggregated across the per-run sandbox processes | OTP `:tprof` |
| `lisp_concurrency.exs` | Aggregate throughput vs concurrency; scheduler microstate; GC pressure | `:msacc` + `:erlang.statistics` |

## Running

```bash
mix bench.check                             # gates reductions, reports heap
mix bench.check --write-baseline --reason "accepted cause"
mix bench.heap                              # gates heap
mix run bench/heap_baseline.exs             # reports heap; --write re-records
mix run bench/prelude_bundle.exs            # PTC_PRELUDE_BENCH_SAMPLES defaults to 7
mix run bench/lisp_throughput.exs
mix run bench/lisp_profile.exs              # PROFILE_ITERS env var (default 3000)
mix run bench/lisp_concurrency.exs
```

`mix run` prunes the OTP `tools` / `runtime_tools` apps from the code
path; the scripts re-add them so `:tprof` / `:msacc` load.

## DABStep page processing

Prepare the pinned CSV with `examples/dabstep-fraud/fetch-data.sh` from the
example directory, then run these commands from the repository root:

```bash
python3 bench/dabstep_mcp.py
mix run bench/dabstep.exs --mode page --samples 5
mix run bench/dabstep.exs --mode scan --samples 2
mix run bench/dabstep.exs --mode replay --samples 2
mix run bench/dabstep.exs --mode page --profile time
mix run bench/dabstep.exs --mode page --profile memory
mix run bench/dabstep.exs --mode scan --profile heap
```

No live model credentials are needed. The heap remains 5,000,000 words.
Page/scan runs report session opening separately, then a cold evaluation and
the requested number of warm evaluations in that session. A scan must return
138,236 rows and 49 pages. Replay includes project loading, fresh providers,
recording, and the recorded corrections; it must still agree on `B. BE`.
Replay artifacts use the example's `.ptc-replay` directory.

JSON lines report wall time and capability time (nested, not additive), plus
VM-wide GC count and reclaimed words. Reclaimed words are allocation-pressure
diagnostics, not exact allocated bytes or per-mission figures. Run without
other workloads in the same VM. Compilation and VM startup precede these
timers. Direct MCP's first scan includes server startup, including `npx`;
subsequent scans share the same server. None of these are cold-disk tests.

Run profiles separately from wall-time comparisons: tracing slows execution.
Time/memory profiles include session open, evaluation and close and trace all
VM processes to include supervisor-owned workers. The heap profile samples
`total_heap_size` every 2 ms for armed 5,000,000-word sandboxes. Its maximum
includes the environment baseline and heap capacity, excludes off-heap binary
storage, and can miss short peaks; it is not the sandbox's charged memory.
See the example's `evidence/PROFILE.md` for measured findings.

## DABStep follow-up experiments

These maintainer experiments are sequential, local diagnostics. Prepare the
pinned data using the example README and run from the repository root with the
pinned toolchain (`mise exec --` may be prefixed to the commands below).

```sh
mkdir -p tmp/profiling/followup
python3 bench/dabstep_mcp.py --capture-page tmp/profiling/followup/page.json
mix run bench/dabstep_experiments.exs
DABSTEP_BENCH_REVERSE=1 mix run bench/dabstep_experiments.exs
DABSTEP_BENCH_WIDE=1 mix run bench/dabstep_experiments.exs
DABSTEP_BENCH_PAIRED=1 mix run bench/dabstep_experiments.exs
DABSTEP_BENCH_PAIRED=1 DABSTEP_BENCH_WIDE=1 mix run bench/dabstep_experiments.exs
DABSTEP_BENCH_PROFILE=1 mix run bench/dabstep_experiments.exs
mix run bench/dabstep_dispatch.exs
mix run bench/dabstep_scaling.exs --suite kernel --samples 2
mix run bench/dabstep_scaling.exs --suite replay --samples 2
mix run bench/dabstep_scaling.exs --suite scale --samples 1
DABSTEP_BENCH_HEAP=1 mix run bench/dabstep_scaling.exs --suite scale --rows 20000
DABSTEP_BENCH_HEAP=1 mix run bench/dabstep_scaling.exs --suite scale --rows 320000
mix run bench/dabstep_traces.exs
python3 bench/dabstep_trace_queries.py
python3 bench/dabstep_trace_queries.py --selected-run RUN_REF
```

The capture option saves one MCP page and its advertised schemas. Its catalog
request starts the server before the first scan; catalog opening is reported
separately and samples 1 and 2 remain warm scans. Captures and temporary example
copies stay under ignored `tmp/profiling/followup/`. No live model calls occur.

The isolated harness checks complete projected-row equality and malformed-cell
behavior, then measures namespace size and effect-context controls. `WIDE`
selects all 21 columns; `PAIRED` alternates current/prepared reader variants for
six measured pairs after a warm-up pair. The normal run also emits an LRU
hit-count model for three sequential scans; it is not a cache implementation. Allocation
profiling is separate from timing. The Dispatcher ladder uses the captured
response, schema controls, event capture and two inspection policies; it is not
a transport benchmark. `--suite replay` checks the prepared-type variant,
replaces the temporary CSV with identical bytes before its second replay, and
verifies rejection after changing an EOF byte, restoring that byte afterward.
It does not modify the shipped example or its recording.

The scaling suite streams synthetic files of 20,000, 80,000 and 320,000 rows,
selects three or all 21 columns, and checks full traversal counts. Each
projection opens a fresh session. Sample 0 is the first evaluation and positive
samples are warm; `--samples 1` means two traversals per projection. Large
full-width scans take several minutes. Defaults are two warm samples for kernel,
two repetitions for replay, and one warm sample for scaling, keeping the standard
scans within the unchanged 512-call mission budget. Heap sampling runs separately and has
the same limitations as the original DABStep heap profile above.

The trace generator creates 1,025 real command runs and copies immutable cohorts
at 1, 10, 100, 1,000 and 1,025 runs. It refuses an already generated trace fixture
rather than silently mixing cohorts. The query script reads only CLI query
responses, never raw records; each query retains a compact count and pages at
most 50 summaries. It runs three fresh CLI sessions and three queries per
session. On macOS it also records whole-process peak RSS via `/usr/bin/time -l`.
Use a run reference obtained through `analysis/runs` for the selected-run check.

The trace-query harness requires a `source_limit_exceeded` setup refusal for
the unselected 1,025-run cohort and successful queries for selected runs at
both sizes. Check these assertions with
`python3 -m unittest discover -s bench -p test_dabstep_trace_queries.py`.
Heap profiling accepts both the integer page count and scan summary results:
`DABSTEP_BENCH_HEAP=1 mix run bench/dabstep_scaling.exs --suite kernel`.

See the [follow-up report](../examples/dabstep-fraud/evidence/FOLLOWUP.md) for
results, rejected approaches, measurement caveats and the next concrete fixes.

## Notes

- Benchee's `parallel: N` reports *per-call* latency under contention —
  good for latency, misleading for aggregate throughput. Use
  `lisp_concurrency.exs` (fixed work, wall-clock) for aggregate numbers.
- Each `Lisp.run/2` spawns its own sandbox process, so `:tprof` is run
  with `report: :total` to aggregate across them.
- `mix bench.check` gates child-process eval reductions. Child memory and
  wall-clock timings stay informational: hosted runner timing noise is too large
  for a gate, and a single per-call `memory_bytes` sample cannot separate a leak
  from one-shot warmup.
- Its matrix covers raw/no-prelude evaluation, public prelude calls,
  strict-transitive prelude calls, and private-tool prelude calls. Keep those
  policy rows separate: optimizing the default path must not erase the cost or
  correctness signal for the stricter paths.
- The reductions baseline records full runtime provenance and refuses to compare
  when the Mix environment, Elixir, OTP, ERTS, emulator flavor, or word size
  differs. Architecture and scheduler details remain diagnostic because
  reductions are measured in the isolated eval child rather than as a whole-VM
  resource figure. The committed baseline and automated checks use `MIX_ENV=dev`.
  Regenerate it on an intentional BEAM-shape upgrade rather than treating the
  resulting delta as a code regression.
- Re-record `baselines/lisp_eval.json` only with `--reason`; the task requires
  and stores that written cause for every accepted change. The Nightly workflow
  catches drift daily and the Release Gate blocks a release whose reductions
  exceed the committed allowance.
- `mix bench.heap` is the gating heap entry point; `mix bench.check` prints the
  same table without failing on it. Byte metrics on a per-commit path invite the
  reflexive re-baseline that is how a gate stops meaning anything, so the split
  is deliberate: report where the metric is noisy, assert where it is stable.
- Every heap figure is a heap figure, not RSS. `baselines/heap.json` records the
  commit, OTP release, architecture, emulator flavor, and scheduler count it was
  measured on, because none of those are portable. Comparing across them is
  meaningless; re-record on the target machine instead of reading the delta.
- Repeated-churn memory growth is the soak suite's job, not `bench.check`'s. Run
  it with `mix soak` (`test/soak/`); the scheduled `Soak` workflow runs it weekly
  at `PTC_SOAK_ITERATIONS=3000`. It covers `Lisp.run/2` and
  `Prelude.Compiler.compile/1`, and — via `test/soak/lifecycle/` — the
  long-lived owner families: credential lease, REPL, provider, analysis/trace,
  and the `LocalFences` characterization.
