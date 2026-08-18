defmodule PtcRunner.Kernel.BoundedWorker do
  @moduledoc """
  Internal one-shot worker for heap- and time-bounded host computation.

  Results use a process alias so timeout cleanup can invalidate and drain a
  late reply before returning to the caller. Callers that are themselves
  disposable workers may opt into `:cancel_with_caller`; the bounded worker is
  then linked for the duration of the call so an untrappable caller kill also
  terminates blocked work. A caller may also supply a `:cancel_with` process;
  its termination cancels the worker without coupling the two owners.
  """

  @doc """
  Classifies the result of a bounded provider callback that answers `:ok`.

  Both callers of this — the audited-local and unverified phase-7 steps, and the
  connectivity probe — must translate a callback's outcome the same way, and the
  rule is load-bearing rather than cosmetic: an exhausted budget is reported as
  the bare `:timed_out` atom rather than through the `{:error, reason}`
  translation, so a callback returning the timeout reason itself cannot forge
  the code its caller mints for a real timeout. Anything unrecognised fails
  closed. Drift between two copies of that would be a defect in the one that
  drifted, so there is one copy.

  A reason may also carry one positive integer position — the line of a
  declared input file the callback refused. Nothing else is admitted, because
  the position is the only per-instance detail a caller may publish and a wider
  grammar would let a callback hand its caller an arbitrary payload.
  """
  @spec classify_callback(term()) ::
          :ok | :timed_out | {:error, atom() | {atom(), pos_integer()}}
  def classify_callback({:ok, :ok}), do: :ok
  def classify_callback({:ok, {:error, reason}}) when is_atom(reason), do: {:error, reason}

  def classify_callback({:ok, {:error, {reason, position}}})
      when is_atom(reason) and is_integer(position) and position > 0,
      do: {:error, {reason, position}}

  def classify_callback({:error, :timeout}), do: :timed_out
  def classify_callback(_unrecognised), do: {:error, :internal}

  @doc "Runs a zero-arity function in a monitored process under explicit limits."
  @spec run((-> term()), keyword()) ::
          {:ok, term()} | {:error, :timeout | :cancelled | :heap_exceeded | :worker_failed}
  def run(function, opts) when is_function(function, 0) and is_list(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    max_heap_words = Keyword.fetch!(opts, :max_heap_words)
    cancel_with_caller? = Keyword.get(opts, :cancel_with_caller, false)
    cancel_with = Keyword.get(opts, :cancel_with)
    timeout_cleanup_hook = Keyword.get(opts, :timeout_cleanup_hook)

    if cancel_with_caller? do
      previous_trap_exit = Process.flag(:trap_exit, true)

      try do
        run_worker(
          function,
          timeout_ms,
          max_heap_words,
          true,
          cancel_with,
          timeout_cleanup_hook
        )
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end
    else
      run_worker(
        function,
        timeout_ms,
        max_heap_words,
        false,
        cancel_with,
        timeout_cleanup_hook
      )
    end
  end

  defp run_worker(
         function,
         timeout_ms,
         max_heap_words,
         linked?,
         cancel_with,
         timeout_cleanup_hook
       ) do
    reply_alias = Process.alias()
    reply_ref = make_ref()
    cancel_monitor = monitor_cancel_target(cancel_with)

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
        demonitor_cancel_target(cancel_monitor)
        Process.unalias(reply_alias)
        await_down(pid, monitor_ref)
        unlink(pid, linked?)
        drain_exit(pid, linked?)
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, :killed} ->
        demonitor_cancel_target(cancel_monitor)
        Process.unalias(reply_alias)
        unlink(pid, linked?)
        drain_exit(pid, linked?)
        {:error, :heap_exceeded}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        demonitor_cancel_target(cancel_monitor)
        Process.unalias(reply_alias)
        unlink(pid, linked?)
        drain_exit(pid, linked?)
        {:error, :worker_failed}

      {:EXIT, ^pid, reason} when linked? ->
        demonitor_cancel_target(cancel_monitor)
        await_down(pid, monitor_ref)
        Process.unlink(pid)
        drain_exit(pid, true)

        if reason == :killed,
          do: {:error, :heap_exceeded},
          else: {:error, :worker_failed}

      {:DOWN, cancel_ref, :process, cancel_pid, _reason}
      when cancel_monitor == {cancel_pid, cancel_ref} ->
        if linked?,
          do: terminate_linked(pid, monitor_ref, reply_alias, reply_ref),
          else: terminate(pid, monitor_ref, reply_alias, reply_ref)

        {:error, :cancelled}
    after
      timeout_ms ->
        demonitor_cancel_target(cancel_monitor)
        run_timeout_cleanup_hook(timeout_cleanup_hook)

        if linked?,
          do: terminate_linked(pid, monitor_ref, reply_alias, reply_ref),
          else: terminate(pid, monitor_ref, reply_alias, reply_ref)

        {:error, :timeout}
    end
  end

  defp unlink(pid, true), do: Process.unlink(pid)
  defp unlink(_pid, false), do: true

  defp monitor_cancel_target(nil), do: nil
  defp monitor_cancel_target(pid) when is_pid(pid), do: {pid, Process.monitor(pid)}

  defp demonitor_cancel_target(nil), do: :ok

  defp demonitor_cancel_target({_pid, monitor_ref}),
    do: Process.demonitor(monitor_ref, [:flush])

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
