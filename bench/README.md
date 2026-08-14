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
| `lisp_throughput.exs` | Per-program latency: parse / analyze / full run; per-archetype; latency under `parallel:` load | Benchee |
| `lisp_profile.exs` | Function-level call_time + call_count, aggregated across the per-run sandbox processes | OTP `:tprof` |
| `lisp_concurrency.exs` | Aggregate throughput vs concurrency; scheduler microstate; GC pressure | `:msacc` + `:erlang.statistics` |

## Running

```bash
mix bench.check                             # gates reductions, reports heap
mix bench.check --write-baseline --reason "accepted cause"
mix bench.heap                              # gates heap
mix run bench/heap_baseline.exs             # reports heap; --write re-records
mix run bench/lisp_throughput.exs
mix run bench/lisp_profile.exs              # PROFILE_ITERS env var (default 3000)
mix run bench/lisp_concurrency.exs
```

`mix run` prunes the OTP `tools` / `runtime_tools` apps from the code
path; the scripts re-add them so `:tprof` / `:msacc` load.

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
