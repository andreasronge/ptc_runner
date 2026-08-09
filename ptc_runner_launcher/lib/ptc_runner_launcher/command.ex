defmodule PtcRunnerLauncher.Command do
  @moduledoc false

  @spec run(binary(), [binary()], pos_integer()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, :timeout | :command_failed}
  def run(executable, arguments, timeout_ms)
      when is_binary(executable) and is_list(arguments) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      run_linked(executable, arguments, timeout_ms)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp run_linked(executable, arguments, timeout_ms) do
    reply_alias = Process.alias()

    {worker, monitor} =
      Process.spawn(
        fn ->
          result =
            try do
              {:ok, System.cmd(executable, arguments, stderr_to_stdout: true)}
            rescue
              _exception -> {:error, :command_failed}
            catch
              _kind, _reason -> {:error, :command_failed}
            end

          send(reply_alias, {self(), result})
        end,
        [:link, :monitor]
      )

    receive do
      {^worker, result} ->
        Process.unalias(reply_alias)
        await_down(worker, monitor)
        Process.unlink(worker)
        drain_exit(worker)
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        Process.unalias(reply_alias)
        Process.unlink(worker)
        drain_exit(worker)
        {:error, :command_failed}
    after
      timeout_ms ->
        Process.unalias(reply_alias)
        Process.exit(worker, :kill)
        await_down(worker, monitor)
        Process.unlink(worker)
        drain_exit(worker)
        {:error, :timeout}
    end
  end

  defp await_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp drain_exit(worker) do
    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      0 -> :ok
    end
  end
end
