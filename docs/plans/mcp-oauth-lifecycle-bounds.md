# MCP OAuth lifecycle bounds

**Status:** proposed; no implementation started.
**Tracking:** [#1215](https://github.com/andreasronge/ptc_runner/issues/1215).
**Scope:** two unbounded lifetimes in the OAuth layer, both node-global. This
document exists because each needs a decision before code, not because the code
is large.

Neither problem is a correctness bug in a single run. Both are availability
problems that accumulate over the lifetime of a VM, and both are invisible to
the current test suite because the suite starts a fresh VM per run.

## Problem 1: fences leak one `:persistent_term` entry per failed persistence

### Mechanism

`LocalFences` stores one `:persistent_term` entry per in-flight OAuth response
transition, keyed `{{LocalFences, :fence}, identity, operation_ref}`
(`lib/ptc_runner/kernel/mcp_oauth/local_fences.ex:17,76`).

- `block/3` (`:31`) writes an entry when a response persistence starts —
  `token_manager.ex:755`, with a fresh `make_ref()` per attempt.
- `resolve/2` (`:38`) erases it, but **only on the success branch** —
  `token_manager.ex:796`. The `{:error, _reason}` branch at `:798` marks the
  persistence `:failed` and leaves the entry in place.
- The only other eraser is `admit/3` (`:44`), which erases entries for its own
  `identity` that a strictly newer grant satisfies.

The leak follows from the identity's scope. `identity/2` (`:24`) hashes
`{Store.local_identity(store), key}`, and for the shipped store
`local_identity/1` is `{Memory, pid}` — **the store's pid**
(`store/memory.ex:152`). `Store.Memory` is spawned once per run
(`provider_execution.ex:720`) and dies with its owner.

So a fence written during run N carries run N's store pid. Run N+1 has a
different store pid, therefore a different identity, therefore its `admit/3`
never matches run N's entries and never erases them. Once run N's store is gone,
**no code path can ever erase those entries**. They persist for the life of the
VM.

### Why it matters more than one leaked term

`admit/3` enumerates the *entire* `:persistent_term` table on every admission:

```elixir
for {{@persistent_prefix, ^identity, _operation_ref} = key, fence} <-
      :persistent_term.get(), reduce: [] do
```

`:persistent_term` has no prefix lookup, so this is the only way to enumerate.
The scan is therefore O(all terms in the VM) and grows monotonically with every
failed persistence in every prior run. Separately, each `put/erase` triggers a
VM-wide reference scan, so write cost is already non-trivial.

`test/soak/lifecycle/oauth_local_fences_soak_test.exs:24-27` was written to look
for exactly this and is not a merge gate.

### The constraint any fix must respect

`:persistent_term` was not chosen casually. From `local_fences.ex:5-8`:

> Each secret-free transition has its own `:persistent_term` key, so publishing
> it is atomic and does not depend on a process that can restart between a server
> response and durable persistence.

That is the property to preserve: **a fence must survive the death of any
process that could observe the server response.** It does *not* need to survive
the run. The store whose pid the identity is derived from is itself per-run, so
a fence outliving its store is already meaningless — it can never be matched.

That gap between "must outlive the manager process" and "cannot usefully outlive
the store" is where the fix lives.

### Options

**A. Sweep at store teardown.** When `Store.Memory` terminates, erase every
fence whose identity derives from that store. Preserves the restart property
exactly; bounds lifetime to the run.
*Cost:* the store must be able to enumerate its own fences, which today means the
same full-table scan — once per run rather than once per admit. Needs the sweep
to run even on abnormal store death, i.e. in the store's `terminate/2` plus an
owner-monitor path.

**B. Resolve on the failure branch too.** Erase the fence when a persistence
fails terminally rather than only when it succeeds
(`token_manager.ex:798`).
*Cost:* this is a semantic change, not a cleanup change — the fence exists
precisely to fail closed when persistence outcome is unknown. Erasing on failure
would admit a grant the durable store may not have recorded. **Do not do this
without a separate argument that the failure is terminal and observed.** Listed
for completeness; it is probably wrong.

**C. Keep an index term per identity.** Store `{prefix, :index, identity} =>
MapSet.t(operation_ref)` so `admit/3` reads one term instead of scanning.
*Cost:* the index is itself mutable shared state with no atomic
read-modify-write in `:persistent_term`, reintroducing the race the current
design avoids. Rejected unless someone finds a CAS-shaped formulation.

**Recommendation: A, with B explicitly out of scope.** A preserves the stated
invariant, bounds the lifetime to the only scope where a fence is meaningful, and
its cost (one scan per run) is strictly better than today's (one scan per admit,
over a monotonically growing table).

