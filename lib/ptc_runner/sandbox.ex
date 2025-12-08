defmodule PtcRunner.Sandbox do
  @moduledoc """
  Executes programs in isolated BEAM processes with resource limits.

  Spawns isolated processes with configurable timeout and memory limits,
  ensuring safe program execution.
  """

  alias PtcRunner.Context
  alias PtcRunner.Json.Interpreter

  @typedoc """
  Execution metrics for a program run.
  """
  @type metrics :: %{
          duration_ms: integer(),
          memory_bytes: integer()
        }

  @doc """
  Executes an AST in an isolated sandbox process.

  ## Arguments
    - ast: The AST to execute
    - context: The execution context
    - opts: Options (timeout, max_heap)

  ## Returns
    - `{:ok, result, metrics}` on success
    - `{:error, reason}` on failure
  """
  @spec execute(map(), Context.t(), keyword()) ::
          {:ok, any(), metrics()} | {:error, {atom(), non_neg_integer()} | {atom(), String.t()}}

  def execute(ast, context, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    max_heap = Keyword.get(opts, :max_heap, 1_250_000)

    # Spawn isolated process with resource limits
    start_time = System.monotonic_time(:millisecond)

    parent = self()

    {pid, ref} =
      Process.spawn(
        fn ->
          # Set process priority to normal within the process
          Process.flag(:priority, :normal)
          result = Interpreter.eval(ast, context)
          memory = get_process_memory()
          send(parent, {:result, result, memory})
        end,
        [:monitor, {:max_heap_size, max_heap}]
      )

    # Wait for result with timeout
    receive do
      {:result, result, memory} ->
        end_time = System.monotonic_time(:millisecond)
        duration = end_time - start_time

        Process.demonitor(ref, [:flush])

        case result do
          {:ok, value} ->
            {:ok, value, %{duration_ms: duration, memory_bytes: memory}}

          {:error, reason} ->
            {:error, reason}
        end

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error, {:memory_exceeded, max_heap * 8}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:execution_error, "Process terminated: #{inspect(reason)}"}}
    after
      timeout ->
        # Kill the process if it times out
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        {:error, {:timeout, timeout}}
    end
  end

  defp get_process_memory do
    case Process.info(self(), :memory) do
      {:memory, bytes} -> bytes
      nil -> 0
    end
  end
end
