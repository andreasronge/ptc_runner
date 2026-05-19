defmodule PtcRunner.Lisp.Eval.ParallelRunner do
  @moduledoc """
  Heap-capped, slot-bounded parallel execution of untrusted PTC-Lisp
  work (`pmap`/`pcalls`).

  ## Why not `Task.async_stream`

  `max_heap_size` is a *spawn-time* BEAM option: it must be in force the
  instant a process is created, because the closure (and everything it
  captures — e.g. a large `data/` snapshot bound by an enclosing `let`)
  is copied onto the new process heap before any line of the worker
  function runs. `Task.async_stream` creates the worker process itself,
  so a heap cap set from inside the worker body is too late by
  construction: the unbounded closure copy has already happened.

  `ParallelRunner` owns the worker lifecycle so it can pass
  `{:max_heap_size, ...}` to `Process.spawn` at creation. The cap is then
  in force from process birth and the closure copy lands on a limited
  heap — a worker whose captured environment alone exceeds the budget is
  killed at the first garbage collection.

  ## Heap model: fixed per-worker cap + global slot budget

  Every parallel worker — top-level AND nested — is spawned with the same
  **fixed** `worker_max_heap` `max_heap_size` with shared-binary
  accounting enabled. The heap cap is NOT divided by concurrency:
  dividing is unsound for nested parallelism, because a parent worker
  stays alive while its nested children run, so a parent and its children
  are all live at once.

  Instead, a single shared `PtcRunner.Lisp.Eval.ParallelBudget` semaphore
  (capacity `max_parallel_workers`) bounds how many workers may be alive
  at once across the *whole* `Lisp.run/2`, at every nesting depth. Each
  worker acquires exactly one slot before spawn and releases it on every
  termination path. The aggregate guarantee is:

      max live parallel heap ≈ max_parallel_workers × worker_max_heap

  A worker that wants to spawn nested parallelism with no slot free fails
  fast with `:parallel_capacity_exceeded` — slot acquisition is a
  non-blocking try-acquire, so it never deadlocks waiting on a slot that
  can only free when the worker itself finishes.

  ## Other guarantees

  - **Heap cap at birth** — every worker is spawned with
    `{:max_heap_size, %{size: worker_max_heap, kill: true,
    include_shared_binaries: true, ...}}`.
  - **One shared deadline** — a single absolute `deadline_mono` bounds the
    whole operation. Nested runner calls inherit the *same* deadline.
  - **Orphan cleanup** — workers are linked to the calling (sandbox)
    process, so if it is killed mid-operation the BEAM tears the workers
    down with it. On the normal failure/success path the runner
    explicitly kills any worker still alive.
  - **Deterministic error classification** — abnormal exits map to stable
    atoms: `:killed → :memory_exceeded`, past-deadline → `:timeout`, any
    other abnormal exit → `:runtime_error`.

  ## Link vs monitor — and the scoped `trap_exit`

  Each worker is spawned with BOTH `:link` and `:monitor`:

  - `:link` gives **orphan cleanup for free** when the *caller* dies. A
    plain `:monitor` does not — a monitored worker outlives its dead
    monitor. Since `run/3` executes synchronously inside the sandbox
    process, the only signal that reaches a worker when the sandbox is
    `Process.exit(pid, :kill)`-ed is a link signal.
  - `:monitor` gives the `{:DOWN, ...}` notification used to classify a
    worker's exit reason without ambiguity.

  A worker killed by its heap cap exits `:killed`, which would propagate
  through the link and take the sandbox down too. To prevent that,
  `run/3` enables `trap_exit` **only for the duration of the call** and
  restores the prior flag in an `after` block, converting worker link
  signals into `{:EXIT, _, _}` messages.

  Because the sandbox process may *itself* be linked to its caller (the
  `link: true` mode of `Sandbox.execute/3`, used by the MCP request
  worker), the temporary `trap_exit` must not swallow that caller's
  cancellation. `run/3` therefore distinguishes `{:EXIT, ...}` signals
  by source: signals from its own workers are handled as worker exits,
  while an *abnormal* exit from any non-worker is treated as real
  cancellation — all workers are killed and the exit is re-propagated so
  linked cancellation still tears the sandbox down. `:normal` exits from
  non-workers are ignored.
  """

  alias PtcRunner.Lisp.Eval.ParallelBudget
  alias PtcRunner.TraceContext

  # Process-dictionary key: append-only `MapSet` of EVERY worker pid
  # spawned by the in-progress `run/3` call. Never shrinks for the call
  # — read by the signal drain so it can distinguish our workers' EXITs
  # (including a just-killed worker's trailing `:killed`) from a linked
  # caller's cancellation EXIT.
  @worker_pids_key :__ptc_parallel_runner_worker_pids__

  # Process-dictionary key: registry of workers NOT YET REAPED —
  # `%{pid => %{ref, slot_held?}}`. A worker is removed the moment a
  # normal path reaps it (slot released). The `after`-block sweep kills
  # whatever is left, so a raise partway through `fill_window/1` cannot
  # orphan a worker or leak its slot. Distinct from `@worker_pids_key`
  # (which must keep killed workers so their trailing EXIT is still
  # recognised as ours, not mistaken for caller cancellation).
  @worker_registry_key :__ptc_parallel_runner_worker_registry__

  @typedoc "Per-worker payload returned by `fun`."
  @type worker_result :: {:ok, term()} | {:error, term()}

  @typedoc """
  Options for `run/3`.

  - `:worker_max_heap` - FIXED `max_heap_size` (in words) applied to
    every worker at spawn time. `nil` means no cap (only when the
    sandbox is uncapped).
  - `:max_concurrency` - local scheduling window: max workers this call
    keeps alive at once (>= 1).
  - `:budget` - shared `ParallelBudget` semaphore (the HARD global cap on
    parallel workers across the whole `Lisp.run`). `nil` disables the
    slot budget (used only when there is no global cap configured).
  - `:deadline_mono` - absolute monotonic-time deadline in ms shared by
    the whole operation (including nested runner calls).
  - `:trace_ctx` - trace context captured in the parent, re-attached
    inside each worker.
  - `:spawn_fun` - the 2-arity `(fun, spawn_opts) -> {pid, ref}` used to
    create each worker (default: `&Process.spawn/2`). A seam for
    fault-injection tests that need a spawn to raise partway through
    filling the window; production callers never set it.
  """
  @type opts :: [
          worker_max_heap: pos_integer() | nil,
          max_concurrency: pos_integer(),
          budget: ParallelBudget.t() | nil,
          deadline_mono: integer(),
          trace_ctx: term(),
          spawn_fun: (function(), list() -> {pid(), reference()})
        ]

  @doc """
  Runs `fun` over `items` in parallel under a fixed per-worker heap cap
  and a shared global worker-slot budget.

  `fun` is invoked as `fun.(item)` inside a freshly spawned, heap-capped
  worker process and must return a `worker_result`. The worker re-attaches
  the supplied trace context before calling `fun`.

  Returns `{:ok, results}` (per-worker return values, in input order) or
  `{:error, reason}` on the first failure. `reason` is one of:

  - `{:memory_exceeded, index}` - worker `index` was killed by its heap cap
  - `{:timeout, index}` - the shared deadline elapsed before worker `index`
    finished
  - `:parallel_capacity_exceeded` - the global worker-slot budget was
    exhausted, so a worker could not be started
  - `{:runtime_error, index, term}` - worker `index` exited abnormally
  - any `term` from an `{:error, term}` returned by `fun` itself
  """
  @spec run([term()], (term() -> worker_result()), opts()) ::
          {:ok, [term()]} | {:error, term()}
  def run([], _fun, _opts), do: {:ok, []}

  def run(items, fun, opts) when is_list(items) and is_function(fun, 1) do
    worker_max_heap = Keyword.get(opts, :worker_max_heap)
    max_concurrency = opts |> Keyword.fetch!(:max_concurrency) |> normalize_concurrency()
    budget = Keyword.get(opts, :budget)
    deadline_mono = Keyword.fetch!(opts, :deadline_mono)
    trace_ctx = Keyword.get(opts, :trace_ctx)
    spawn_fun = Keyword.get(opts, :spawn_fun, &Process.spawn/2)

    indexed = items |> Enum.with_index() |> Map.new(fn {item, idx} -> {idx, item} end)
    total = map_size(indexed)

    state = %{
      indexed: indexed,
      fun: fun,
      worker_max_heap: worker_max_heap,
      max_concurrency: max_concurrency,
      budget: budget,
      deadline_mono: deadline_mono,
      trace_ctx: trace_ctx,
      spawn_fun: spawn_fun,
      total: total,
      next: 0,
      # %{ref => %{pid, index, slot_held?: boolean}}
      live: %{},
      results: %{},
      # `true` when the LAST `fill_window/1` could not spawn an item
      # because the global slot budget was full. It is only a genuine
      # `:parallel_capacity_exceeded` failure if it persists while NO
      # worker of this run is live (no slot will ever free for us);
      # otherwise a live worker finishing frees a slot and filling
      # resumes. `collect/1` makes that call.
      budget_blocked?: false
    }

    # Append-only set of every worker pid ever spawned by this run
    # (signal-drain EXIT classification), and the not-yet-reaped worker
    # registry (the `after`-block sweep's safety net). Both live in the
    # process dictionary so the sweep finds workers even when a raise
    # mid-`fill_window/1` means the per-iteration `state` never reached
    # us. Cleared in the `after` block.
    Process.put(@worker_pids_key, MapSet.new())
    Process.put(@worker_registry_key, %{})

    # `Process.spawn` raising mid-`fill_window/1` (e.g. the VM process
    # limit) would otherwise orphan already-spawned workers and leak
    # their slots + the `trap_exit` flag. So BOTH the `trap_exit` set
    # and the initial spawn happen INSIDE the `try`; the `after` block
    # sweeps the registry, killing every still-live worker and releasing
    # every still-held slot, on every exit path including a raise.
    prior_trap_exit = Process.flag(:trap_exit, true)

    try do
      state |> fill_window() |> collect()
    after
      # Final orphan/slot cleanup. `sweep_registry/1` kills any worker
      # still registered (i.e. not already reaped + slot-released by the
      # normal paths) and releases its slot — this covers a raise
      # partway through `fill_window/1`.
      sweep_registry(budget)
      Process.delete(@worker_registry_key)

      # P2-b — trap_exit restoration / cancellation ordering.
      #
      # While `trap_exit` is `true`, an incoming exit signal is converted
      # into a queued `{:EXIT, _, _}` MESSAGE. Once the flag is restored
      # to `prior_trap_exit` (false for a normal sandbox), an exit signal
      # is instead delivered as a direct kill.
      #
      # `drain1` (still trapping) catches every cancellation already
      # converted to a message. But a cancellation signal can still be
      # *in flight* — sent by the dying linked caller, not yet processed
      # by this process. A single `receive ... after 0` scan after the
      # restore can miss it (it has not landed yet); the process would
      # then run on with the cancellation un-acted-on.
      #
      # Ordering argument for the close:
      #   1. `drain1` runs while `trap_exit` is still true — it drains
      #      every cancellation ALREADY converted to a message.
      #   2. `Process.flag/2` restores the flag. From here on an exit
      #      signal is a direct kill, never a droppable message.
      #   3. `blocking_cancellation_drain/1` parks this process at a
      #      signal-processing `receive` for a short BOUNDED window. A
      #      cancellation still in flight is delivered during that window
      #      and — `trap_exit` now false — directly kills this process.
      #      A cancellation that was already a trapped message is matched
      #      and re-propagated.
      #
      # So a cancellation is ALWAYS either (a) a message that drain1 or
      # the blocking drain re-propagates, or (b) a signal that kills the
      # process directly. It is never silently swallowed. A cancellation
      # arriving after the bounded window is still a signal against the
      # restored flag and kills the (still-running) process at its next
      # scheduling point — deferred, never lost.
      cancellation = drain_worker_signals(nil)
      Process.flag(:trap_exit, prior_trap_exit)
      cancellation = blocking_cancellation_drain(cancellation)
      Process.delete(@worker_pids_key)

      if cancellation, do: exit(cancellation)
    end
  end

  # Length of the bounded window (ms) over which, after `trap_exit` has
  # been restored, this process parks at a `receive` so any in-flight
  # cancellation signal is delivered (as a direct kill) or any trapped
  # cancellation message is observed. See the P2-b note in `run/3`.
  @cancellation_drain_window_ms 5

  # Post-restore drain. By this point every worker has been reaped and
  # unlinked, so the only remaining link is to an external caller (the
  # `link: true` sandbox's caller). If there is NO such link, no
  # cancellation is possible — drain the mailbox non-blocking (zero
  # added latency, the common case). If there IS a linked caller, park
  # briefly so an in-flight cancellation is delivered: as a direct kill
  # (`trap_exit` now false) or, if already a trapped message, matched
  # and re-propagated. See the P2-b ordering argument in `run/3`.
  defp blocking_cancellation_drain(cancellation) do
    case Process.info(self(), :links) do
      {:links, []} -> drain_worker_signals(cancellation)
      _linked -> drain_cancellations(cancellation, deadline_after(@cancellation_drain_window_ms))
    end
  end

  defp deadline_after(ms), do: System.monotonic_time(:millisecond) + ms

  defp drain_cancellations(cancellation, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, _ref, :process, _pid, _reason} ->
        drain_cancellations(cancellation, deadline)

      {:worker_result, _pid, _idx, _result} ->
        drain_cancellations(cancellation, deadline)

      {:EXIT, pid, reason} ->
        worker_pids = Process.get(@worker_pids_key, MapSet.new())

        case classify_drain_exit(pid, reason, worker_pids) do
          :drain -> drain_cancellations(cancellation, deadline)
          {:cancel, cancel_reason} -> drain_cancellations(cancellation || cancel_reason, deadline)
        end
    after
      timeout -> cancellation
    end
  end

  # ---- worker registry (process-dictionary; see `run/3`) ----

  defp registry, do: Process.get(@worker_registry_key, %{})

  defp register_worker(pid, ref, slot_held?) do
    # Append-only "ever spawned" set (drain classification).
    Process.put(
      @worker_pids_key,
      MapSet.put(Process.get(@worker_pids_key, MapSet.new()), pid)
    )

    # Not-yet-reaped registry (sweep safety net).
    Process.put(
      @worker_registry_key,
      Map.put(registry(), pid, %{ref: ref, slot_held?: slot_held?})
    )
  end

  # Remove a worker from the not-yet-reaped registry once a normal path
  # has reaped it (slot released), so the `after`-block sweep does not
  # double-kill / double-release it. The append-only `@worker_pids_key`
  # set deliberately keeps it — the worker's trailing `:killed`/`:normal`
  # EXIT must still be recognised as ours by the drain.
  defp unregister_worker(pid) do
    Process.put(@worker_registry_key, Map.delete(registry(), pid))
  end

  # `after`-block safety net: kill every worker still in the registry
  # and release its slot. On the normal paths the registry is already
  # empty (every worker reaped via `reap_worker/5`); this only fires
  # when `fill_window/1` raised partway and left workers unreaped.
  defp sweep_registry(budget) do
    Enum.each(registry(), fn {pid, %{ref: ref, slot_held?: slot_held?}} ->
      Process.demonitor(ref, [:flush])
      Process.unlink(pid)
      Process.exit(pid, :kill)
      release_slot(budget, slot_held?)
    end)

    Process.put(@worker_registry_key, %{})
  end

  # Spawn workers until the local scheduling window is full, items run
  # out, the shared deadline has passed, or the global slot budget is
  # exhausted.
  defp fill_window(state) do
    window_open? =
      spawn_next?(map_size(state.live), state.max_concurrency, state.next, state.total)

    cond do
      # Window full / all items started — clear any stale block flag.
      not window_open? ->
        %{state | budget_blocked?: false}

      # The deadline is re-checked against the live clock before EVERY
      # spawn: a nested pmap/pcalls may enter `run/3` with an already
      # expired inherited deadline, and a slot may free up (via
      # `handle_worker_result/4`) after the deadline elapsed. In both
      # cases an unstarted item must never start.
      deadline_passed?(state.deadline_mono) ->
        %{state | budget_blocked?: false}

      true ->
        # Try to claim a global worker slot — a non-blocking try-acquire.
        case acquire_slot(state.budget) do
          :ok ->
            state |> spawn_one(true) |> fill_window()

          :no_budget ->
            # No global budget configured for this run — spawn uncounted.
            state |> spawn_one(false) |> fill_window()

          :full ->
            # No slot free right now. Stop filling and record the block.
            # `collect/1` resolves it: if a live worker finishes, a slot
            # frees and filling resumes; if NO worker of this run is
            # live, the budget is held entirely by other parallelism and
            # the run fails closed with `:parallel_capacity_exceeded`.
            %{state | budget_blocked?: true}
        end
    end
  end

  # `:ok` — a slot was acquired (must be released on worker termination).
  # `:full` — budget exhausted.
  # `:no_budget` — no budget object; nothing to acquire or release.
  defp acquire_slot(nil), do: :no_budget

  defp acquire_slot(%ParallelBudget{} = budget) do
    case ParallelBudget.try_acquire(budget) do
      :ok -> :ok
      :full -> :full
    end
  end

  defp release_slot(_budget, false), do: :ok
  defp release_slot(nil, true), do: :ok
  defp release_slot(%ParallelBudget{} = budget, true), do: ParallelBudget.release(budget)

  @doc false
  # Pure predicate: may `fill_window/1` spawn the next worker right now,
  # given the live-worker count, the local scheduling cap, the next item
  # index, and the total item count?
  #
  # `false` when the scheduling window is full or when every item has
  # already been started. The deadline check and the global slot budget
  # are applied separately in `fill_window/1`. Public only so this logic
  # can be pinned by a unit test.
  @spec spawn_next?(non_neg_integer(), pos_integer(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  def spawn_next?(live_count, max_concurrency, next, total) do
    live_count < max_concurrency and next < total
  end

  @doc false
  # Has the shared `deadline_mono` already elapsed? When it has,
  # `fill_window/1` must not start any further worker. Public so this
  # exact branch is pinned deterministically by a unit test.
  @spec deadline_passed?(integer()) :: boolean()
  def deadline_passed?(deadline_mono) do
    System.monotonic_time(:millisecond) >= deadline_mono
  end

  # `slot_held?` records whether this worker holds a global budget slot
  # (so it is released exactly once, when the worker leaves `live`).
  defp spawn_one(state, slot_held?) do
    index = state.next
    item = Map.fetch!(state.indexed, index)
    parent = self()
    fun = state.fun
    trace_ctx = state.trace_ctx

    worker = fn ->
      # The heap cap is set as a spawn option, so it is in force the
      # instant this process exists — the closure (and its captured
      # environment, e.g. a large `let`-bound vector) is copied onto a
      # heap that is already governed by `max_heap_size`.
      #
      # `max_heap_size` with `kill: true` is enforced at garbage
      # collection. Force one GC immediately so an oversized captured
      # environment is caught *before* `fun` runs, even when `fun`
      # itself is too cheap to trigger a GC on its own.
      :erlang.garbage_collect()
      TraceContext.attach(trace_ctx)
      result = fun.(item)
      send(parent, {:worker_result, self(), index, result})
    end

    # The budget slot for this worker was already acquired by
    # `fill_window/1`. If the spawn itself raises (e.g. VM process
    # limit), that slot is not yet attached to any worker the sweep can
    # find — release it here before re-raising, so it does not leak.
    pid_ref =
      try do
        state.spawn_fun.(worker, spawn_opts(state.worker_max_heap))
      rescue
        e ->
          release_slot(state.budget, slot_held?)
          reraise e, __STACKTRACE__
      end

    {pid, ref} = pid_ref

    # Register BEFORE returning, so even if a later iteration of
    # `fill_window/1` raises, the `after`-block sweep finds this worker.
    register_worker(pid, ref, slot_held?)

    %{
      state
      | next: index + 1,
        live: Map.put(state.live, ref, %{pid: pid, index: index, slot_held?: slot_held?})
    }
  end

  # `:link` for orphan cleanup when the caller dies; `:monitor` for the
  # `{:DOWN, ...}` exit-reason notification. See moduledoc.
  defp spawn_opts(nil), do: [:link, :monitor]

  defp spawn_opts(worker_max_heap) when is_integer(worker_max_heap) and worker_max_heap > 0 do
    [
      {:max_heap_size,
       %{size: worker_max_heap, kill: true, error_logger: false, include_shared_binaries: true}},
      :link,
      :monitor
    ]
  end

  # Drive the receive loop until all results are in, a worker fails, the
  # slot budget is genuinely exhausted, or the shared deadline elapses.
  defp collect(%{results: results, total: total} = state) do
    cond do
      # `fill_window/1` could not get a slot AND no worker of this run
      # is live — no slot will ever free for us, so the global budget
      # is held entirely by other parallelism. Fail closed. (If a worker
      # WERE live, we instead fall through to `collect_receive/1`: that
      # worker finishing frees a slot and filling resumes — so a run
      # whose own window simply exceeds the budget is never failed, and
      # nesting cannot deadlock.)
      state.budget_blocked? and map_size(state.live) == 0 and map_size(results) < total ->
        finish_error(state, :parallel_capacity_exceeded)

      map_size(results) == total and map_size(state.live) == 0 ->
        {:ok, ordered_results(results, total)}

      true ->
        collect_receive(state)
    end
  end

  defp collect_receive(state) do
    remaining = state.deadline_mono - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      finish_error(state, {:timeout, any_live_index(state)})
    else
      receive do
        {:worker_result, pid, index, result} ->
          handle_worker_result(state, pid, index, result)

        {:DOWN, ref, :process, _pid, reason} ->
          handle_down(state, ref, reason)

        {:EXIT, pid, reason} ->
          handle_exit(state, pid, reason)
      after
        remaining ->
          finish_error(state, {:timeout, any_live_index(state)})
      end
    end
  end

  # A worker has sent its `{:worker_result, ...}`. CRITICAL (P2-a): the
  # result `send/2` happens *before* the worker process exits, so the
  # worker may still be alive and still holding its heap. We therefore
  # do NOT release its budget slot or remove it from `live` here — the
  # slot belongs to the worker until its termination is *confirmed* by
  # the monitor `:DOWN`. We only record the result; `handle_down/3`
  # later releases the slot and frees the `fill_window` capacity. This
  # guarantees `fill_window` cannot spawn a replacement while the
  # completed worker is still running, so live workers (and aggregate
  # heap) never exceed `max_parallel_workers`.
  # `index` from the message is ignored — the authoritative index is
  # the one in the worker's `live` entry, keyed by its monitor ref.
  defp handle_worker_result(state, pid, _index, result) do
    case pop_by_pid(state.live, pid) do
      {nil, _live} ->
        # Worker already reaped (DOWN seen first) — its result is stale.
        collect(state)

      {%{ref: ref} = info, live_without} ->
        case result do
          {:ok, value} ->
            # Stash the value; keep the worker in `live` (slot still
            # held) tagged with its result, awaiting its `:DOWN`.
            entry =
              info
              |> Map.delete(:ref)
              |> Map.put(:result, {:ok, value})

            %{state | live: Map.put(live_without, ref, entry)}
            |> collect()

          {:error, reason} ->
            # A `fun`-returned error fails the whole run. The worker is
            # finishing; `finish_error/2` -> `kill_all/1` reaps it
            # (releasing its slot) along with the rest.
            finish_error(state, {:fun_error, reason})
        end
    end
  end

  # A worker's monitor `:DOWN` — the worker process has *actually*
  # terminated. Termination of a worker is confirmed by `:DOWN` OR by
  # its `{:EXIT, ...}` (we trap exits); whichever arrives first reaps
  # the worker via `reap_terminated_worker/3`. This is the single point
  # where a worker's budget slot is released and its `fill_window`
  # capacity is freed (P2-a).
  defp handle_down(state, ref, reason) do
    case Map.pop(state.live, ref) do
      {nil, _live} ->
        # Already reaped (its `{:EXIT, ...}` was handled first).
        collect(state)

      {info, live} ->
        reap_terminated_worker(%{state | live: live}, Map.put(info, :ref, ref), reason)
    end
  end

  # `{:EXIT, ...}` while `trap_exit` is enabled. See moduledoc.
  defp handle_exit(state, pid, reason) do
    case pop_by_pid(state.live, pid) do
      {%{} = info, live} ->
        # Case 1: an EXIT from one of our workers — confirms its
        # termination, exactly like `:DOWN` (it may arrive first).
        reap_terminated_worker(%{state | live: live}, info, reason)

      {nil, _live} when reason == :normal ->
        # Case 3: a non-worker exited normally — not cancellation.
        collect(state)

      {nil, _live} ->
        # Case 2: abnormal exit from a non-worker (linked caller
        # cancellation). Tear down workers (releasing their slots),
        # then propagate so the sandbox process dies.
        kill_all(state)
        _ = drain_worker_signals(nil)
        exit(reason)
    end
  end

  # A worker (already removed from `state.live`) has terminated. Reap it
  # — release its budget slot — then either record its successful result
  # and resume filling, or fail the run if it died without one.
  #
  # `info` carries the per-worker `live` entry plus its `:ref`. If the
  # worker had already delivered a successful result (P2-a: result and
  # termination are two events) the `live` entry is tagged `:result`,
  # and the slot is being released only NOW that termination is
  # confirmed — never on result receipt.
  defp reap_terminated_worker(state, %{pid: pid, ref: ref, index: index} = info, reason) do
    reap_worker(state.budget, pid, ref, info.slot_held?, kill: false)

    case info do
      %{result: {:ok, value}} ->
        state
        |> Map.update!(:results, &Map.put(&1, index, value))
        |> fill_window()
        |> collect()

      _no_result ->
        finish_error(state, classify_down(index, reason))
    end
  end

  # Stable classification of an abnormal worker exit (issue H1):
  # callers can assert ONE reason, not a set.
  defp classify_down(index, :killed), do: {:memory_exceeded, index}
  defp classify_down(index, :normal), do: {:runtime_error, index, :exited_without_result}
  defp classify_down(index, reason), do: {:runtime_error, index, reason}

  # Kill every still-live worker (releasing its slot), then return the
  # error. A linked caller's abnormal cancellation EXIT seen while
  # draining is re-propagated rather than masked by the error tuple.
  defp finish_error(state, error) do
    kill_all(state)

    case drain_worker_signals(nil) do
      nil -> {:error, unwrap_error(error)}
      cancellation -> exit(cancellation)
    end
  end

  # A `{:error, term}` returned by `fun` is surfaced as `term` verbatim.
  defp unwrap_error({:fun_error, term}), do: term
  defp unwrap_error(other), do: other

  # Kill every live worker and release each one's global budget slot.
  defp kill_all(state) do
    Enum.each(state.live, fn {ref, %{pid: pid} = info} ->
      reap_worker(state.budget, pid, ref, info.slot_held?, kill: true)
    end)
  end

  # Reap a worker: demonitor + unlink + (optionally) kill it, release
  # its global budget slot, and remove it from the registry so the
  # `after`-block sweep does not double-act on it. The single place
  # every worker termination path funnels through.
  defp reap_worker(budget, pid, ref, slot_held?, kill: kill?) do
    Process.demonitor(ref, [:flush])
    Process.unlink(pid)

    if kill? do
      Process.exit(pid, :kill)
    else
      drain_exit_for(pid)
    end

    release_slot(budget, slot_held?)
    unregister_worker(pid)
  end

  defp pop_by_pid(live, pid) do
    case Enum.find(live, fn {_ref, %{pid: p}} -> p == pid end) do
      {ref, info} -> {Map.put(info, :ref, ref), Map.delete(live, ref)}
      nil -> {nil, live}
    end
  end

  # Drain a possibly-pending `{:EXIT, pid, _}` for a specific worker we
  # just unlinked, so it never leaks into a later receive.
  defp drain_exit_for(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  # Drain stray worker signals; see moduledoc. Returns a non-worker
  # abnormal-EXIT cancellation reason if one was seen, else `nil`.
  defp drain_worker_signals(cancellation) do
    receive do
      {:DOWN, _ref, :process, _pid, _reason} ->
        drain_worker_signals(cancellation)

      {:worker_result, _pid, _idx, _result} ->
        drain_worker_signals(cancellation)

      {:EXIT, pid, reason} ->
        # Use the APPEND-ONLY ever-spawned set, not the not-yet-reaped
        # registry: a worker just reaped (e.g. heap-killed, slot
        # released, unregistered) can still have a trailing
        # `{:EXIT, _, :killed}` in the mailbox, and that EXIT is still
        # ours — it must be drained, not mistaken for caller cancellation.
        worker_pids = Process.get(@worker_pids_key, MapSet.new())

        case classify_drain_exit(pid, reason, worker_pids) do
          :drain -> drain_worker_signals(cancellation)
          {:cancel, cancel_reason} -> drain_worker_signals(cancellation || cancel_reason)
        end
    after
      0 -> cancellation
    end
  end

  @doc false
  # Pure classification of an `{:EXIT, pid, reason}` seen during the
  # finish-path drain, given the set of known (still-registered) worker
  # pids.
  #
  #   - EXIT from a known worker            -> `:drain`
  #   - `:normal` EXIT from a non-worker    -> `:drain`
  #   - abnormal EXIT from a non-worker     -> `{:cancel, reason}`
  @spec classify_drain_exit(pid(), term(), MapSet.t()) :: :drain | {:cancel, term()}
  def classify_drain_exit(pid, reason, worker_pids) do
    cond do
      MapSet.member?(worker_pids, pid) -> :drain
      reason == :normal -> :drain
      true -> {:cancel, reason}
    end
  end

  defp ordered_results(results, total) do
    Enum.map(0..(total - 1), fn idx -> Map.fetch!(results, idx) end)
  end

  defp any_live_index(%{live: live}) do
    case Enum.min_by(live, fn {_ref, %{index: idx}} -> idx end, fn -> nil end) do
      {_ref, %{index: idx}} -> idx
      nil -> 0
    end
  end

  defp normalize_concurrency(c) when is_integer(c) and c > 0, do: c
  defp normalize_concurrency(_), do: 1
end
