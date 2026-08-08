# Spike: `:gen_statem` for Kernel owner processes

**Status:** spike complete, no adoption decision taken.
**Branch:** `spike/gen-statem-owner`.
**Code:** `test/support/spike/*.ex`, `test/spike/*.exs` — 16 tests, all passing.

## Question

The Kernel has 25 `GenServer`-based owner modules. Each one enforces
single-ownership, bounded cleanup, and exactly-once finalization through
hand-written flag combinations and `handle_*` head patterns. Recent flakes and
review findings have clustered on exactly that layer.

Would rewriting these owners as OTP `:gen_statem` machines make the ownership
rules structurally enforced rather than review-enforced?

## Method

`PtcRunner.Kernel.ExecutionSessionOwner` was chosen as the subject: it is the
central lifecycle owner, and Checkpoint E of the stable-CLI plan will touch it
regardless.

Three artefacts were built:

| Module | Role |
| --- | --- |
| `Spike.ExecutionLifecycle` | The lifecycle as a pure function — named phases, an explicit held-resource set, and returned effects. Acts as the test oracle. |
| `Spike.FlagsOwner` | The same lifecycle as a `GenServer` in the shipped house style: flat map, nilable/boolean flags, catch-all `handle_info/2`. |
| `Spike.StatemOwner` | The same lifecycle as a `:gen_statem` in `:state_functions` mode. |

Real resource work (sink finalization, authority abort/commit, worker teardown)
is replaced by an append-only `Spike.EffectLog`, so tests can assert *how many
times* and *in what order* an owner unwound.

Both process implementations are driven through identical randomized event
sequences (`stream_data`, sequences of 1–8 events drawn from await,
worker-result-ok, worker-result-error, worker-death, handoff-ack, caller-death)
and checked against the ownership invariants. `:caller_down` is a genuine
monitored process exit, not a simulated message. Awaits are issued with
`:gen_server.send_request/2` / `:gen_statem.send_request/2` so that a call keeps
its position in the sequence relative to plain sends; a spawned `GenServer.call`
raced them and made early runs non-deterministic.

## What the spike found

### 1. The highest-value finding is not about `:gen_statem`

The first property run failed against **both** implementations on the sequence
`[{:worker_result, {:error, …}}, :caller_down]`: the error settle released sinks
and authority, and the subsequent caller death released them again.

```
sinks finalized 2 times
effects: [:finalize_sinks, :abort_authority, :finalize_sinks, :abort_authority]
```

Naming the phase does not fix this — `:completed` is reached by both a
successful run holding its resources and a failed run that has already released
them. What fixed it in both implementations was making *ownership* explicit:
a held-resource set (`:worker`, `:sinks`, `:authority`) that release consults,
so replaying a release is a no-op instead of a second real teardown.

The shipped owner has the same shape. `handle_info({:DOWN, caller, …})` returns
`{:stop, :normal, abort(state)}`, and `terminate/2` then calls `abort/1` again.
On the provider-free path `state.built` is still set, so
`finalize_aborted_sinks/1` matches its first clause both times and calls
`EventSink.stop/1` twice.

This is not currently a defect: `EventSink.stop/1` is explicitly documented as
"Calling it after owner-driven shutdown is harmless." The finding is narrower and
worth recording anyway — **the exactly-once guarantee lives in the callees'
docstrings, not in the owner's structure.** It holds only as long as every
resource ever added to `abort/1` is independently idempotent, and nothing in the
build checks that. An explicit held-set moves the guarantee into the owner,
where it can be tested.

This change is available today, in plain `GenServer`, at no migration cost.

### 2. Model-based property testing works on this lifecycle

Five properties and eleven examples now run in ~27s and cover sequences that no
hand-written test enumerates. The exactly-once and never-both-ways invariants are
the ones that ownership bugs actually violate, and they are cheap to state once
the transitions are pure.

`stream_data` is already a dependency. This is available today and does not
depend on any `:gen_statem` decision.

### 3. `:gen_statem` capabilities that have no `GenServer` equivalent

Each is demonstrated in `test/spike/statem_capabilities_test.exs`.

