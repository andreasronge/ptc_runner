defmodule PtcRunner.Lisp.Eval.ParallelBudget do
  @moduledoc """
  A shared, lock-free slot semaphore bounding the number of parallel
  `pmap`/`pcalls` worker processes alive at once across a whole
  `PtcRunner.Lisp.run/2`.

  ## Why a global slot budget (and not heap division)

  An earlier model gave each worker `max_heap / concurrency`. That is
  unsound for *nested* parallelism: a parent `pmap` worker stays alive
  while its nested children run, so a parent and its children are all
  live simultaneously — dividing the heap cannot bound the aggregate
  once nesting compounds.

  The model instead is: every parallel worker (top-level and nested)
  runs under a **fixed** `max_heap_size` cap, and one shared semaphore
  with capacity `max_parallel_workers` limits how many such workers may
  be alive at once. The aggregate guarantee is then simply:

      max live parallel heap ≈ max_parallel_workers × worker_max_heap

  ## Why `:atomics` (not `:counters`, not a GenServer)

  - **`:atomics`** gives `add_get/3` — an atomic increment-and-fetch.
    Try-acquire is one atomic op with no race: bump the counter, and if
    the new value exceeds capacity, atomically give it back. No lock,
    no extra process, no message round-trip.
  - **`:counters`** has only `add/3` (returns `:ok`) + a separate
    `get/2`; a try-acquire built from those two has a check-then-act
    race between concurrent acquirers.
  - **A GenServer** would add a process to supervise, monitor and clean
    up, plus a message round-trip on every spawn — all to serialise an
    operation `:atomics` already does atomically.

  The `:atomics` reference is an opaque term; it is threaded through
  `EvalContext` and copied into worker closures unchanged — every
  process operates on the *same* underlying counter.

  ## Acquire / release contract

  - `try_acquire/1` is **non-blocking**. It never waits for a slot —
    a worker that cannot get one fails fast with
    `:parallel_capacity_exceeded` rather than deadlocking on a slot that
    can only free when the worker itself finishes.
  - Every acquired slot MUST be released on every termination path
    (normal, timeout, heap kill, cancellation). Callers pair
    `try_acquire/1` with `release/1` via monitor cleanup / `after`.
  - Releasing without a held slot is a caller bug. It raises rather
    than clamping because a decrement-then-clamp release can race with a
    valid acquire and erase the acquired slot.
  """

  @enforce_keys [:atomics_ref, :capacity]
  defstruct [:atomics_ref, :capacity]

  @typedoc "Shared parallel-worker slot budget."
  @type t :: %__MODULE__{atomics_ref: :atomics.atomics_ref(), capacity: pos_integer()}

  # Single atomic slot holding the count of currently-held slots.
  @slot 1

  @doc """
  Creates a budget with `capacity` slots, all initially free.
  """
  @spec new(pos_integer()) :: t()
  def new(capacity) when is_integer(capacity) and capacity > 0 do
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, @slot, 0)
    %__MODULE__{atomics_ref: ref, capacity: capacity}
  end

  @doc """
  Non-blocking attempt to acquire one slot.

  Returns `:ok` if a slot was acquired (the caller now owns it and must
  `release/1` it), or `:full` if all slots are in use. Never blocks.
  """
  @spec try_acquire(t()) :: :ok | :full
  def try_acquire(%__MODULE__{atomics_ref: ref, capacity: capacity}) do
    # Atomic increment-and-fetch: claim a slot optimistically.
    case :atomics.add_get(ref, @slot, 1) do
      held when held <= capacity ->
        :ok

      _over ->
        # Over capacity — atomically hand the slot back.
        :atomics.sub(ref, @slot, 1)
        :full
    end
  end

  @doc """
  Releases one previously-acquired slot.

  Safe to call exactly once per successful `try_acquire/1`. Raises if
  no slot is currently held; underflow is a caller bug and must not be
  hidden in a hard security budget.
  """
  @spec release(t()) :: :ok
  def release(%__MODULE__{atomics_ref: ref}) do
    do_release(ref)
  end

  defp do_release(ref) do
    case :atomics.get(ref, @slot) do
      held when held > 0 ->
        case :atomics.compare_exchange(ref, @slot, held, held - 1) do
          :ok -> :ok
          _current -> do_release(ref)
        end

      _zero ->
        raise RuntimeError, "parallel budget release underflow"
    end
  end

  @doc """
  Returns the number of slots currently held (for tests / introspection).
  """
  @spec held(t()) :: non_neg_integer()
  def held(%__MODULE__{atomics_ref: ref}) do
    max(:atomics.get(ref, @slot), 0)
  end

  @doc """
  Returns the number of slots currently free.
  """
  @spec available(t()) :: non_neg_integer()
  def available(%__MODULE__{capacity: capacity} = budget) do
    max(capacity - held(budget), 0)
  end
end
