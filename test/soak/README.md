# Memory soak tests

Long-running tests that hammer specific PtcRunner / MCP-server
subsystems and assert memory + process state stays flat. Excluded
from `mix test` by default — opt in with `--only soak`.

## Run

```bash
# ptc_runner-side (closures, tracer)
mix test --only soak

# MCP-side (session churn, many-turn sessions, stdio)
cd mcp_server && mix test --only soak

# Crank iteration count for real soak runs
PTC_SOAK_ITERATIONS=10000 mix test --only soak

# stdio soak needs a built release first
MIX_ENV=prod mix release --overwrite       # in mcp_server/
MIX_ENV=test mix test --only soak test/soak/mcp_stdio_soak_test.exs
```

## Tests

| File                                            | Investigates |
|-------------------------------------------------|--------------|
| `closure_capture_soak_test.exs`                 | Host-process accumulation across `Lisp.run/2` calls; refc-binary pinning by returned closures |
| `tracer_soak_test.exs`                          | `PtcRunner.Tracer` bounded-list cap; refc-binaries in entry payloads |
| `mcp_server/.../session_churn_soak_test.exs`    | `Sessions.Registry` + DynamicSupervisor cleanup over many start/eval/close cycles |
| `mcp_server/.../many_turns_soak_test.exs`       | Per-turn projection state growth; atom-table growth on user-supplied var names |
| `mcp_server/.../mcp_stdio_soak_test.exs`        | Built release driven over real stdio with repeated stateless eval calls |

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
