defmodule PtcRunnerLauncher.Command do
  @moduledoc false

  @spec run(binary(), [binary()], pos_integer()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, :timeout | :command_failed}
  def run(executable, arguments, timeout_ms)
      when is_binary(executable) and is_list(arguments) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    reply_alias = Process.alias()

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          System.cmd(executable, arguments,
            stderr_to_stdout: true,
            parallelism: true
          )

        send(reply_alias, {self(), result})
      end)

    receive do
      {^worker, result} ->
        Process.unalias(reply_alias)
        await_down(worker, monitor)
        {:ok, result}

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        Process.unalias(reply_alias)
        {:error, :command_failed}
    after
      timeout_ms ->
        Process.unalias(reply_alias)
        Process.exit(worker, :kill)
        await_down(worker, monitor)
        {:error, :timeout}
    end
  end

  defp await_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end
end
