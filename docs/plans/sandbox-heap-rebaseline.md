# Sandbox Heap Re-baseline — grant data must not consume the program's budget

**Status:** draft spec (2026-06-11), from the F3 investigation in
[`m1-m2-bench-setup.md`](m1-m2-bench-setup.md). Blocks M2 (the `obs/` prelude
will cache fetched data in session memory — exactly the pattern the current
accounting punishes).

## Problem

The sandbox enforces `:max_heap` via the BEAM `max_heap_size` process flag
with `kill: true, include_shared_binaries: true`
(`lib/ptc_runner/sandbox.ex`). The flag is set at spawn, so everything the
spawned process ever holds counts against the program's budget — including
the host-provided environment copied in at spawn: `Context.new(ctx, memory,
normalized_tools, turn_history)` plus the prelude. The program is billed for
data the host chose to give it and that it cannot free.

Measured (2026-06-11, M1 bench logs; `(+ 1 2)` is the probe program):

| granted environment | min `max_heap` for `(+ 1 2)` |
|---|---|
| none | ≤ 0.4 MB |
| `Introspection.tools(jsonl_path)` | ≤ 0.4 MB |
| closures over 2 MB of small-string rows | ≤ 0.4 MB **or killed — varies by run** |
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
   program+environment is **nondeterministic across runs** (observed both
   passing and killed at the same limit).
2. **The counted size is the entire heap at GC time** — all generations,
   stack, and "any extra memory that the garbage collector needs during
   collection" (OTP docs). Transient garbage and GC to-space count; live
   data size does not predict the bill. OTP's own guidance: heap size "is
   quite hard to predict … first run it in production with `kill` set to
   `false`". The flag is designed as a crash guard, not a precise quota.
3. **`include_shared_binaries` bills referenced refc binaries** (>64-byte
   binaries, e.g. JSON-decoded strings): "the size of a shared binary is
   included by all processes that are referring it", and possibly more than
   once per process via the binary vheap, which only re-tallies at GC.
   Measured amplification: ~2.5–5× the binary payload. Refc-binary
   allocation also *reliably triggers* GC (binary vheap threshold ≈ 360 KB),
   which is why binary-bearing grants kill deterministically while plain
   heap data flips.

The flag itself is the right enforcement primitive (fail-closed, kernel-side,
per `feedback`: limits fail closed with a stable error). What is wrong is
**what gets billed**: host-granted data and per-eval session-memory copies
land inside the budget meant for program allocations.

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

## Alternatives considered

| option | verdict |
|---|---|
| **A. Raise the default** | Rejected alone. The overhead scales with granted data, so any constant dies on a bigger log/memory; mislabels the limit's meaning; keeps nondeterminism. |
| **B. Teach agents / document idioms** | Rejected. Failing programs were innocent (~1–3 MB); the boundary is invisible and nondeterministic; conflicts with the prelude value hypothesis (natural code should work). |
| **C. Drop `include_shared_binaries`** | Rejected. It exists so binary-heavy programs can't dodge the budget off-heap (the anti-cheat is legitimate). |
| **D. persistent_term-backed grants** | Works (measured zero-cost) but global namespace + erase cost (global scan) + lifecycle management. Keep as fallback for very large static grants; not the general fix. |
| **E. Host-side execution for all tools** (protocol refactor) | Too big for now; upstream-tool closures capture tiny envs anyway. Revisit only if P2-style proxying proves broadly needed. |
| **F. Post-setup re-baseline** (this spec, P1) | Fixes the *class*: grants, session memory, ctx data all excluded from the program's bill; preserves fail-closed kills for program-acquired memory. |

## Plan

### P1 — re-baseline in `PtcRunner.Sandbox` (core)

In the spawned sandbox fun, before `eval_fn`:

1. Spawn with a **setup ceiling** instead of the final budget:
   `setup_max_heap` (new option; default e.g. `8 × max_heap`, configurable) —
   keeps a hard fail-closed bound while the host environment is copied in.
2. After the env copy (top of the spawned fun): `:erlang.garbage_collect()`,
   then measure
   `baseline = total_heap_size + ceil(binary_refs_bytes / word_size)` where
   `binary_refs_bytes` sums `Process.info(self(), :binary)` sizes.
3. `Process.flag(:max_heap_size, %{size: baseline + max_heap, kill: true,
   error_logger: false, include_shared_binaries: true})`.

Semantics change to document: **`:max_heap` becomes the program's allocation
headroom above the granted environment**, not the process's absolute size.
Per OTP, headroom is consumed by transient garbage and GC workspace, not
just live data — the docs must say so.

Notes:

- Prelude attachment runs inside `eval_fn` (after re-baseline), so prelude
  top-level allocations bill the program. Acceptable for v1 (curated
  preludes are small); if M2 preludes get heavy, add a post-attach re-flag
  hook inside `Eval` as a follow-up.
- pmap/pcalls workers (`:worker_max_heap`) copy closures/env the same way —
  apply the same re-baseline in the worker prologue.
- `:max_heap` validation (`@min_max_heap_words`, MCP `program_memory_limit`)
  keeps meaning "program budget"; no MCP config change needed.

**Tests (write the failing ones first):**

- Regression reproducing F3: grant tools closing over ≥ 1 MB of >64-byte
  binaries; `(+ 1 2)` and a `group-by`+`mapv` analysis pass at the default
  limit.
- `memory:` carrying ≥ 1 MB of refc binaries: trivial program passes at
  default.
- Fail-closed preserved: a program allocating beyond `max_heap` (e.g. big
  `range`→`vec`) is still killed, with the stable `:memory_exceeded` error.
- Worker: a pmap worker allocating beyond `worker_max_heap` is still killed;
  a worker under a heavy grant baseline is not.

### P2 — introspection sources stop hauling the log into the sandbox

Even after P1, a `log/` closure that *executes in the sandbox* re-loads or
copies the whole event list per call (path sources `Analyzer.load` inside
the sandbox; `MemorySink.events(pid)` copies every event), billing the
program transiently for the full log. Fine for 100 KB logs, not for real
retention.

- `Introspection.tools/1` closures become thin proxies: a holder process
  owns the events and computes the **projections** (`sessions`, `turns`,
  `programs`, `tool_calls`) host-side; only results cross into the sandbox.
  For memory-sink sources the sink itself grows projection calls; for
  path/list sources `tools/1` starts (or accepts) a holder.
- Bounded outputs stay as-is (D4 read-only, sample limits).
- Test: tool results' size, not the log's size, determines sandbox cost — a
  synthetic 50 MB event list with a 10 MB default budget still answers
  `(count (log/sessions))`.

### P3 — diagnostics

- `{:error, {:memory_exceeded, bytes}}` grows to carry
  `%{limit, baseline, budget}` (bytes) so a kill message can say
  *"program budget 10 MB, granted-environment baseline 11.6 MB"* instead of
  "heap limit exceeded". Surface in `Step.fail.details` and the turn event.
- Sandbox moduledoc: GC-time check semantics, headroom-not-live-data, the
  OTP unpredictability caveat, and the W1 (`def`-and-reuse) interaction.

Suggested split: P1 and P2 as separate PRs (different mechanisms), P3 rides
with P1.

## Open questions (for review rounds)

- `setup_max_heap` default: multiplier of `max_heap` vs absolute words; what
  should MCP pass?
- Should baseline measurement bias up (give the program slack) or down
  (strict)? Proposed: measure after a forced full GC and take the raw sum —
  simple and reproducible; revisit only if flakes appear.
- Is one re-flag (post-spawn) enough, or is the post-prelude-attach hook
  needed in v1 (depends on M2 prelude size)?
