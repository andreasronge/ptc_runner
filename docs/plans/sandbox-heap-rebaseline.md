# Sandbox Heap Re-baseline — grant data must not consume the program's budget

**Status:** draft spec v2 (2026-06-11; v2 after codex review round 1), from the
F3 investigation in [`m1-m2-bench-setup.md`](m1-m2-bench-setup.md). Blocks M2
(the `obs/` prelude will cache fetched data in session memory — exactly the
pattern the current accounting punishes).

## Problem

The sandbox enforces `:max_heap` via the BEAM `max_heap_size` process flag
with `kill: true, include_shared_binaries: true`
(`lib/ptc_runner/sandbox.ex`). The flag is set at spawn, so everything the
spawned process ever holds counts against the program's budget — including
the host-provided environment copied in at spawn: `Context.new(ctx, memory,
normalized_tools, turn_history)` plus the compiled prelude riding in
`eval_fn`'s captured `eval_opts`. The program is billed for data the host
chose to give it and that it cannot free.

Measured (2026-06-11, M1 bench logs; `(+ 1 2)` is the probe program):

| granted environment | min `max_heap` for `(+ 1 2)` |
|---|---|
| none | ≤ 0.4 MB |
| `Introspection.tools(jsonl_path)` | ≤ 0.4 MB |
| closures over 2 MB of small-string rows | ≤ 0.4 MB **or killed — flips between runs** |
| closures over 732 KB of >64-byte binaries | ~3.6 MB |
| closures over 1.46 MB of >64-byte binaries | ~3.6 MB |
| `Introspection.tools(events_list)` (129 KB flat, M1 turn log) | **~11.6 MB** |
| `memory:` containing 732 KB of >64-byte binaries | ~1.5 MB |

Consequences observed at the M1 gate: under the `log/` introspection grant,
*every* nontrivial analysis program sat within ~25% of the 10 MB default;
which idiom died (`vec` vs no-`vec`, map-literal vs `count`) was GC-timing
luck. The programs themselves needed only ~1–3 MB.

## Mechanism (confirmed against OTP docs + experiment)

Three properties of `max_heap_size` combine:

1. **The check runs only when a GC is triggered.** No GC → no check. A big
   on-heap environment copied at spawn may never trigger one for a trivial
   program (initial heap is sized to fit), so enforcement of the *same*
   program+environment is GC-timing-sensitive — observed both passing and
   killed at the same limit across runs.
2. **The counted size is the entire heap at GC time** — all generations,
   stack, heap-part messages, and "any extra memory that the garbage
   collector needs during collection" (OTP docs). Transient garbage and GC
   workspace count; live data size does not predict the bill. OTP's own
   guidance: heap size "is quite hard to predict … first run it in
   production with `kill` set to `false`". The flag is designed as a crash
   guard, not a precise quota.
3. **`include_shared_binaries` bills referenced refc binaries** (>64-byte
   binaries, e.g. JSON-decoded strings): "the size of a shared binary is
   included by all processes that are referring it", and possibly more than
   once per process via the binary vheap, which only re-tallies at GC.
   Measured amplification: ~2.5–5× the binary payload. Refc-binary
   allocation also *reliably triggers* GC (binary vheap threshold ≈ 360 KB),
   which is why binary-bearing grants kill consistently while plain heap
   data flips.

The flag itself is the right enforcement primitive (fail-closed, kernel-side,
stable error). What is wrong is **what gets billed**: host-granted data and
per-eval session-memory copies land inside the budget meant for program
allocations.

This directly fights the project's own goals:

- The M1 report's top waste finding (W1) tells agents to `def` fetched data
  and reuse it. Session memory is copied into every subsequent eval's
  sandbox, so following that advice inflates every later turn's baseline —
  at ~2× the refc payload (measured row above).
- The M2 `obs/` prelude is precisely a "fetch once, cache, reuse" layer. It
  runs in agent sessions at the default limit.
- The `log/` introspection grant over an in-memory event list is unusable at
  the default limit today (11.6 MB baseline for a no-op program).

## Verified building blocks

- **Re-flag works** (experiment): a process can call
  `Process.flag(:max_heap_size, ...)` on itself after setup; raising it
  post-setup works, and kill semantics still fire afterwards (verified both
  directions).
