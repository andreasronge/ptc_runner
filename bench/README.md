# Runtime performance benchmarks

Micro-benchmarks and profiling for the PtcRunner PTC-Lisp runtime.

Focused on the cost of creating and running many **short** PTC-Lisp
programs, and how that cost scales under concurrency (the basis for
many concurrent multi-turn sessions).

## Scripts

| Script | What it measures | Tool |
|---|---|---|
| `mix bench.check` | Deterministic release gate for sandbox child eval reductions vs committed baseline | custom Mix task |
| `lisp_throughput.exs` | Per-program latency: parse / analyze / full run; per-archetype; latency under `parallel:` load | Benchee |
| `lisp_profile.exs` | Function-level call_time + call_count, aggregated across the per-run sandbox processes | OTP `:tprof` |
| `lisp_concurrency.exs` | Aggregate throughput vs concurrency; scheduler microstate; GC pressure | `:msacc` + `:erlang.statistics` |

## Running

```bash
mix bench.check
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
- Repeated-churn memory growth is the soak suite's job, not `bench.check`'s. Run
  it with `mix soak` (`test/soak/`); the scheduled `Soak` workflow runs it weekly
  at `PTC_SOAK_ITERATIONS=3000`. It currently covers `Lisp.run/2` and
  `Prelude.Compiler.compile/1` — not the long-lived owner lifecycles.
