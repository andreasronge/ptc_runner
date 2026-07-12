defmodule PtcRunner.Kernel.BoundedWorker do
  @moduledoc false

  @spec run((-> term()), keyword()) ::
          {:ok, term()} | {:error, :timeout | :heap_exceeded | :worker_failed}
  def run(function, opts) when is_function(function, 0) and is_list(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    max_heap_words = Keyword.fetch!(opts, :max_heap_words)
    reply_alias = Process.alias()
    reply_ref = make_ref()

    {pid, monitor_ref} =
      Process.spawn(
        fn -> send(reply_alias, {reply_ref, function.()}) end,
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

    receive do
      {^reply_ref, result} ->
        Process.unalias(reply_alias)
        Process.demonitor(monitor_ref, [:flush])
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, :killed} ->
        Process.unalias(reply_alias)
        {:error, :heap_exceeded}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        Process.unalias(reply_alias)
        {:error, :worker_failed}
    after
      timeout_ms ->
        :ok = terminate(pid, monitor_ref, reply_alias, reply_ref)
        {:error, :timeout}
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

    receive do
      {^reply_ref, _late_result} -> :ok
    after
      0 -> :ok
    end
  end
end