### Open questions for A

1. Where does the sweep hook go — `Store.Memory.terminate/2`, the owner monitor,
   or both? A `:kill`ed store runs no `terminate/2`.
2. Is `Store` the right place at all, given `store.ex:11-14` contemplates
   non-memory adapters whose `local_identity` may not be pid-derived? A durable
   adapter would change the lifetime argument entirely.
3. Should the soak become a merge gate once bounded?

## Problem 2: cleanup workers never give up

### Mechanism

`ManagerCleanupWorker.handle_info(:close, …)`
(`lib/ptc_runner/kernel/mcp_oauth/manager_cleanup_worker.ex:39-48`) retries
`TokenManager.close/1` with exponential backoff capped at 30s. There is no
attempt counter, no total deadline, and no terminal branch.

So a manager whose close never succeeds produces a worker that retries every 30s
forever and holds one of `@max_managers 128` node-global slots
(`manager_cleanup.ex:25`) permanently. Reaching 128 makes `adopt/2` return
`:cleanup_unavailable` for the whole node until the VM restarts.

### Two error paths, not one — and they need opposite treatment

An earlier draft of this plan, and issue #1215, claimed the only error path is a
timeout. **That is wrong**, and it invalidated the first attempted fix.
`token_manager.ex:202`:

```elixir
@spec close(t()) :: :ok | {:error, :persistence_failed | :timeout}
```

- **`{:error, :timeout}`** comes from the `catch` at `token_manager.ex:205-207`
  when the manager does not answer within
  `@close_timeout_ms = @response_transition_timeout_ms + 1_000` (6s). The manager
  is wedged; further retries accomplish nothing.
- **`{:error, :persistence_failed}`** is an ordinary reply
  (`token_manager.ex:858`), sent by `close_or_continue/1` once every outstanding
  response persistence has status `:failed`. The manager is alive and answering.

The second path is the important one, because **retrying is doing real work**.
`handle_call(:close, from, %{closing: nil})` (`token_manager.ex:243-249`) calls
`retry_failed_persistences/1` on every attempt. The retry loop is the mechanism
by which a failed OAuth response eventually reaches durable persistence.

### Consequence: a blanket deadline is wrong

Killing the manager on exhaustion — the approach this plan originally
recommended, implemented on `fix/oauth-cleanup-give-up` and **not merged** —
breaks the `:persistence_failed` path. It:

1. abandons durable persistence of a response that was still being retried, and
2. strands the `LocalFences` entry for that operation, because
   `LocalFences.resolve/2` runs only on the success branch
   (`token_manager.ex:796`).

Point 2 means the naive fix makes **Problem 1 measurably worse**. Nothing can
resume the work: the persistence closure and its `operation_ref` live only in
`TokenManager` state, and the fence is VM-local `:persistent_term`.

**The two problems are therefore not independent.** An earlier version of this
document said they were; that was wrong.

### What this means for the design

Bounding is still required — `:persistence_failed` can also repeat forever if the
durable store is permanently unavailable — but the two paths want different
bounds and different exhaustion behaviour:

- `:timeout` — no progress is possible. A short bound with an abnormal exit is
  defensible.
- `:persistence_failed` — progress is possible. Any bound must decide what
  happens to the unresolved fence, and "erase it" runs straight into the
  fail-closed argument in Problem 1's option B.

That coupling is the open design question, and it is why no fix is merged.

### What is already correct

Refusal is fail-closed. Both callers kill the manager rather than leak it —
`host_installation.ex:1042` and `mcp_request_context.ex:441` both
`Process.exit(manager.pid, :kill)`. Raising `@max_managers` would not fix
anything; it would only move the wall.

### The constraint any fix must respect

On give-up the worker must exit **abnormally**. `Process.link/1` at
`manager_cleanup_worker.ex:28` is the reclamation mechanism, and links do not
propagate normal exits. The moduledoc at `manager_cleanup.ex:8-10` documents
this path explicitly:

> If this owner restarts, OTP terminates the linked workers, which in turn
> terminate their linked managers rather than leaving unreachable credential
> owners alive.

A `{:stop, :normal, state}` on exhaustion would free the slot and leave the
manager running — strictly worse than today.

### The decision

Two questions, and the second is the hard one.

**Q1 — what shape is the bound?** A total deadline bounds slot-time directly; an
attempt cap bounds it only through the backoff curve, so retuning the curve
silently moves the worst case. **Deadline.**

**Q2 — what happens on exhaustion for `:persistence_failed`?** Unresolved. The
options each give something up:

- **Kill the manager anyway.** Simple, bounds the slot, but abandons durable
  persistence and strands a fence. Rejected above.
- **Resolve the fence, then kill.** Bounds everything, but admits a grant the
  durable store may never have recorded — the exact failure the fence exists to
  prevent. Needs the same argument as Problem 1 option B, which is probably
  unwinnable.
- **Separate the slot from the retry.** Let the cleanup *slot* be released at the
  deadline while the manager keeps retrying persistence under some other owner.
  Preserves both properties, but needs a second owner with its own bound, and
  the `Process.link/1` reclamation contract has to be rethought.
- **Bound only `:timeout`, leave `:persistence_failed` unbounded.** Fixes the
  wedged-manager case, which is the one with no possible progress, and leaves
  today's behaviour for the case where retrying still does work. Smallest honest
  step; does not fully close slot exhaustion.

**Tentative recommendation: the last one**, as a first slice — it is the only
option that strictly improves the situation without deciding the fence question.
Full bounding waits on Problem 1.

Whatever is chosen, the bound must not be so short that a slow-but-recovering
endpoint loses its graceful close — that close is what revokes the remote token.

### Testability note

Reproducing this needs a `TokenManager` whose `:close` blocks, and each retry
costs 6s. **Making the bound injectable is a prerequisite for a test that runs in
CI**, not a nicety. Whichever option is chosen should be a worker-init parameter
with the production value as the default, so a test can drive a 50ms deadline.

## Sequencing and scope

- **These are not independent** — see "Consequence: a blanket deadline is wrong".
  Problem 2's exhaustion behaviour depends on how Problem 1 resolves fence
  lifetime. Do Problem 1 first, or take only the `:timeout`-only slice of
  Problem 2.
- Still one mechanism per PR, per the repo's scope-one-mechanism convention.
- Neither collides with the stable-CLI plan. Checkpoint F touches OAuth only to
  disable interactive authorization in the standalone VM
  (`docs/plans/lisp-kernel/stable-cli-contract.md:66,378`); nothing in E, F, or G
  mentions `:persistent_term`, fences, or the cleanup owner.
- The third item in #1215 — child-process environment inheritance in
  `trace_log.ex` — is deliberately **not** in this plan. It is a settled fix, and
  it belongs with Checkpoint F2's child descriptor/hygiene sweep
  (`stable-cli-contract.md:390,397`).

## Acceptance

Problem 1:
- [ ] A test proves fence entries do not survive their store, including on
      abnormal store death.
- [ ] A test proves `admit/3` cost does not grow across sequential runs.
- [ ] The restart invariant from `local_fences.ex:5-8` still holds, with a test
      that kills the manager between server response and durable persistence.
- [ ] Decision recorded on whether the soak becomes a gate.

Problem 2:
- [ ] A failing test reproduces permanent slot occupancy before the fix, running
      in CI time via an injected bound.
- [ ] Exhaustion exits abnormally and the manager is reclaimed.
- [ ] A slow-but-recovering close still completes gracefully within the bound.
- [ ] **A test distinguishes `{:error, :timeout}` from
      `{:error, :persistence_failed}` and proves the latter is not killed while
      persistence retries can still succeed.**
- [ ] **No fence is stranded by exhaustion** — assert the `:persistent_term`
      entry count is unchanged across a give-up.
- [ ] `@max_managers` is left alone, or changed with a stated reason.

Note for implementers: the parked branch `fix/oauth-cleanup-give-up` has a
working test harness for this (a stub manager that replies to `:close` with a
chosen result, so retries cost no wall time). Reuse the harness; do not reuse the
blanket-deadline fix.
