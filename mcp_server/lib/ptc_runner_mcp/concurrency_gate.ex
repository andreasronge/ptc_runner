defmodule PtcRunnerMcp.ConcurrencyGate do
  @moduledoc """
  Counting semaphore that enforces `:max_concurrent_calls` (§ 11) for
  `tools/call name: "ptc_lisp_execute"`.

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
    case :persistent_term.get(@key, :undefined) do
      :undefined ->
        ref = :atomics.new(1, signed: true)
        :persistent_term.put(@key, ref)
        ref

      ref ->
        ref
    end
  end
end
