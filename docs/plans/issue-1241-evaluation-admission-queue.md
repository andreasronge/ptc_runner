# Blocking evaluation admission + configurable parallel deadline

Slice plan for #1241 (remaining half) and the `pmap_timeout` row of #1236.
Branch: `fix/issue-1241-eval-admission-queue`.

## Problem

A run holds a single evaluation lease. `RunState.reserve_evaluation/1` answers
`{:error, :busy}` to every concurrent caller, and `agent.core` (correctly,
since #1267) converts that into a typed `evaluation-unavailable` workflow
failure. Under `pcalls`, N agent loops finish their provider calls and collide
on `kernel/eval-source` probabilistically — so a *declaratively parallel*
program dies from a host scheduling accident the PTC-Lisp author cannot see,
prevent, or handle (no sleep, no retry, no per-branch recovery in a parallel
call). PR #1272 made the failure honest; this slice makes it not happen.

Separately, the `pmap`/`pcalls` deadline is a hard-coded 5 000 ms
(`Context.@default_pmap_timeout`) that `Runner.execute_workflow/5` and
`Evaluation.evaluate_source/7` never override, and no `LimitCatalog` row can
reach. Two live agents already measured 4.1 s, so queued admission without a
configurable parallel deadline would be dead on arrival: `ParallelRunner`
kills the workers before the queue helps.

## Decision

1. **Admission queues instead of failing fast — for the `kernel-eval` tool
   path only.** Waiters park in a FIFO inside RunState with a server-side
   deadline. Direct callers (REPL `reserve_evaluation`) keep today's
   fail-fast `:busy`.
2. **The parallel deadline becomes a manifest-narrowable limit**,
   `parallel_timeout_ms`, threaded from Kernel limits into `Lisp.run`'s
   existing `:pmap_timeout` option for both the workflow evaluation and
   subordinate mission evaluations. Effective deadline for one parallel
   operation: `min(now + parallel_timeout_ms, run deadline)`.
3. **Serialization is preferred over concurrent leases.** Subordinate
   evaluations commit sequentially into shared run memory/history
   (`commit_evaluation`); concurrent leases would need merge semantics —
   that redesign is the mission-spaces track (#1237), not this slice.

Why not retry in the prelude: PTC-Lisp has no sleep, so backoff is either a
reduction-burning busy loop or a new blocking host capability — i.e. this
queue with a worse interface and no fairness.

## Mechanism

### RunState admission queue

New state: `admission_queue` (Erlang `:queue` of waiter records
`%{from, caller, monitor_ref, timer_ref}`). The existing single-slot
`evaluation_release_waiter` stays for release-status parking but gains an
always-reply discipline (below).

New call `reserve_evaluation(state, :block)` → `{token, {:reserve_evaluation,
:block}}`:

- Run closed / run deadline expired / `subordinate_evaluations` spent →
  immediate typed error reply, exactly as today.
- Lease free and no stale-lease reservations (below) → admit immediately
  (identical to the non-blocking path).
- Otherwise → enqueue: monitor the caller (the monitor ref is the waiter's
  immutable identity), start a `Process.send_after(self(),
  {:admission_deadline, monitor_ref}, timeout)` timer with
  `timeout = min(evaluation_admission_timeout_ms, RunState remaining ms)`,
  answer `{:noreply, …}`.

**Admission trigger points — enumerated, not assumed.** `clear_evaluation/1`
is *not* a universal choke point today: `{:fail, …}`, `:close`, and the
protocol-error closure only set `closed?`, and provider reservations drain
through `release_reservation/2` after the lease is already gone. Admission
(`admit_from_queue/1`) is therefore invoked from every one of:

- `clear_evaluation/1` (commit, explicit release, release-status completion,
  lease-owner `:DOWN`);
- `release_reservation/2` (a stale-lease provider reservation draining);
- every transition that sets `closed?: true` (`{:fail, kind, reason}`,
  `:close`, `:close_and_drain`, protocol-error closure, event-sink closure) —
  where it drains the whole queue with typed errors.

**Admission gate — applies to every grant path.** An evaluation grant
(blocking *or* fail-fast) is issued only when the lease is free **and no
capability reservation still carries a non-nil mission `evaluation_lease`**.
The lease-owner `:DOWN` path clears the lease while the dead evaluation's
provider tasks may still be live; their reservations reference the old lease
ref, and granting before they drain would overlap a new evaluation with the
old one's external effects. Fail-fast callers meeting this condition get
`{:error, :busy}`, exactly as if the lease were held. `reserve_source_check/1`
uses the same gate **and additionally answers `:busy` while the admission
queue is non-empty** — otherwise the declared queue-priority policy would be
violated by a source check slipping in between handoffs.
`release_reservation/2` firing for the last stale reservation is what
finally admits the next waiter.

**Admission loop.** `admit_from_queue/1` pops waiters until it either grants
one or empties the queue. A popped waiter is re-checked against the same
preflight conditions (closed, run deadline, `subordinate_evaluations`
budget) and receives the typed error reply on failure — the loop then
continues to the next waiter, because no future lease-clear is guaranteed to
occur. `evaluations` increments at admission, not enqueue.

Waiter lifecycle events (all lookup-by-ref-before-reply; unknown ref →
ignore, the waiter was already resolved):

- `{:admission_deadline, monitor_ref}` → if run deadline has expired, reply
  `{:error, :deadline_expired}`; otherwise `{:error, :admission_timeout}`.
  Remove, `demonitor(…, [:flush])`.
- `:DOWN` for a queued caller → remove, `Process.cancel_timer`, no reply.
- Closure drain → typed `{:error, :run_closed}` to every waiter, cancel
  timers, flush monitors.
- Admission → `Process.cancel_timer` + tolerate an already-in-flight
  `{:admission_deadline, ref}` message (the ref lookup fails; ignored).

**Invariant (review target):** every enqueued waiter receives exactly one
reply, or its caller is known dead. No state transition may drop a `from`.
Proving "exactly once" via `GenServer.call` alone is impossible (call aliases
discard late duplicates), so tests assert on RunState state transitions —
queue emptied, no lingering timers/monitors — in addition to caller-observed
replies.

The caller side (`RunState.reserve_evaluation(state, :block)`) uses
`GenServer.call(…, :infinity)`: the server-side timer guarantees a bounded
reply, and RunState death propagates to the caller through the call monitor.

### Always-reply for `release_evaluation_status`

`maybe_complete_evaluation_release/1` currently has paths that drop a parked
waiter without replying (`clear_evaluation` while parked; the lease-mismatch
`_other` branch). The parked caller then dies on the default 5 s
`GenServer.call` timeout — the best current lead on the unreproduced live
hang in #1241. Rework so that every path either keeps the waiter parked or
replies. The reply stays `{:ok, evaluation_status(state)}` — **not** an
error — because `Evaluation.release_failure/5` hard-matches `{:ok, status}`
and only needs the terminal-provider-failure bit; run closure is reported to
that caller through its own result path.

Ordering on closure, made explicit: closure drains **admission** waiters
immediately (they hold no lease and no provenance), but a parked
**release-status** waiter stays parked until its lease-scoped provider
reservations drain — closure kills the providers, their `:DOWN`s release the
reservations, and only then does the waiter receive `{:ok, status}` with
`terminal_provider_failure?` intact. `close_and_drain` (which empties
`reservations` synchronously) completes the parked waiter in the same
transition. The lease-mismatch `_other` branch replies immediately — its
lease is already gone, so there is no pending provenance to wait for.

### Evaluation path

The opts keyword lives on `evaluate_source_detailed/7`, not on
`evaluate_source/7` (whose seventh argument is `params`). `admission: :block
| :fail_fast` (default `:fail_fast`) is added to `evaluate_source_detailed`'s
opts and validated like `:projection_boundary` — an invalid value raises
`ArgumentError` rather than falling into a function-clause crash.
`RuntimeTools`' private `evaluate_source`/`evaluate_source_with` helpers move
to `evaluate_source_detailed` + the existing legacy projection (or an
equivalent wrapper), passing `admission: :block` — the embedded-program
(`kernel/eval`) path gets the same treatment. New failure mapping: `{:error,
:admission_timeout}` → `failure(:busy, :admission_timeout)`. Because the
kind stays `:busy`,
`agent.core`'s existing `(:busy :limit_exceeded)` branch already converts it
to the typed `evaluation-unavailable` workflow failure, and #1272's taxonomy
retention carries it through `pcalls` — no prelude change needed.

The evaluation's own `timeout_ms`/deadline are computed after admission, as
today; admission waiting spends only run time and the admission bound.

### Parallel deadline limit (#1236, `pmap_timeout` row only)

- New `LimitCatalog` manifest-narrowable row `parallel_timeout_ms`
  (compiled default 30 000, installed default 300 000) — one parallel
  operation's deadline.
- A relative `pmap_timeout` computed at `Lisp.run_native` start cannot
  implement `min(now + parallel_timeout_ms, run deadline)`: a parallel
  operation started late in the evaluation would construct a deadline past
  the absolute run deadline. The clamp therefore happens **at operation
  start**: `Runner.execute_workflow/5` and `Evaluation.execute_with_lease`
  pass both `pmap_timeout: parallel_timeout_ms` and the existing absolute
  `run_deadline_ms`; `Parallel.parallel_deadline/1` computes
  `min(now + pmap_timeout, absolute deadline cap)` from a new
  `EvalContext` field carrying that cap (populated from `run_deadline_ms`).
  The cap must survive every context reconstruction: `Lisp` run params →
  `Context.new`, **and both closure-invocation sites in `apply.ex` that
  build fresh contexts and hand-copy `pmap_timeout`/`pmap_deadline`** —
  omitting it there would silently unclamp any parallel operation started
  inside a prelude closure. A unit test pins each site.
- `Context.@default_pmap_timeout` (5 000) remains as the library-level
  fallback for direct `Lisp.run` users; Kernel runs always pass the option.
- Nested parallel calls keep inheriting the outer absolute deadline.

### New limit rows (both manifest-narrowable)

| name | compiled default | installed default |
| --- | --- | --- |
| `parallel_timeout_ms` | 30 000 | 300 000 |
| `evaluation_admission_timeout_ms` | 10 000 | 120 000 |

Rationale: at compiled defaults, worst-case admission wait is queue-length ×
evaluation time — eight workers behind 1 s evaluations fit inside 10 s. The
installed ceiling is deliberately 2× the installed `evaluation_timeout_ms`
ceiling (60 s) so a host that raises evaluation time can keep at least one
queued waiter admissible behind a maximal evaluation. The admission bound
does not *guarantee* admission — behind pathological holders it converts to
the typed `evaluation-unavailable`, which is the same contract as today,
bounded instead of instant. Hosts tune both; manifests narrow both. `Limits`
struct, host/manifest schema, and generated docs (`mix ptc.gen_docs`) update
together.

### Scheduling policy (explicit)

Queued blocking admission takes priority: an atomic handoff keeps
`evaluation_lease` continuously occupied while the queue is non-empty, so
direct fail-fast callers (`reserve_evaluation/1`, REPL) and
`reserve_source_check/1` observe `:busy` for the duration. That is the same
observable outcome those callers have under today's contention, sustained
rather than probabilistic, and it is the intended trade: the queue exists
for the one caller class (agent loops) that cannot handle `:busy`. A test
pins the policy.

## Tests (failing first, then implementation)

1. **Headline behavior:** N=4 (and N=8) `agent.core/run-value` loops under
   `pcalls`, stub requester with a barrier forcing simultaneous
   `kernel/eval-source` — the workflow now **succeeds** with all N values.
   The barrier releases after `min(N, Context.default_pmap_max_concurrency())`
   arrivals **and answers every later arrival immediately** — a one-shot
   barrier sized to the first scheduling window deadlocks any worker
   scheduled after it terminates. The existing 4-agent contention test is
   rewritten: with the 30 s `tool/hold` park and a narrowed
   `evaluation_admission_timeout_ms`, it now pins the admission-timeout path
   (`failure_kind "evaluation-unavailable"`, no extra model calls) instead of
   pinning fail-fast on first collision.
2. **Always-reply invariant:** a parked `release_evaluation_status` caller
   is resolved — never dropped — including by a commit the owner issued
   asynchronously after parking (raw `:"$gen_call"` regression observing
   both replies), by `close_and_drain`, and by reservation drain; a
   duplicate status request while one is parked is rejected with a typed
   `:release_pending` instead of replacing the first waiter's `from`.
   Because `GenServer.call` aliases absorb duplicate replies, the riskiest
   race (timer expiry vs admission) uses a raw send with a plain ref —
   two replies would both be observed.
3. **Queue mechanics:** FIFO order across 3 waiters; head admission-timeout
   followed by next-waiter admission; two simultaneous timer expirations
   with the queue usable afterwards; a stale `{:admission_deadline, ref}`
   after admission is ignored; a queued waiter killed mid-wait is dropped
   without wedging the queue; budget exhausted while queued → typed
   `:limit_exceeded` at admission; both `fail` and plain `close` drain all
   waiters with `:run_closed`.
4. **Reservation sequencing (release waiter *and* admission gate):** parked
   release completes when the reservation drains via dispatcher completion
   and via dispatcher death; provider death alone keeps it parked (the
   reservation belongs to the dispatcher); `terminal_provider_failure?` is
   preserved through a parked release; no grant — blocking or fail-fast —
   while a stale-lease provider reservation is live (the lease-owner-death
   overlap case).
5. **Parallel deadline:** manifest narrowing `parallel_timeout_ms` fails a
   parked `pcalls` at the configured deadline with the failure attributed
   to `parallel_timeout_ms` (not `workflow_timeout_ms`). The
   late-started-operation clamp is pinned at the `Parallel`/`Context` unit
   level (a near cap beats a generous `pmap_timeout`) — an integration
   version would race the sandbox kill on the same absolute deadline and
   flake. Nested-deadline behavior is pinned where it is observable: the
   runner spawns zero workers for an already-expired inherited deadline
   (`parallel_runner_test`), and the cap propagation through both closure
   reconstruction sites has direct tests. The `pmap_deadline` copy in the
   closure sites itself has no independently Lisp-observable outcome — the
   outer runner kills its workers at the same deadline regardless, and the
   absolute cap bounds even a hypothetically reset inner deadline — so it
   carries no dedicated test. A
   `:slow`-tagged test proves an op surviving past the old 5 s ceiling
   under the new default (park a capability ~5.5 s via `receive after`, no
   `Process.sleep`). A REPL test proves the configured limit reaches REPL
   parallel operations instead of the library's 5 s default.
6. **Fail-fast callers unchanged:** direct `reserve_evaluation` and
   `reserve_source_check` still answer `:busy` while the queue holds the
   lease (pins the scheduling policy).

## Documentation

- `docs/guides/building-agents.md`: replace the "fail fast on contention"
  paragraph — concurrent agent loops now serialize their evaluation phase;
  `evaluation-unavailable` remains for admission timeout and spent budget.
- `docs/guides/kernel-maintainer.md`: update the admission section (queue
  mechanics, always-reply invariant, why serialize instead of concurrent
  leases, pointer to #1237).
- `docs/guides/host-configuration.md` + generated schema/docs via
  `mix ptc.gen_docs` for the two new limit rows.

## Out of scope

- The live 150 s hang remains unreproduced; this slice removes the
  best-lead code path (reply-less waiter drop) but does not claim the fix.
  #1241 stays open for the hang unless the repro proves it closed.
- Per-agent budgets, config legibility, and the rest of #1236.
- Mission-spaces / concurrent leases (#1237).

## Risks

- `run_state.ex`, `evaluation.ex`, `context.ex` are in the semantic build
  projection's source closure — fine: only the release gate checks it; do
  not regenerate on this branch.
- Owner-state mutation rules: all queue operations are single atomic
  `handle_call`/`handle_info` transitions inside RunState; no external
  read-modify-write.
- Changing the pinned fail-fast contention behavior is deliberate; the
  rewritten regression test documents the new contract.
