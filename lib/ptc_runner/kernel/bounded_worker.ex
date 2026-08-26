defmodule PtcRunner.Kernel.BoundedWorker do
  @moduledoc """
  Internal one-shot worker for heap- and time-bounded host computation.

  Results use a process alias so timeout cleanup can invalidate and drain a
  late reply before returning to the caller. Callers that are themselves
  disposable workers may opt into `:cancel_with_caller`; the bounded worker is
  then covered by a monitor-based guard so caller death terminates blocked work
  without changing the caller's exit-trapping semantics. A caller may also
  supply a `:cancel_with` process; its termination cancels the worker without
  coupling the two owners.
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

  @doc """
  Classifies a bounded provider callback that may answer with one payload.

  The connectivity probe's shipped callback reports what its request spent, so
  a success may carry a term beside `:ok`. Only that one shape is added: every
  other outcome, a bare `:ok` included, is translated by `classify_callback/1`,
  so the failure rule above stays the single copy both callers share. The
  payload is opaque here and stays untrusted — the caller closes its shape
  before publishing it, on the same terms as the position above.
  """
  @spec classify_payload_callback(term()) ::
          :ok | {:ok, term()} | :timed_out | {:error, atom() | {atom(), pos_integer()}}
  def classify_payload_callback({:ok, {:ok, payload}}), do: {:ok, payload}
  def classify_payload_callback(result), do: classify_callback(result)

  @doc "Runs a zero-arity function in a monitored process under explicit limits."
  @spec run((-> term()), keyword()) ::
          {:ok, term()} | {:error, :timeout | :cancelled | :heap_exceeded | :worker_failed}
  def run(function, opts) when is_function(function, 0) and is_list(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    max_heap_words = Keyword.fetch!(opts, :max_heap_words)
    cancel_with_caller? = Keyword.get(opts, :cancel_with_caller, false)
    cancel_with = Keyword.get(opts, :cancel_with)
    timeout_cleanup_hook = Keyword.get(opts, :timeout_cleanup_hook)

    run_worker(
      function,
      timeout_ms,
      max_heap_words,
      cancel_with_caller?,
      cancel_with,
      timeout_cleanup_hook
    )
  end

  defp run_worker(
         function,
         timeout_ms,
         max_heap_words,
         cancel_with_caller?,
         cancel_with,
         timeout_cleanup_hook
       ) do
    reply_alias = Process.alias()
    reply_ref = make_ref()
    cancel_monitor = monitor_cancel_target(cancel_with)

    case start_worker(
           function,
           reply_alias,
           reply_ref,
           max_heap_words,
           cancel_with_caller?
         ) do
      {:ok, pid, monitor_ref, caller_guard} ->
        await_worker(
          pid,
          monitor_ref,
          caller_guard,
          reply_alias,
          reply_ref,
          cancel_monitor,
          timeout_ms,
          timeout_cleanup_hook
        )

      {:error, :worker_failed} ->
        demonitor_cancel_target(cancel_monitor)
        Process.unalias(reply_alias)
        {:error, :worker_failed}
    end
  end

  defp await_worker(
         pid,
         monitor_ref,
         caller_guard,
         reply_alias,
         reply_ref,
         cancel_monitor,
         timeout_ms,
         timeout_cleanup_hook
       ) do
    {guard, guard_monitor} = caller_guard_identity(caller_guard)

    receive do
      {^reply_ref, result} ->
        demonitor_cancel_target(cancel_monitor)
        Process.unalias(reply_alias)
        await_down(pid, monitor_ref)
        release_caller_guard(caller_guard)
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, :killed} ->
        demonitor_cancel_target(cancel_monitor)
        Process.unalias(reply_alias)
        release_caller_guard(caller_guard)
        {:error, :heap_exceeded}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        demonitor_cancel_target(cancel_monitor)
        Process.unalias(reply_alias)
        release_caller_guard(caller_guard)
        {:error, :worker_failed}

      {:DOWN, ^guard_monitor, :process, ^guard, _reason} ->
        demonitor_cancel_target(cancel_monitor)
        terminate(pid, monitor_ref, reply_alias, reply_ref)
        {:error, :worker_failed}

      {:DOWN, cancel_ref, :process, cancel_pid, _reason}
      when cancel_monitor == {cancel_pid, cancel_ref} ->
        terminate(pid, monitor_ref, reply_alias, reply_ref)
        release_caller_guard(caller_guard)

        {:error, :cancelled}
    after
      timeout_ms ->
        demonitor_cancel_target(cancel_monitor)
        run_timeout_cleanup_hook(timeout_cleanup_hook)

        terminate(pid, monitor_ref, reply_alias, reply_ref)
        release_caller_guard(caller_guard)

        {:error, :timeout}
    end
  end

  defp start_worker(function, reply_alias, reply_ref, max_heap_words, false) do
    {pid, monitor_ref} = spawn_worker(function, reply_alias, reply_ref, max_heap_words)
    {:ok, pid, monitor_ref, nil}
  end

  defp start_worker(function, reply_alias, reply_ref, max_heap_words, true) do
    caller = self()
    guard_ref = make_ref()

    {guard, guard_monitor} =
      spawn_monitor(fn ->
        caller_guard(caller, guard_ref, function, reply_alias, reply_ref, max_heap_words)
      end)

    receive do
      {^guard_ref, pid, start_ref} ->
        worker_monitor = Process.monitor(pid)
        send(pid, {start_ref, :run})
        {:ok, pid, worker_monitor, {guard, guard_monitor, guard_ref}}

      {:DOWN, ^guard_monitor, :process, ^guard, _reason} ->
        {:error, :worker_failed}
    end
  end

  defp spawn_worker(function, reply_alias, reply_ref, max_heap_words) do
    Process.spawn(
      fn -> send(reply_alias, {reply_ref, function.()}) end,
      worker_spawn_options(max_heap_words)
    )
  end

  defp caller_guard(caller, guard_ref, function, reply_alias, reply_ref, max_heap_words) do
    caller_ref = Process.monitor(caller)
    start_ref = make_ref()

    {worker, worker_ref} =
      spawn_guarded_worker(function, reply_alias, reply_ref, max_heap_words, start_ref)

    send(caller, {guard_ref, worker, start_ref})
    guard_worker(caller, caller_ref, guard_ref, worker, worker_ref)
  end

  defp spawn_guarded_worker(function, reply_alias, reply_ref, max_heap_words, start_ref) do
    Process.spawn(
      fn ->
        receive do
          {^start_ref, :run} -> send(reply_alias, {reply_ref, function.()})
        end
      end,
      worker_spawn_options(max_heap_words)
    )
  end

  defp worker_spawn_options(max_heap_words) do
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
  end

  defp guard_worker(caller, caller_ref, guard_ref, worker, worker_ref) do
    receive do
      {^guard_ref, :release} ->
        Process.demonitor(caller_ref, [:flush])
        Process.demonitor(worker_ref, [:flush])
        :ok

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        Process.exit(worker, :kill)
        await_down(worker, worker_ref)

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        guard_after_worker(caller, caller_ref, guard_ref)
    end
  end

  defp guard_after_worker(caller, caller_ref, guard_ref) do
    receive do
      {^guard_ref, :release} ->
        Process.demonitor(caller_ref, [:flush])
        :ok

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        :ok
    end
  end

  defp release_caller_guard(nil), do: :ok

  defp release_caller_guard({guard, guard_monitor, guard_ref}) do
    send(guard, {guard_ref, :release})
    await_down(guard, guard_monitor)
  end

  defp caller_guard_identity(nil), do: {nil, nil}
  defp caller_guard_identity({guard, guard_monitor, _guard_ref}), do: {guard, guard_monitor}

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
