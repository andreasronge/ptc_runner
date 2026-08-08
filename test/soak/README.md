# Memory soak tests

Long-running tests that exercise PtcRunner runtime allocation and assert that
memory and process state stay flat. They are excluded from `mix test` by
default; opt in with `--only soak`.

## Run

```bash
mix soak

# Crank iteration count for real soak runs
PTC_SOAK_ITERATIONS=10000 mix soak
```

`mix soak` is an alias for `mix test --only soak`. The scheduled `Soak`
workflow (`.github/workflows/soak.yml`) runs it weekly, and on manual dispatch,
at `PTC_SOAK_ITERATIONS=3000`. It is deliberately not a per-PR gate: the suite
is long-running and its signal is a trend across runs.

## Tests

| File | Investigates |
| --- | --- |
| `closure_capture_soak_test.exs` | Host-process accumulation across `Lisp.run/2` calls and refc-binary pinning by returned closures |
| `atom_leak_soak_test.exs` | Parser atom interning on novel variable, keyword, and namespace-symbol names |
| `prelude_compile_atom_leak_soak_test.exs` | Component compilation atom interning on novel namespaces, exports, helpers, and keywords |

## Tunables (env vars)

| Var                       | Default | Purpose                          |
|---------------------------|---------|----------------------------------|
| `PTC_SOAK_ITERATIONS`     | 100     | Loop count per soak test         |
| `PTC_SOAK_WARMUP`         | 10      | Warmup iters (not measured)      |
| `PTC_SOAK_TOLERANCE_PCT`  | 20      | Allowed `:erlang.memory` growth  |

## Interpreting failures

  - **`:binary` grew** — refc-binary leak. Top-by-memory snapshot in
    the failure message points at the suspect process. Confirm with
    `:recon.bin_leak(20)` from IEx.
  - **Atom growth rate flagged** — `String.to_atom/1` on user input
    somewhere in the per-iter path. Atoms never GC.
  - **`procs` grew** — orphaned GenServer / Task. Check `Process.list/0`
    for stragglers (Session pids that didn't terminate, etc.).

## Interactive investigation

`:recon` is a dev/test dep — use from IEx:

```elixir
:recon.proc_count(:memory, 10)            # top 10 by memory
:recon.proc_count(:message_queue_len, 10) # mailbox backlog
:recon.bin_leak(20)                       # force GC, report reclaim
:recon_alloc.memory(:allocated_types)     # allocator breakdown
```

The harness module `PtcRunner.TestSupport.MemorySoak` (and its
MCP-side mirror) exposes `snapshot/0`, `measure/3`, `assert_flat!/4`,
`assert_atoms_per_iter!/4`, `assert_procs_stable!/3`. See its
`@moduledoc` for the full API.
