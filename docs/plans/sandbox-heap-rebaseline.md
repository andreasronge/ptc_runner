# Sandbox Heap Re-baseline — grant data must not consume the program's budget

**Status:** draft spec v3 (2026-06-11; after codex review rounds 1–2), from the
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
   `:setup_max_heap` (new option, words), a hard fail-closed bound while the
   host environment is copied in. **Concrete derivation (v1):**
   - Bare `Lisp.run/2` default: `4 × max_heap` (40 MB at the default
     budget). Rationale: covers `max_program_bytes` (1 MB source) +
     `memory:`/grants up to ~6 MB of refc payload at the measured ≤5×
     accounting amplification. Callers granting more must raise
     `:setup_max_heap` explicitly — and get the distinguishable
     setup-kill error (P3) if they don't, which is the boundedness
     precondition *enforced*, not prose.
   - MCP sessions pass an explicit value:
     `4 × max_heap + 5 × words(max_session_memory_bytes)` — both terms
     config-derived; `5×` is the measured refc amplification ceiling,
     pinned by a regression test so a BEAM accounting change moves the
     test, not production behavior.
   - This option applies to `Sandbox.execute/3` only. `run_bounded/2` is
     out of scope: there the caller's closure *is* the workload, so
     re-baselining would exempt exactly what the limit exists to bill —
     it keeps spawn-time semantics unchanged.
2. `:erlang.garbage_collect()`, then measure
   `baseline = total_heap_size + ceil(binary_refs_bytes / word_size)` where
   `binary_refs_bytes` sums the sizes from `Process.info(self(), :binary)`.
   The measurement itself allocates (the `:binary` info list) and
   OTP documents that info as a debug surface; we GC *before* measuring and
   accept the residual **upward** bias — it grants the program slack, never
   false kills. No measure-GC-measure loop in v1 unless tests show drift.
3. `Process.flag(:max_heap_size, %{size: baseline + max_heap, kill: true,
   error_logger: false, include_shared_binaries: true})`.
4. Send `{:baseline, baseline_words}` to the parent before eval starts
   (needed for P3 diagnostics — after a `kill: true` the child can report
   nothing). The parent's receive handling gains a small state update to
   consume this message alongside result/DOWN — it must not be left to sit
   unmatched in the mailbox or race the DOWN clause.

Semantics change to document: **`:max_heap` becomes the program's allocation
headroom above the granted environment**, not the process's absolute size.
Per OTP, headroom is consumed by transient garbage and GC workspace, not
just live data — the docs must say so.

**Documented caveat — the baseline is a *sandbox* baseline, not a grant
baseline.** The spawned fun's environment includes the parsed user program
(`ast`/`core_ast` captured by `eval_fn`), `eval_opts`, the compiled
prelude, and trace context — so program-*authored* literals land in the
baseline, exempt from `max_heap`. This is bounded by `:max_program_bytes`
(default 1 MB source) and by the setup ceiling. The AST expansion factor
must be **measured, not assumed**: the P1 test list includes a worst-case
literal test (deep nesting, large maps, string-heavy source at the size
cap) that pins source-bytes→baseline-words expansion. V1 accepts and
documents the hole; option G (send the AST to the sandbox only after
re-baseline, so it is billed as heap-part message data) is the clean close
if the measured bound proves too loose — and is worth prioritizing for MCP,
where untrusted programs arrive over the wire.

**Workers (pmap/pcalls) are unchanged in v1.** `ParallelRunner`
deliberately forces an immediate GC before `fun.(item)` so an oversized
*program-created* captured environment is caught before work starts — that
guard stays exactly as is, and so does the spawn-time `worker_max_heap`
flag. Re-baselining workers (or granting them an additive allowance from
the parent's measured baseline) was considered and dropped: the parent
baseline is a *sandbox* baseline (it includes user AST, `eval_fn`,
`eval_opts`, the compiled prelude, and setup noise — not just grants), so
any allowance derived from it hands program-created worker envs unearned
headroom and silently breaks the MCP invariant
`max_parallel_workers × worker_max_heap ≤ max_heap_words`
(`mcp_server/lib/ptc_runner_mcp/sandbox.ex` divides worker heap to preserve
it). **Documented v1 limitation:** a program that captures heavy granted
data into a `pmap` closure can still hit `worker_max_heap` at the old
accounting — none of the motivating workloads (introspection, `obs/`
caching) use `pmap` over grant-heavy closures, and P2 removes the heavy
grant from the introspection path anyway. Revisit with a *grant-only*
allowance if a real workload hits this; that requires separating grant
transfer from the rest of the closure env first (option G plumbing).

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
- AST expansion measurement: worst-case source at `:max_program_bytes`
  (deep nesting, big literals, string-heavy) — pins the
  source-bytes→baseline-words factor claimed in the caveat above.
- Amplification pin: the `5×` refc factor used in the MCP setup-ceiling
  formula has its own regression test (a known refc payload's measured
  baseline stays under 5× + slack), so an OTP accounting change surfaces in
  CI, not in killed sessions.
- Worker guard regression: a pmap worker whose *program-created* captured
  env exceeds `worker_max_heap` is still killed (existing behavior,
  unchanged).

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
- Holder bounds: the holder is not an unbounded escape hatch for the data
  it owns. Memory-sink sources inherit the sink's existing byte-budget
  ring buffer; path/list holders get a load cap (`:max_bytes`, refusing
  oversized logs with a recoverable error). A holder is a plain GenServer —
  one projection call at a time (natural serialization/backpressure), no
  call queue beyond the mailbox.
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

## MCP memory envelope (post-change)

With workers unchanged, MCP's existing invariant
`max_parallel_workers × worker_max_heap ≤ max_heap_words` holds as-is. The
per-eval envelope becomes:

    setup ceiling (covers baseline)  +  max_heap (program headroom)
                                     +  max_parallel_workers × worker_max_heap

with the baseline itself bounded by `max_session_memory_bytes`,
`max_program_bytes`, and the grant sizes the server config chose.
`program_memory_limit_bytes` keeps meaning "per-eval program headroom" —
the user-facing semantics MCP documents today.

## Open questions (for review rounds)

- Option G (two-phase AST transfer) in v1 for MCP, where untrusted programs
  arrive over the wire and `max_program_bytes` + the measured expansion
  factor is the only bound on baseline gaming — or wait for the AST
  expansion test to say whether the hole is material?
- Should the bare `Lisp.run/2` setup-ceiling default be strict
  (`2 × max_heap`) instead of `4 ×`, forcing callers with real grants to
  opt in explicitly? (Trade: more setup-kills for casual heavy-grant
  callers vs a tighter default envelope.)
