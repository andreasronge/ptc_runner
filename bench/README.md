# Runtime performance benchmarks

Micro-benchmarks and profiling for the PtcRunner runtime — distinct from
the LLM/token-cost benchmarks in `demo/` and `mcp_server/bench/`.

Focused on the cost of creating and running many **short** PTC-Lisp
programs, and how that cost scales under concurrency (the basis for
many concurrent multi-turn sessions).

## Scripts

| Script | What it measures | Tool |
|---|---|---|
| `lisp_throughput.exs` | Per-program latency: parse / analyze / full run; per-archetype; latency under `parallel:` load | Benchee |
| `lisp_profile.exs` | Function-level call_time + call_count, aggregated across the per-run sandbox processes | OTP `:tprof` |
| `lisp_concurrency.exs` | Aggregate throughput vs concurrency; scheduler microstate; GC pressure | `:msacc` + `:erlang.statistics` |

## Running

```bash
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
