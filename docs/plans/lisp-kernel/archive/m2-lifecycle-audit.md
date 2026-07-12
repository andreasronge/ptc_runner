# M2 lifecycle launch audit

Date: 2026-07-10

This audit closes the runtime/lifecycle prerequisites for the preregistered M2
Tier-2 paired smoke. It does not record an M2 outcome.

## Runtime edge policy

- Kernel continuation memory is owned by `PtcRunner.Kernel.StateHandle`, a
  per-run GenServer with an unforgeable token and an owner monitor.
- Checkout is atomic and issues a caller-monitored, per-checkout lease. A
  second checkout receives `:busy`; foreign or expired leases cannot release
  or overwrite the checked-out value, and holder death abandons the lease.
- Checkin revalidates the retained-memory byte cap. Stale tokens, stopped
  handles, and owner-dead handles fail as `:stale_handle`.
- Kernel run cleanup explicitly stops the handle; owner death independently
  terminates it through the monitor.
- Every inner sandbox runs with `link: true`, so an outer sandbox timeout or
  kill promptly tears down blocked inner work.
- The outer policy loop permits at most two parallel workers so the existing
  adversarial `pmap` test can prove simultaneous `eval-program` calls fail
  closed. Inner model-authored evaluation permits one parallel worker. Worker
  heaps are pinned to the corresponding outer/inner sandbox heap cap.
- LLM/eval correlation is serialized by the turn recorder's atomic
  `Agent.get_and_update/2`; continuation memory is serialized by StateHandle.
- Journal and tool-cache state are deliberately not continued between kernel
  inner turns. M2 continuation consists only of native PTC-Lisp definitions;
  each inner call receives fresh journal/tool-cache state.

## Per-run owner inventory

| Resource | Owner/lifetime | Cleanup/evidence |
| --- | --- | --- |
| StateHandle GenServer | One kernel run | Explicit stop plus caller monitor |
| Turn-recorder Agent | One kernel run | Linked and stopped in `after` |
| Eval event/prompt Agents | One evaluation case | Stopped in nested `after` blocks |
| Trace collector | One traced case | `TraceLog.with_trace/2` stop; monitored in soak |
| Parallel workers/slot budget | One Lisp evaluation | Fixed heap, bounded slots, blocking drain |
| RuntimeCallable process state | One invocation | Existing cleanup assertions after calls |
| TraceContext process dictionary | Dynamic trace scope | Empty collector/sink assertions after every soak cell |
| Prelude compiled cache | VM-wide immutable cache | Content-addressed `persistent_term`; no per-run growth |
| Req/Finch pools | Application-wide | Not created per kernel run; prior M1 live 5/5 exercised the same registry/provider path |

No per-run ref-counted binary holder, HTTP pool, global async queue, or atomics
slot is created by the kernel. Trace collectors own their file queue; pmap owns
its bounded worker registry and slot budget.

## Recorded verification

Command:

```console
PTC_SOAK_ITERATIONS=1000 mix test test/soak/kernel_soak_test.exs --include soak
```

Result: 2 tests, 0 failures.

- Untraced: 1,000 measured runs; process count 188 → 188, total memory
  98.33MB → 98.38MB, binary memory 8.96MB → 8.96MB, and reductions
  87,759,842 → 92,895,667 (5,135,825 total; about 5,136/run).
- Traced: 100 measured runs and 100 canonical kernel turns; process count
  188 → 188, total memory 98.61MB → 98.68MB, binary memory stable at
  8.97MB, and reductions 87,529,068 → 88,807,212 (1,278,144 total; about
  12,781/run).
- Aggregate and maximum per-process mailbox lengths were both 0 before and
  after each measured phase.
- The application-wide `Req.Finch` pool retained the same live PID and its
  mailbox stayed within one message of baseline. The mock soak intentionally
  made no HTTP requests; live provider behavior remains outside this gate.
- Trace write errors/drops/unexpected turns: zero.
- Collector processes terminated and TraceContext collector/sink lists were
  empty after every run.
- Atom growth was within the registered fixed-init/per-iteration budget.

Focused StateHandle and kernel tests additionally prove owner/lease-monitor
cleanup, run-end invalidation, stale-token and stale-lease rejection, byte-cap
enforcement, callable continuation, and fail-closed concurrent eval behavior.

## Launch decision

R21, R22, S11, and S12 are satisfied for the sequential preregistered M2
paired smoke. This does not authorize parallel experiment cells, widened live
soaks, M3 claims, or changes to the frozen M2 command.
