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

`TokenManager.close/1`'s only error path is a timeout
(`token_manager.ex:204-208`: `:exit, {:timeout, _}` → `{:error, :timeout}`;
every other exit returns `:ok`), bounded by
`@close_timeout_ms = @response_transition_timeout_ms + 1_000` = 6s
(`token_manager.ex:40-41`).

So a manager whose `:close` handler blocks — a stalled revocation, a wedged
transport — produces a worker that retries every 30s forever and holds one of
`@max_managers 128` node-global slots (`manager_cleanup.ex:25`) permanently.
Reaching 128 makes `adopt/2` return `:cleanup_unavailable` for the whole node
until the VM restarts.

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

What is the bound?

**A. Total deadline** (e.g. 5 minutes from adoption). Predictable worst-case slot
occupancy; independent of how backoff is tuned.

**B. Attempt cap** (e.g. 10 attempts). Simpler to test; worst-case wall time is
an emergent property of the backoff curve and changes if the curve does.

**Recommendation: A.** The resource being bounded is *slot-time*, and a deadline
bounds it directly. With the current curve, 128 slots × a 5-minute deadline
gives a comprehensible worst case; an attempt cap does not.

Whatever is chosen, it must not be so short that a slow-but-recovering endpoint
loses its graceful close — that close is what revokes the remote token.

### Testability note

Reproducing this needs a `TokenManager` whose `:close` blocks, and each retry
costs 6s. **Making the bound injectable is a prerequisite for a test that runs in
CI**, not a nicety. Whichever option is chosen should be a worker-init parameter
with the production value as the default, so a test can drive a 50ms deadline.

## Sequencing and scope

- These are independent. Two PRs, one mechanism each, per the repo's
  scope-one-mechanism convention.
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
- [ ] `@max_managers` is left alone, or changed with a stated reason.
