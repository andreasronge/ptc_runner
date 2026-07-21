defmodule PtcRunner.Lisp.Java.Oracle.Subprocess do
  @moduledoc false

  @default_timeout_ms 30_000
  @default_output_limit 1_000_000

  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, {:exit_status, non_neg_integer(), String.t()} | atom()}
  def run(executable, args, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    output_limit = Keyword.get(opts, :output_limit, @default_output_limit)
    env = Keyword.get(opts, :env, [])

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :hide,
        :use_stdio,
        :stderr_to_stdout,
        args: Enum.map(args, &String.to_charlist/1),
        env:
          Enum.map(env, fn {key, value} ->
            {String.to_charlist(key), String.to_charlist(value)}
          end)
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, [], 0, output_limit, deadline)
  end

  defp collect(port, chunks, size, output_limit, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, bytes}} when size + byte_size(bytes) <= output_limit ->
        collect(port, [bytes | chunks], size + byte_size(bytes), output_limit, deadline)

      {^port, {:data, _bytes}} ->
        close(port)
        {:error, :output_limit_exceeded}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status, chunks |> Enum.reverse() |> IO.iodata_to_binary()}}
    after
      remaining_ms ->
        close(port)
        {:error, :timeout}
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end
end