- **persistent_term grants are free** (experiment): `log/` closures reading
  events from `:persistent_term` run real prelude calls at ≤ 0.4 MB —
  literal-area reads are by reference and exempt from the accounting.

## Boundedness precondition (load-bearing)

Re-baselining is only sound because everything excluded from the program's
bill is **host-bounded elsewhere**:

- granted tools/ctx: host-authored; size is a host decision made at grant
  time;
- session memory: bounded by `max_session_memory_bytes` (MCP sessions,
  default 1 MB) / the SubAgent memory contract;
- user program source: bounded by `:max_program_bytes` (default 1 MB).

Any caller that grants unbounded data without its own cap re-opens the hole.
The spec makes this an explicit contract, and the setup ceiling (below) is
the backstop, not the primary bound.

## Alternatives considered

| option | verdict |
|---|---|
| **A. Raise the default** | Rejected alone. The overhead scales with granted data, so any constant dies on a bigger log/memory; mislabels the limit's meaning; keeps the timing-sensitivity. |
| **B. Teach agents / document idioms** | Rejected. Failing programs were innocent (~1–3 MB); the boundary is invisible and timing-dependent; conflicts with the prelude value hypothesis (natural code should work). |
| **C. Drop `include_shared_binaries`** | Rejected. It exists so binary-heavy programs can't dodge the budget off-heap (the anti-cheat is legitimate). |
| **D. persistent_term-backed grants** | Works (measured zero-cost) but: global key namespace (leak / cross-session collision risk), `put`/`erase` of large terms is globally expensive (scans all processes), and it shifts memory to a region no per-process limit sees. Acceptable only for static, deployment-lifetime grants; not for session/log data. Fallback, not the fix. |
| **E. Host-side execution for all tools** (protocol refactor) | Too big for now; upstream-tool closures capture tiny envs anyway. P2 applies the idea narrowly where it pays (introspection). |
| **F. Session-memory quota alone** | Already exists (`max_session_memory_bytes`); does not help — the bill is ~2× the payload *per eval* and stacks with grant overhead. Needed as a precondition (see above), insufficient as the fix. |
| **G. Two-phase transfer (grants first, AST after baseline)** | Closes the user-AST-in-baseline hole (see P1 caveat 1) at the cost of restructuring spawn/eval plumbing. Deferred follow-up; v1 documents and bounds the hole instead. |
| **H. Post-setup re-baseline** (this spec, P1) | Fixes the *class*: grants, session memory, ctx data excluded from the program's bill; preserves fail-closed kills for program-acquired memory. |

## Plan

### P1 — re-baseline in `PtcRunner.Sandbox` (core)

In the spawned sandbox fun, before `eval_fn`:

1. Spawn with a **setup ceiling** instead of the final budget:
   `:setup_max_heap` (new option, words). Default: `4 × max_heap` plus the
   word-equivalent of the caller's known data caps when supplied; MCP passes
   a value derived from `program_memory_limit_bytes +
   max_session_memory_bytes + grant allowance`. This stays a hard
   fail-closed bound while the host environment is copied in.
2. `:erlang.garbage_collect()`, then measure
   `baseline = total_heap_size + ceil(binary_refs_bytes / word_size)` where
   `binary_refs_bytes` sums the sizes from `Process.info(self(), :binary)`.
   The measurement itself allocates (the `:binary` info list) and
   OTP documents that info as a debug surface; we GC *before* measuring and
   accept the residual **upward** bias — it grants the program slack, never
   false kills. No measure-GC-measure loop in v1 unless tests show drift.
3. `Process.flag(:max_heap_size, %{size: baseline + max_heap, kill: true,
   error_logger: false, include_shared_binaries: true})`.
4. Send `{:baseline, baseline_words}` to the parent before eval starts (one
   small message; needed for P3 diagnostics — after a `kill: true` the child
   can report nothing).

Semantics change to document: **`:max_heap` becomes the program's allocation
headroom above the granted environment**, not the process's absolute size.
Per OTP, headroom is consumed by transient garbage and GC workspace, not
just live data — the docs must say so.

**Documented caveat — user AST is part of the baseline.** The spawned fun's
environment includes the parsed user program (`ast`/`core_ast` captured by
`eval_fn`), so program-*authored* literals land in the baseline, exempt from
`max_heap`. This is bounded by `:max_program_bytes` (default 1 MB source;
AST expansion is a small constant factor) and by the setup ceiling. V1
accepts and documents this; option G (send the AST to the sandbox only
after re-baseline, so it is billed as heap-part message data) is the clean
close if the bound ever proves too loose.

