defmodule PtcRunner.Kernel.BoundedCapture do
  @moduledoc """
  One-shot owner-scoped capture under a heap limit and an absolute deadline.

  A snapshot owner reads a source once, at start, and must not grow its own
  heap doing so. The work therefore runs in a separate monitored process with
  `:max_heap_size` set to kill, and the calling owner waits on three things at
  once: the reply, the worker's death, and the death of the process the
  capture belongs to.

  The outcome is reported in one vocabulary — `:owner_down`, `:heap_exceeded`,
  `:worker_failed`, `:deadline_exceeded` — and each caller maps it onto the
  codes its own source contract publishes. A capture's own return value is
  handed back wrapped in `{:ok, …}`, so a capture that answers `{:error, …}`
  is never confused with a failure of the capture machinery itself.

  Whatever ends the wait, the worker does not outlive it: a deadline or a dead
  owner kills the worker and reaps its `:DOWN` before returning, so no capture
  keeps reading a source nobody is waiting for.
  """

  @type failure :: :owner_down | :heap_exceeded | :worker_failed | :deadline_exceeded

  @doc """
  Runs `capture` for `:owner`, returning `{:ok, capture_result}` or a failure.

  `:owner_ref` must be a monitor the caller already holds on `:owner`, so the
  owner's death is observed rather than polled. `:deadline_ms` is an absolute
  `System.monotonic_time(:millisecond)` value, not a duration, so a deadline
  already spent yields no work rather than a fresh budget.
  """
  @spec for_owner((-> term()), keyword()) :: {:ok, term()} | {:error, failure()}
  def for_owner(capture, opts) when is_function(capture, 0) and is_list(opts) do
    owner = Keyword.fetch!(opts, :owner)
    owner_ref = Keyword.fetch!(opts, :owner_ref)
    max_heap_words = Keyword.fetch!(opts, :max_heap_words)
    deadline_ms = Keyword.fetch!(opts, :deadline_ms)

    reply_alias = Process.alias()
    reply_ref = make_ref()

    {worker, worker_ref} =
      Process.spawn(
        fn -> send(reply_alias, {reply_ref, capture.()}) end,
        [
          {:max_heap_size,
           %{
             size: max_heap_words,
             kill: true,
             error_logger: false,
             include_shared_binaries: true
           }},
          :monitor
        ]
      )

    await(
      {worker, worker_ref},
      {owner, owner_ref},
      {reply_alias, reply_ref},
      max(deadline_ms - System.monotonic_time(:millisecond), 0)
    )
  end

  defp await({worker, worker_ref}, {owner, owner_ref}, {reply_alias, reply_ref}, timeout) do
    receive do
      {^reply_ref, result} ->
        Process.unalias(reply_alias)
        Process.demonitor(worker_ref, [:flush])
        if Process.alive?(owner), do: {:ok, result}, else: {:error, :owner_down}

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        terminate(worker, worker_ref, reply_alias)
        {:error, :owner_down}

      {:DOWN, ^worker_ref, :process, ^worker, :killed} ->
        Process.unalias(reply_alias)
        {:error, :heap_exceeded}

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        Process.unalias(reply_alias)
        {:error, :worker_failed}
    after
      timeout ->
        terminate(worker, worker_ref, reply_alias)
        {:error, :deadline_exceeded}
    end
  end

  defp terminate(worker, worker_ref, reply_alias) do
    Process.unalias(reply_alias)
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end
end
