defmodule PtcRunner.Kernel.BoundedWorker do
  @moduledoc """
  Internal one-shot worker for heap- and time-bounded host computation.

  Results use a process alias so timeout cleanup can invalidate and drain a
  late reply before returning to the caller. Callers that are themselves
  disposable workers may opt into `:cancel_with_caller`; the bounded worker is
  then linked for the duration of the call so an untrappable caller kill also
  terminates blocked work.
  """

  @doc "Runs a zero-arity function in a monitored process under explicit limits."
  @spec run((-> term()), keyword()) ::
          {:ok, term()} | {:error, :timeout | :heap_exceeded | :worker_failed}
  def run(function, opts) when is_function(function, 0) and is_list(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    max_heap_words = Keyword.fetch!(opts, :max_heap_words)
    cancel_with_caller? = Keyword.get(opts, :cancel_with_caller, false)
    timeout_cleanup_hook = Keyword.get(opts, :timeout_cleanup_hook)

    if cancel_with_caller? do
      previous_trap_exit = Process.flag(:trap_exit, true)

      try do
        run_worker(function, timeout_ms, max_heap_words, true, timeout_cleanup_hook)
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end
    else
      run_worker(function, timeout_ms, max_heap_words, false, timeout_cleanup_hook)
    end
  end

  defp run_worker(function, timeout_ms, max_heap_words, linked?, timeout_cleanup_hook) do
    reply_alias = Process.alias()
    reply_ref = make_ref()

    spawn_options =
      [
        {:max_heap_size,
         %{
           size: max_heap_words,
           kill: true,
           error_logger: false,
           include_shared_binaries: true
         }},
        :monitor
      ] ++ if(linked?, do: [:link], else: [])

    {pid, monitor_ref} =
      Process.spawn(
        fn -> send(reply_alias, {reply_ref, function.()}) end,
        spawn_options
      )

    receive do
      {^reply_ref, result} ->
        Process.unalias(reply_alias)
        await_down(pid, monitor_ref)
        unlink(pid, linked?)
        drain_exit(pid, linked?)
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, :killed} ->
        Process.unalias(reply_alias)
        unlink(pid, linked?)
        drain_exit(pid, linked?)
        {:error, :heap_exceeded}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        Process.unalias(reply_alias)
        unlink(pid, linked?)
        drain_exit(pid, linked?)
        {:error, :worker_failed}

      {:EXIT, ^pid, reason} when linked? ->
        await_down(pid, monitor_ref)
        Process.unlink(pid)
        drain_exit(pid, true)

        if reason == :killed,
          do: {:error, :heap_exceeded},
          else: {:error, :worker_failed}
    after
      timeout_ms ->
        run_timeout_cleanup_hook(timeout_cleanup_hook)

        if linked?,
          do: terminate_linked(pid, monitor_ref, reply_alias, reply_ref),
          else: terminate(pid, monitor_ref, reply_alias, reply_ref)

        {:error, :timeout}
    end
  end

  defp unlink(pid, true), do: Process.unlink(pid)
  defp unlink(_pid, false), do: true

  defp await_down(pid, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp drain_exit(pid, true) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp drain_exit(_pid, false), do: :ok

  defp terminate_linked(pid, monitor_ref, reply_alias, reply_ref) do
    Process.unalias(reply_alias)
    Process.exit(pid, :kill)
    await_down(pid, monitor_ref)
    Process.unlink(pid)
    drain_exit(pid, true)
    drain_result(reply_ref)
  end

  defp run_timeout_cleanup_hook(nil), do: :ok
  defp run_timeout_cleanup_hook(hook) when is_function(hook, 0), do: hook.()

  defp drain_result(reply_ref) do
    receive do
      {^reply_ref, _late_result} -> :ok
    after
      0 -> :ok
    end
  end

  @doc false
  @spec terminate(pid(), reference(), reference(), reference()) :: :ok
  def terminate(pid, monitor_ref, reply_alias, reply_ref) do
    Process.unalias(reply_alias)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    end

    drain_result(reply_ref)
  end
end