**Workers (pmap/pcalls) keep spawn-time enforcement.** `ParallelRunner`
deliberately forces an immediate GC before `fun.(item)` so an oversized
*program-created* captured environment is caught before work starts — that
guard stays; re-baselining workers would exempt exactly the data
`worker_max_heap` exists to bill. What changes: granted host data rides
along in worker closures too, so the parent passes its measured **grant
baseline** down and the worker flag becomes
`worker_max_heap + grant_baseline` (additive allowance for host data,
program-created env still billed). The documented aggregate bound becomes:

    max_parallel_workers × (worker_max_heap + grant_baseline)

**Tests (write the failing ones first):**

- Regression reproducing F3: grant tools closing over ≥ 1 MB of >64-byte
  binaries; `(+ 1 2)` and a `group-by`+`mapv` analysis pass at the default
  limit.
- `memory:` carrying ≥ 1 MB of refc binaries: trivial program passes at
  default.
- Fail-closed preserved: a program allocating beyond `max_heap` (e.g. big
  `range`→`vec`) is still killed, with the stable `:memory_exceeded` error.
- Setup ceiling: a grant larger than `:setup_max_heap` kills during setup
  with a distinguishable error (see P3).
- Worker: a pmap worker whose *program-created* captured env exceeds
  `worker_max_heap` is still killed (existing guard); a worker under a heavy
  grant baseline plus small program env is not.

### P2 — introspection sources stop hauling the log into the sandbox

Even after P1, a `log/` closure that *executes in the sandbox* re-loads or
copies the whole event list per call (path sources run `Analyzer.load`
inside the sandbox; `MemorySink.events(pid)` copies every event), billing
the program transiently for the full log. Fine for 100 KB logs, not for
real retention.

- `Introspection.tools/1` closures become thin proxies: a holder owns the
  events and computes the **projections** (`sessions`, `turns`, `programs`,
  `tool_calls`) host-side; only results cross into the sandbox (billed —
  correctly, as program inputs; results keep the existing D4 bounded-output
  limits).
- Holder shape: for memory-sink sources the sink itself grows projection
  calls (reads see a consistent snapshot of a live sink — same answer a
  copied-events read would give); for path/list sources `tools/1` starts a
  holder process owned by the grant's creator, linked/monitored so it dies
  with its owner and cannot leak past the session.
- Calls use a timeout no larger than the sandbox's remaining `:timeout`
  budget; a dead/unresponsive holder is a recoverable tool error (signal
  value), not a hang.
- Test: tool results' size, not the log's size, determines sandbox cost — a
  synthetic 50 MB event list with a 10 MB default budget still answers
  `(count (log/sessions))`.

### P3 — diagnostics

- `{:error, {:memory_exceeded, bytes}}` grows to
  `%{limit, baseline, budget}` (bytes), built from the `{:baseline, _}`
  message the child sent before eval, so a kill can say *"program budget
  10 MB, granted-environment baseline 11.6 MB"* instead of "heap limit
  exceeded". A kill with **no** baseline message received is reported as
  *killed during environment setup (ceiling N bytes)* — the two failure
  modes are distinguishable and each is actionable.
- Surface in `Step.fail.details` and the turn event.
- Sandbox moduledoc: GC-time check semantics, headroom-not-live-data, the
  OTP unpredictability caveat, the user-AST-in-baseline caveat, the
  boundedness precondition, and the W1 (`def`-and-reuse) interaction.

Suggested split: P1 (+P3, they share plumbing) and P2 as separate PRs.

## Open questions (for review rounds)

- `:setup_max_heap` derivation: is `4 × max_heap` + caller caps the right
  default shape, or should MCP/SubAgent always pass an explicit value and
  the bare default stay small (strict)?
- Worker grant allowance: pass the parent's measured `grant_baseline`
  verbatim, or re-measure per worker (costlier, tighter)?
- Is option G (two-phase AST transfer) worth doing in v1 for MCP sessions,
  where untrusted programs arrive over the wire and `max_program_bytes` is
  the only bound on baseline gaming?
