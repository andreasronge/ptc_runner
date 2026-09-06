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
