# Memory observability and leak detection

## Problem

Three things are true at once: the soak tests are good, nothing runs them, and
they cover the half of the runtime that was never at risk.

**Nothing runs them.** `test/test_helper.exs:17` excludes `:soak` by default.
`.github/workflows/` has zero references to soak. The only automated caller was
`mix release.smoke`, deleted in `ec5806d1` ("refactor(kernel): remove upstream
and MCP products"). Two documents still assert the gate exists:
`.claude/skills/release/SKILL.md:46` lists `mix release.smoke` as release step 3
— it no longer resolves — and `bench/README.md` claims "memory regressions are
covered by the release soak tests." A documented gate that does not run is worse
than an absent one, because it stops maintainers from looking.

The tests themselves are healthy, not rotted: `PTC_SOAK_ITERATIONS=200 mix test
--only soak` passes 7 tests in 10.1 s.

**They cover the safe half.** All three files exercise two entry points,
`Lisp.run/2` and `Prelude.Compiler.compile/1`. Both reap their sandbox process
when the call returns, so per-call leakage is bounded by construction. Nothing
*soaks* the long-lived side — those lifecycles have good single-cycle tests
(see the use-case matrix), but none is ever repeated N times with the aggregate
asserted flat. That is roughly 23 owner modules under
`lib/ptc_runner/kernel/`: session lifecycle (`ExecutionSessionOwner`,
`ReplSessionOwner`, `AnalysisSession`, `SessionTrace`), provider acquire/close
(`ProviderRegistry`, `ProviderTaskTracker`, `ProviderActivity`), the
`HostCredentialLease` and `ReplSession` ETS tables, MCP stdio port and HTTP
adapter churn, and OAuth refresh cycles.

**The oracle has a blind spot.** `MemorySoak.assert_flat!/4` reads
`:erlang.memory/0` — what the VM believes it allocated, not RSS. Allocator
carrier fragmentation, the classic "flat `:erlang.memory` while RSS climbs"
failure, passes every current assertion.

## Non-goals

- Rewriting the existing three soak files. They are correct; they get a runner
  and a wider sibling, not a rewrite.
- A production metrics backend, exporter, or dashboard. This plan emits
  measurements; consuming them is the host's business.
- Chasing allocator tuning (`+MB*` flags). Fragmentation gets *observed* here;
  acting on it needs evidence this plan is designed to produce.
- Changing any sandbox or Kernel limit default.

## Measured baseline

**Provenance.** Commit `b77c234e`; darwin/arm64; Elixir 1.20.2, Erlang/OTP 29
(erts-17.0.3, JIT); 10 schedulers online; `mix run` in `:dev`. **One sample,
one machine, no repetitions.** Peak figures come from a busy-loop sampler
process reading `:erlang.memory(:total)`, which has unbounded sampling jitter
and can miss a short spike entirely.

These numbers are indicative, not a baseline. They exist to size the problem
and to justify the slicing below. Slice 2 replaces them with a committed,
reproducible baseline that records workload source, warmup protocol, sampling
method, repetition count, and distributions — scoped by OTP version,
architecture, scheduler count, and VM flags, since none of those are portable.
Do not quote a figure from this section as a capacity guarantee.

### Floor

| metric | value | note |
|---|---|---|
| `:erlang.memory(:total)` | 71.1 MB | includes Mix |
| `:code` | 16.9 MB | 457 modules loaded, only 48 are `PtcRunner.*` |
| `:processes` | 16.8 MB | 155 processes |
| `:ets` | 1.73 MB | |
| `:atom` | 1.05 MB | 31,620 atoms |

The floor is measured under `mix run`, so 47 loaded `Mix.*` modules and the
compiler are inside it. An embedded or release host floor is materially lower
and must be measured separately — Slice 2 does this without Mix on the path.
Only 48 of ~460 `PtcRunner.*` modules are loaded at the floor; lazy module
loading inflates any early measurement and is the dominant one-shot cost.

### Resident cost of durable artifacts

| artifact | retained size |
|---|---|
| compiled bundle, 1 tiny component | 5.6 KB |
| `WorkflowEnvironment` | 5.7 KB |
| `Limits` struct | 0.5 KB |
| `Lisp.Env.initial` | `:oversized` — see below |

`RetainedSize.bytes/1` returns `:oversized` for the initial env because it
holds builtin closures. Measured separately via `:erts_debug.flat_size/1`, the
`persistent_term` copy is ~45 KB and is shared process-wide, not per-run.

### Residual after workload

Each row runs the workload N times, forces a system-wide GC, and compares
`:erlang.memory` before/after.

| workload | N | total | processes | ETS | atoms |
|---|---|---|---|---|---|
| `Lisp.run` trivial | 500 | +61 KB | +61 KB | 0 | 0 |
| `Lisp.run` collection HOFs | 500 | +307 KB | +99 KB | +12 KB | +2061 |
| `Kernel.run` full workflow | 200 | +59 KB | +59 KB | 0 | 0 |
| `compile_bundle` | 200 | +61 KB | +61 KB | 0 | 0 |

The ~60 KB rows are driver-process heap growth, at noise level (0.1–0.3
KB/iter). **The collection-HOF row is not a leak.** Repeating three equal
batches of 500 gives +2061 atoms and +82 KB ETS in batch 1, then **+0 and +0**
in batches 2 and 3 — entirely lazy module loading on first use.

That result is the methodology finding of this plan: a single before/after
comparison cannot distinguish one-shot warmup from a linear leak, and a naive
harness reads that row as a 4 atom/iter leak. The existing
`MemorySoak.measure3/3` plus `assert_atoms_per_iter_strict!/5` already solve
this by excluding the first measured iteration. Slice 2 generalizes the same
idea to bytes with an explicit repeated-batch oracle (below).

### Peak heap under concurrency (`Kernel.run`)

| concurrency | peak delta over base | per concurrent run |
|---|---|---|
| 1 | 0.94 MB | 937 KB |
| 8 | 1.61 MB | 201 KB |
| 32 | 3.91 MB | 122 KB |
| 64 | 5.98 MB | 93 KB |

The trend is sub-linear across the four points sampled, trailing at ~90–120 KB
peak per concurrent trivial `Kernel.run`. The concurrency-1 figure is dominated
by one-shot allocation and is not a per-run cost. Four points from one sample
do not establish convergence, and nothing here supports extrapolating past 64;
Slice 2 extends the sweep to 128 with repeated trials before any capacity claim
is made.

### Observed average vs enforced worst case

These are different numbers and must not be conflated. The ~100 KB above is
what a *trivial* workflow happens to use. The *enforced* ceiling is what a host
must actually provision against, and it is far larger:

| limit | default | bytes |
|---|---|---|
| `workflow_heap_words` | 8,000,000 | ~64 MB |
| `evaluation_heap_words` | 1,250,000 | ~10 MB |
| `provider_heap_words` | 5,000,000 | ~40 MB |
| `max_parallel_workers` | 8 | — |
| `live_provider_tasks` | 8 | — |

`Runner` passes `max_heap: config.limits.workflow_heap_words`
(`runner.ex:196`), so a Kernel workflow runs under the 64 MB ceiling — not the
10 MB `evaluation_heap_words` figure, which governs the subordinate evaluation
path. `worker_max_heap` defaults to `max_heap`, and `lisp.ex:262` states the
aggregate directly: live parallel heap ≈ `max_parallel_workers ×
worker_max_heap`. For a Kernel workflow using `pmap`/`pcalls` at defaults that
is 8 × 64 MB of worker heap **on top of** the 64 MB parent.

So the worst-case tail for a single `Kernel.run` at default limits is on the
order of **hundreds of MB**, roughly three orders of magnitude above the
observed trivial-run average. Establishing where real workloads sit between
those bounds is a primary goal of the Slice 2 matrix. Capacity planning driven
by the average alone would badly under-provision.

## Use-case matrix

Slice 2 commits a baseline for each row. Programs stay generic and
domain-blind, consistent with the repository prompt rules.

| # | use case | measures | why it matters |
|---|---|---|---|
| 1 | idle floor, no Mix | resident MB, module count | the number an embedder budgets first |
| 2 | `Lisp.run` trivial | per-call peak, residual | cheapest possible unit |
| 3 | `Lisp.run` collection HOFs | per-call peak, residual | exercises allocation-heavy builtins |
| 4 | `Lisp.run` large-binary build | peak, refc-binary residual | the refc-pinning failure mode |
| 5 | `compile_bundle`, 1 component | peak, retained bundle size | per-artifact resident cost |
| 6 | `compile_bundle`, 20 components | peak, retained, scaling | does bundle cost scale linearly |
| 7 | `Kernel.run` full workflow | peak, residual | the real embedding unit |
| 8 | `Kernel.run` with capabilities + events | peak, sink retained bytes | sink accounting vs actual heap |
| 9 | concurrency sweep 1/8/32/64/128 | peak per concurrent run | capacity planning |
| 10 | `AnalysisSession` + `SessionTrace` churn | procs, monitors, ETS entries | trace owner + evaluation owner pair |
| 11 | provider acquire/close churn | procs, monitors, `ProviderTaskTracker` | acquire/close is the richest lifecycle |
| 12 | `HostCredentialLease` churn | ETS entries, procs, heir transfers | table changes owner via `give_away` |
| 13 | MCP stdio transport churn | ports, OS fds, procs, binary | port/fd lifecycle |
| 14 | MCP HTTP adapter churn | procs, binary, connections | distinct transport from stdio |
| 15 | REPL session churn | ETS **entries**, procs | shared per-creator table |
| 16 | OAuth refresh cycles | `persistent_term`, procs | token manager + cleanup workers |
| 17 | OAuth rejection / scope-requirement transitions | `persistent_term` | **characterization only** — see below |
| 18 | `RunCoordinator` churn, provider-free | procs, monitors, sinks | creates `ExecutionSessionOwner` |
| 19 | `RunCoordinator` churn, provider-backed | procs, monitors, provider tasks | the full command execution path |

Rows 18–19 exist because row 7 does **not** reach `ExecutionSessionOwner`.
`Kernel.run/2` goes to `Runner.run` (`kernel.ex:59`); the owner is created only
via `RunCoordinator` (`run_coordinator.ex:163`, `:249`). Both rows include
caller death, which is the case that owner specifically defends against.

Every row 10–19 runs three ways: normal completion, owner death, and deadline
expiry. A leak that appears only when a session is killed at its cleanup
deadline — where `terminate/2` never runs — is the leak most likely to exist,
and the happy path cannot find it.

**Row 17 is a characterization row, not a gate.** Ordinary session churn never
writes a `LocalFences` entry. A fence is written by a **rejection or
scope-requirement transition** — `start_response_persistence/5` blocks the
fence before persistence is attempted (`token_manager.ex:283`, `:297`). A
persistence *failure* creates nothing new; it merely leaves the existing fence
unresolved, because `TokenManager` retains the failed operation without calling
`LocalFences.resolve/2` (`token_manager.ex:793`) and retries reuse the same
operation reference.

The workload must therefore drive **repeated distinct transitions** with
persistence forced to fail. Repeatedly failing one transition would show a flat
count and wrongly retire Slice 5. Two variants are needed, because they bound
different things:

1. many distinct transitions under **one fixed identity** — tests whether
   per-identity coalescing would be enough;
2. transitions across **churning identities** — tests the global bound, which
   per-identity coalescing cannot provide.

Each variant is accepted or rejected separately, and neither is readable
without proof the workload did what it claims. Instrument the run to count
actual `LocalFences.block/3` calls. A flat fence count means one of two very
different things:

- **blocks were observed, count stayed flat** → that variant's growth is
  already bounded; record it and retire the corresponding half of Slice 5;
- **no blocks were observed** → the workload never reached the code and proves
  nothing. Fix the workload; do not conclude anything about the candidate.

Only if *both* variants report observed blocks with a flat count is Slice 5
retired in full.

Row 17 therefore records and prints the fence-count slope and never fails the
build. If the slope is positive, the candidate is confirmed and the deferred
slice below has its reproduction. That slice fixes the growth and flips row 17
from diagnostic to gating in the same change — the repository's
failing-test-before-fix convention, expressed across two slices because the
reproduction is worth landing before the fix is designed.

**What is genuinely missing.** These paths are *not* untested — the tree has
substantial close, timeout, owner-death, and cleanup coverage, including
`repl_session_test.exs`, `mcp_stdio_transport_test.exs`,
`analysis_session_test.exs`, `provider_session_test.exs`, and
`host_installation_test.exs:432` ("registry creator death drains credential
resolution and its lease table"). Each verifies that *one* lifecycle cleans up
correctly. None runs the cycle N times and asserts the aggregate returns to
baseline. The gap is repeated-churn leak detection, not lifecycle correctness —
and a per-cycle residue small enough to pass every single-cycle assertion is
exactly what accumulates over a host's lifetime.

## Leak oracle

Replace "before vs after, allow N%" with a repeated-batch test, because the
measured HOF row above proves a single delta cannot separate warmup from leak.

Run K equal batches of N iterations, forcing a system-wide GC at each boundary.
A one-shot cost appears in batch 1 only; a linear leak appears in every batch.

The detector is a **slope**, not a trend. Regress the post-GC endpoint value
against cumulative iterations over batches 2..K and assert the fitted slope is
below a per-metric threshold. A linear leak produces a roughly *constant*
positive delta in every batch, so "the per-batch delta does not grow" is
satisfied by exactly the leak we are hunting — it is the wrong assertion and
must not be the primary one. Batch 1 is excluded from the fit, not from the
report: it is the warmup cost and belongs in the log.

Choose each threshold from the metric's observed batch-to-batch noise on a
known-clean workload, not from a round number.

### Metric tiers

Not every sample can carry the same authority. Three tiers, decided per metric
rather than per test:

**Gating, exact.** Counted resources attributable to the churned family, with
no legitimate steady-state growth: owned processes, ETS entries under the
family's keys, `persistent_term` entries under the family's prefix, ports,
monitors. Threshold zero, asserted exactly.

These must be **family-scoped, not global**. A global
`:erlang.system_info(:process_count)` both flaps on a shared VM and can hide a
real leak when an unrelated process exits and offsets it. Scope every count to
resources the test itself created.

**Gating, thresholded.** Byte metrics — `:erlang.memory` totals, per-family
retained sizes. Slope assertion against a threshold measured from clean-workload
noise, never a round number.

**Diagnostic, non-gating.** RSS, `:recon_alloc` carrier utilization, and any
characterization row. Always recorded and printed; never fails a build. RSS and
carrier behavior are platform- and allocator-dependent, so they inform
investigation rather than deciding it.

`measure3/3` is **not** an instance of this shape: it compares one measured
iteration against the remaining N−1 after warmup, which isolates first-call
cost but yields a single rate, not a slope. It stays as-is for the existing
atom soaks; the batch harness is a new sibling, not a replacement.

### Samples, with the tier each one carries

Every sample is listed with its tier. A global total and its family-scoped
counterpart are paired: the scoped one gates, the global one is context for
reading a failure.

| sample | tier | note |
|---|---|---|
| processes created by the test (monitored) | **gate, exact** | the real process-leak detector |
| `:erlang.system_info(:process_count)` | diagnostic | global; flaps on a shared VM |
| ETS entries under the family's keys | **gate, exact** | see `ReplSession` note below |
| `length(:ets.all())`, per-table `:ets.info(t, :size)` | diagnostic | global context |
| `persistent_term` entries under the family's prefix | **gate, exact** | except row 17 |
| `length(:persistent_term.get())` | diagnostic | global context |
| ports opened by the test | **gate, exact** | MCP stdio transports |
| `length(:erlang.ports())`, OS fd count | diagnostic | fd count is platform-specific |
| monitors held by the family's owners | **gate, exact** | |
| total monitor count | diagnostic | global context |
| `:erlang.memory/0` totals | **gate, threshold** | slope vs measured noise |
| `:erlang.system_info(:atom_count)` | **gate, special** | see below |
| `:recon_alloc` allocated types + carrier utilization | diagnostic | fragmentation |
| RSS via `:os.getpid` + platform query | diagnostic | platform-specific |

**Atoms are their own case.** The count is global and monotonic — atoms never
GC, so no scoping is possible and no decrease can mask a leak. That makes the
global count both unavoidable and unusually trustworthy. It gates on slope
after warmup exclusion, which is what the existing
`assert_atoms_per_iter_strict!/5` already does; the batch harness reuses that
rule rather than inventing a second one.

**The `ReplSession` case** is why ETS gates on entries, not tables: it
allocates one `:private` table per *creator process*, not per session, keyed by
session ID with entries deleted on close (`repl_session.ex:919`). A leaked
session entry never changes the table count.

`:recon` is already a `dev`/`test` dependency (`mix.exs:122`), so the
fragmentation and allocator sampling costs nothing new.

## Slices

Slices 1–4 are independently shippable and each changes one boundary. Slice 5
is explicitly dependent on Slice 3's row 17 and is sequenced, not parallel.

### Slice 1 — restore the gate

Smallest, highest value, no design risk.

- Add a `soak` alias to `mix.exs` running `test --only soak`.
- Add a scheduled CI job (weekly plus manual dispatch) running the soak suite at
  `PTC_SOAK_ITERATIONS=3000`. Scheduled, not per-PR: the suite is long and its
  signal is a trend, not a per-commit gate.
- Fix `.claude/skills/release/SKILL.md:46` to invoke the real command.
- Fix the false claim in `bench/README.md`.

Non-goal: adding new assertions. This slice only makes existing ones run.

Done when: a green scheduled run exists and no document references
`mix release.smoke`.

### Slice 2 — heap baseline harness and committed baseline

- Add `bench/heap_baseline.exs` covering use-case rows 1–9.
- Commit `bench/baselines/heap.json`, matching the existing
  `bench/baselines/lisp_eval.json` convention.
- Extend `mix bench.check` to compare heap against that baseline. Whether it
  **gates** or stays informational is deliberately open — see Open questions.
- Row 1 (floor without Mix) needs an escape from `mix run`; a release or a
  plain `erl` boot with the ebin path is the likely shape.

Done when: `mix bench.check` prints a heap table against a committed baseline
and a deliberate 2× regression is detected.

### Slice 3 — lifecycle soak

The real gap. Rows 10–19, each in its normal, owner-death, and deadline-expiry
variant.

- Extend `MemorySoak.snapshot/1` with the new samples (ETS entries, ports, OS
  fds, `persistent_term` count, monitors, allocator carriers, RSS) and add the
  batch harness plus the tiered slope assertions.
- Split the tests by owner family rather than one omnibus file, so a failure
  names the leaking subsystem: analysis/trace, provider, credential lease,
  MCP transports, REPL, OAuth, and execution session.

**Owner discovery is per-family and mostly explicit.** The marker-based helper
in `command_engine_test.exs:4552` is not a general pattern — it works because
`HostInstallationOwner` publishes an authority marker in its process dictionary
(`host_installation_owner.ex:165`). A repository-wide search finds that marker
and one other process-dictionary key, and the second is **not** an owner
marker: `ReplSession`'s key lives on the *creator* process and identifies its
shared ETS table (`repl_session.ex:936`). The `ReplSessionOwner` PID is inside
each table entry, stored as `{id, {pid, token}}` (`repl_session.ex:886`).

Getting this wrong breaks the owner-death variant specifically: monitoring what
the process-dictionary key points at would monitor the long-lived creator (the
test process), not the session owner, and the variant would silently verify
nothing. Capture the owner PID from the table entry.

Analysis, provider, MCP, OAuth, and execution owners publish nothing
equivalent at all.

So the primary mechanism is the test capturing PIDs and resource identities at
creation and monitoring them, asserting each is dead and its resources
reclaimed — not scanning for owners. Use markers only for the two families that
already have them. Adding markers to production modules purely for test
discovery is explicitly rejected: it would put test affordances in the runtime
for no runtime benefit.

This slice is large enough to land in stages; ship it owner-family by owner
family, harness first. Each family is a usable increment — a soak that covers
only providers still catches provider leaks.

Write down before coding, per the review workflow: for each churned resource,
its creator, owner, authorized user, and closer; and behavior on caller death,
owner death, and deadline expiry. Deterministic termination is required —
monitors and explicit acknowledgement, never `Process.sleep`.

Done when: every owner family holds its **gating** metrics flat across batches
2..K in all three termination variants; diagnostic metrics are recorded and
printed regardless; and row 17 has produced a fence-count slope, whatever its
sign, so the deferred question below is answerable either way.

### Slice 4 — runtime memory signal

`Sandbox` already measures `memory_bytes` and `eval_reductions`
(`sandbox.ex:314`) and surfaces them in `step.usage`, but the telemetry stop
event (`lisp.ex:473`) carries only `duration`, `result_bytes`, and
`prints_count`. Both values exist a few lines from the emit site.

- Add `memory_bytes` and `eval_reductions` to
  `[:ptc_runner, :lisp, :execute, :stop]` measurements.
- Document the event's full measurement set.

This is additive to a measurements map and breaks no handler. There are only
four `:telemetry.execute` sites in `lib/`, none on the Kernel side; widening
Kernel telemetry is deliberately **not** in scope here.

Done when: a host attaching to the stop event can chart per-run heap.

### Slice 5 (dependent) — `LocalFences` growth bound

Depends on Slice 3 row 17. Kept separate because it is a distinct mechanism and
belongs in its own change; sequenced after the reproduction rather than
deferred indefinitely.

**Do not bound fence lifetime.** The permanence of an unsatisfied fence is the
fail-closed security mechanism, not an oversight: `local_fences.ex` exists so a
rejected authority cannot be reissued after a manager restart or a failed
durable transition. Evicting a fence by age or by cardinality pressure would
reissue exactly the authority the fence denies. Any design that lets an
unsatisfied fence disappear is wrong regardless of what it does for memory.

Scope: bound fence **cardinality** while preserving every outstanding rejection
and scope requirement, so the retained set stays bounded without any
requirement being dropped.

Per-identity coalescing alone is **not sufficient** for a global bound. An
identity is a hash of the store identity plus the whole `GrantKey`
(`local_fences.ex:23`), and the grant key carries principal and authority epoch
(`grant_key.ex:10`). Identity churn therefore produces unboundedly many
distinct identities, each able to retain a permanent fence, even when every
individual identity is perfectly coalesced. A global limit is required before
the retained set can be called bounded.

**"Backpressure" is not a sufficient specification for that limit.** Rejection
and scope transitions are learned from `401`/`403` responses
(`mcp_source.ex:1618`) — the requirement exists the moment the server states
it. If a transition that overflows the global limit merely blocks or errors
without publishing something equivalent, manager death drops that requirement
and a replacement manager can reissue the rejected authority. The limit must
degrade toward *more* denial, never less: a conservative global saturation
marker that denies broadly while full, a durable spill, or an equivalent. This
is the design question Slice 5 has to answer first, before any memory
consideration.

The acceptance test is explicit: fill the limit, submit a new-identity
rejection or scope transition, kill or time out the manager, restart it, and
verify the authority is still denied.

Coalescing within an identity is still worth doing and must be provably
conservative: a merged fence may only be satisfied by a grant that would have
satisfied every fence it replaced.

The gate this slice adds is **zero growth slope, not zero live fences**. A
steady-state population of outstanding fences is correct; unbounded growth is
not. Keep tests proving that a replacement manager stays denied through an
indefinite persistence failure — that property must survive this slice.

Retirement follows row 17's two-variant acceptance rule above: both variants
must report observed `LocalFences.block/3` calls *and* a flat slope before this
slice is dropped, and the plan records why.

`lib/ptc_runner/kernel/mcp_oauth/local_fences.ex:33` writes one
`:persistent_term` entry per `{identity, operation_ref}`, where `operation_ref`
is a fresh `make_ref()`. It is erased by `resolve/2`, or by `admit/3` when a
strictly newer sufficient grant arrives. If neither happens — the operation
never resolves and no newer grant appears — the entry is permanent. There is no
cap and no sweeper, and `persistent_term` put/erase are global operations.

Fences are written by rejection and scope-requirement transitions, before
persistence is attempted (`token_manager.ex:283`, `:297`). A persistence
failure creates nothing new — it leaves an existing fence unresolved, because
`TokenManager` retains the failed operation and never calls `resolve/2`
(`token_manager.ex:793`).

Growth therefore comes from **distinct transitions, not retries.**
`start_response_persistence/5` mints one `operation_ref` and
`retry_response_persistence/2` reuses it (`token_manager.ex:753`, `:815`). This
sets Slice 5's lever: bound distinct transitions, globally; do not touch retry
behavior, which is already key-stable.

This is a **candidate, not a confirmed leak**. Slice 3 row 17 is what would
confirm it, and only row 17: ordinary session churn never reaches this code,
because a fence is written solely by a rejection or scope-requirement
transition. Do not fix it before the soak reproduces it.

One adjacent suspicion was investigated and **dismissed**: `admit/3` reads the
whole table with `:persistent_term.get/0` (line 50), which looked like it would
copy every value including the ~45 KB initial Lisp env. Measured: 1.1 µs per
call and 1.1 KB of heap growth, because `get/0` returns references to off-heap
literals rather than copies. Not a problem; recorded so it is not
re-investigated.

## Risks

- **Threshold flakiness.** Memory assertions on shared CI runners are noisy.
  Mitigation: scheduled rather than per-PR, slope over batches rather than a
  single absolute delta, exact assertions for counted metrics where the
  legitimate value is zero, and `PTC_SOAK_ITERATIONS` already tunable.
- **Baseline churn.** A committed heap baseline invites reflexive re-baselining
  the moment it goes red — the same failure mode the `bench.check` reductions
  baseline has already seen. Any bump needs a written cause, per the existing
  bench convention.
- **RSS sampling is platform-specific.** darwin and linux differ. It sits in
  the diagnostic tier for exactly this reason — recorded, never gating, and
  never branching the oracle on OS.
- **Slice 3 may find nothing.** That is an acceptable outcome and still worth
  the cost: it converts "we think the owner lifecycle is clean" into evidence.

## Open questions

1. Should Slice 2's heap check **gate** `mix bench.check`, or stay
   informational as `memory_bytes` is today? Gating risks re-baseline churn;
   informational risks being ignored, which is precisely how the soak gate
   died. Leaning informational in `bench.check` but hard-asserted in the Slice 3
   soak, so the trend is gated where it is stable and reported where it is not.
2. Does the scheduled soak job belong in `test.yml` or a new
   `soak.yml`? A separate workflow is easier to run manually and cannot slow
   PR CI.
3. How many of Slice 3's owner families justify their cost? Provider,
   credential-lease, and OAuth churn are the most complex to set up and the
   most likely to hide a leak; REPL and analysis-session churn are cheap. If
   the slice has to be cut, cut from the cheap end — but decide deliberately
   rather than by running out of appetite.
