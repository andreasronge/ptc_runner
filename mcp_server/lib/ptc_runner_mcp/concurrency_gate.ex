defmodule PtcRunnerMcp.ConcurrencyGate do
  @moduledoc """
  Counting semaphore that enforces `:max_concurrent_calls` (§ 11) for
  `tools/call name: "lisp_eval"`.

  Per `Plans/ptc-runner-mcp-server.md` § 11, this limit is applied as
  a non-queueing semaphore: when the cap is reached, additional
  requests are rejected synchronously with `reason: "busy"` rather
  than blocking. The cap exists primarily as a memory ceiling — at
  default values, eight concurrent sandboxes can hold up to ~80 MB.

  ## Implementation

  Uses an `:atomics` ref (1-element 64-bit counter) stored in
  `:persistent_term`. `try_acquire/0` performs a single
  `:atomics.add_get/3`; if the post-increment value exceeds the cap,
  it decrements back and returns `:full`. `release/0` decrements.

  HTTP workers can use tracked permits: the permit is acquired first,
  then attached to the worker pid. A tiny monitor process releases the
  permit exactly once if the worker exits before the owning session can
  release it explicitly.

  This is intentionally lock-free and non-queueing: `:full` callers
  do NOT wait. Acquire is O(1) regardless of contention.

  Cap is read once at acquire time from `PtcRunnerMcp.Limits`.

  ## Test ergonomics

  Tests can call `reset/0` to drop the persistent counter and force a
  fresh init on next call. Callers that need to override the cap for
  a single check use `try_acquire/1`.
  """

  alias PtcRunnerMcp.Limits

  @key {__MODULE__, :ref}
  @type tracked_permit :: pid()

  @doc """
  Initialize the underlying atomics ref. Idempotent. Called once at
  application start (`PtcRunnerMcp.Application.start/2`) so that
  concurrent first callers cannot race on lazy initialization.

  Calling `init/0` more than once is a no-op — the existing ref is
  preserved so any in-flight permits remain accounted for.
  """
  @spec init() :: :ok
  def init do
    case :persistent_term.get(@key, :undefined) do
      :undefined ->
        ref = :atomics.new(1, signed: true)
        :persistent_term.put(@key, ref)
        :ok

      _existing ->
        :ok
    end
  end

  @doc """
  Try to acquire one permit using the configured cap.

  Returns `:ok` when a permit is granted (caller must call `release/0`
  when done) or `:full` when the cap has been reached.
  """
  @spec try_acquire() :: :ok | :full
  def try_acquire, do: try_acquire(Limits.max_concurrent_calls())

  @doc "Try to acquire one permit against an explicit cap (test helper)."
  @spec try_acquire(pos_integer()) :: :ok | :full
  def try_acquire(cap) when is_integer(cap) and cap > 0 do
    ref = ref()
    new_count = :atomics.add_get(ref, 1, 1)

    if new_count > cap do
      :atomics.sub(ref, 1, 1)
      :full
    else
      :ok
    end
  end

  @doc """
  Try to acquire a permit guarded by a monitor process.

  The returned permit must either be attached to a worker via
  `track_worker/2` or released with `release_tracked/1`. If the owner
  process exits before a worker is attached, the guard releases the
  permit. Once a worker is attached, the guard releases on either
  explicit release or worker `:DOWN`.
  """
  @spec try_acquire_tracked(pos_integer(), pid()) :: {:ok, tracked_permit()} | :full
  def try_acquire_tracked(cap, owner \\ self())
      when is_integer(cap) and cap > 0 and is_pid(owner) do
    case try_acquire(cap) do
      :ok -> {:ok, spawn(fn -> permit_guard(owner) end)}
      :full -> :full
    end
  end

  @doc "Attach a tracked permit to the worker process that owns it."
  @spec track_worker(tracked_permit(), pid()) :: :ok
  def track_worker(permit, worker) when is_pid(permit) and is_pid(worker) do
    send(permit, {:track_worker, worker})
    :ok
  end

  @doc "Release a tracked permit before its worker exits."
  @spec release_tracked(tracked_permit()) :: :ok
  def release_tracked(permit) when is_pid(permit) do
    send(permit, :release)
    :ok
  end

  @doc "Release one previously-acquired permit. Idempotent: never goes below 0."
  @spec release() :: :ok
  def release do
    ref = ref()
    new_count = :atomics.sub_get(ref, 1, 1)

    if new_count < 0 do
      # Defensive clamp: an over-release would let later acquires
      # succeed beyond the cap. Restore to 0.
      :atomics.add(ref, 1, 1)
    end

    :ok
  end

  @doc "Read the current in-flight count. Test-only."
  @spec in_flight() :: integer()
  def in_flight, do: :atomics.get(ref(), 1)

  @doc "Reset the counter to zero. Test-only — drops any leaked permits."
  @spec reset() :: :ok
  def reset do
    ref = ref()
    :atomics.put(ref, 1, 0)
    :ok
  end

  defp ref do
    # `init/0` is called from Application.start/2 so the term is
    # always present. The fallback here is defensive: it covers test
    # processes that bypass the OTP supervisor (e.g., direct
    # ConcurrencyGate.reset/0 in setup blocks before init/0 has run
    # in this BEAM instance).
    case :persistent_term.get(@key, :undefined) do
      :undefined ->
        :ok = init()
        :persistent_term.get(@key)

      ref ->
        ref
    end
  end

  defp permit_guard(owner) do
    owner_ref = Process.monitor(owner)

    receive do
      {:track_worker, worker} ->
        Process.demonitor(owner_ref, [:flush])
        worker_ref = Process.monitor(worker)
        await_permit_release(worker_ref)

      :release ->
        release()

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        release()
    end
  end

  defp await_permit_release(worker_ref) do
    receive do
      :release ->
        Process.demonitor(worker_ref, [:flush])
        release()

      {:DOWN, ^worker_ref, :process, _pid, _reason} ->
        release()
    end
  end
end