**Free `terminate` guard.** `terminate(_reason, :closed, _data), do: :ok` skips
unwinding in exactly one state, named. The `GenServer` twin needs a dedicated
`closed?` field for the same guarantee — a field that has to be set on every path
that reaches termination, and is silently wrong if one path forgets.

**`:postpone`.** An event arriving before its state is reached is re-delivered
once the machine gets there. The strict statem honours a `:handoff_ack` sent
*before* the worker result; the `GenServer` shape drops the same message on its
catch-all clause, permanently and without signal.

Caveat: this exact reordering is not reachable through the shipped `await/1`,
which sends the ack only after the call returns. The value is structural — it
removes an ordering assumption rather than fixing a live bug.

**`:state_timeout`.** A per-state deadline that any state change cancels
automatically, with no timer reference in the data. Relevant to the operation
deadlines the owners already carry by hand.

**Fail-loud on unhandled events.** A statem with no catch-all crashes with the
state name as the failing function and the event as its argument:

```
{:function_clause,
 [{StrictOwner, :awaiting_handoff, [:info, :worker_down, %{…}], …} | _]}
```

The `GenServer` twin returns `{:noreply, state}` and stays alive. Given that the
shipped owners' catch-alls are exactly where dropped-message bugs hide, this is
the most valuable of the four for this codebase.

### 4. Measured costs

| Metric | `FlagsOwner` | `StatemOwner` |
| --- | --- | --- |
| Total lines | 150 | 169 (+13%) |
| Event-handling clauses | 9 | 20 (+122%) |

The clause count roughly doubles. Each clause is smaller and reads only against
one state, but there are many more of them, and every new event must be
considered against every state that could receive it. For a 5-state, 6-event
machine that is a table of 30 cells; the flags version leaves most of them
implicit.

### 5. Project gates are not an obstacle

On the spike branch, with `test/support/spike/` compiled into the test build:

- `mix format` — clean
- `mix credo --strict` — 630 files, no issues
- `MIX_ENV=test mix dialyzer` — 0 errors

`@behaviour :gen_statem` with `@impl :gen_statem` is understood by all three.

### 6. Supervision is a non-issue here

`:gen_statem` has no Elixir `use` macro, so it provides no `child_spec/1` and no
default `start_link/1`. That is normally the main adoption friction.

It does not apply to these owners. `PtcRunner.Application`'s supervision tree has
exactly one child (`MCPOAuth.ManagerCleanup`), and the execution owners are
started unsupervised with `GenServer.start/2` by deliberate ownership design.

## Risks of adopting

1. **Migration risk on already-hardened code.** `ExecutionSessionOwner` is 620
   lines that have been through many review rounds. A rewrite re-opens every one
   of those decisions. The spike reproduced the control flow, not the resource
   handling — the real work is in `ProviderExecution`, `RunBuilder`, and the
   cleanup ordering comment at `execution_session_owner.ex:516`, none of which
   the spike touched.
2. **`:state_functions` cannot see its own state name.** Genuinely shared event
   handling requires threading the state atom into a helper by hand. The
   alternative, `:handle_event_function` mode, reintroduces one catch-all clause
   list and gives up most of the benefit under evaluation.
3. **Clause growth is real** (measured above) and will be larger on a machine
   with more states than this reduction has.
4. **Team familiarity.** `:gen_statem` is unidiomatic in Elixir. Every future
   contributor and every review agent meets an Erlang behaviour with no Elixir
   wrapper.
5. **The benefits are separable.** Findings 1 and 2 deliver most of the
   correctness value and require no migration at all. Adopting `:gen_statem` on
   top adds findings 3's four capabilities — real, but incremental.

## Suggested next steps

Nothing here argues for a fleet-wide migration.

1. **Do first, independent of any decision:** make the held-resource set explicit
   in `ExecutionSessionOwner`'s `abort/1` path, and add model-based property
   tests over the extracted transitions. Both are cheap and land the majority of
   the value.
2. **Then consider:** converting exactly one owner to `:gen_statem` — the natural
   candidate is whichever owner Checkpoint E rewrites anyway, since the migration
   cost is already being paid there. Judge on the resulting diff.
3. **Do not** convert owners that are not otherwise being touched.

## Reproducing

```bash
cd /Users/andreasronge/projects/ptc_runner-gen-statem-spike
mix test test/spike/
```
