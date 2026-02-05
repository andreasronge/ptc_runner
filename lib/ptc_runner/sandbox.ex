defmodule PtcRunner.Sandbox do
  @moduledoc """
  Executes programs in isolated BEAM processes with resource limits.

  Spawns isolated processes with configurable timeout and memory limits,
  ensuring safe program execution.

  ## Resource Limits

  | Resource | Default | Option |
  |----------|---------|--------|
  | Timeout | 1,000 ms | `:timeout` |
  | Max Heap | ~10 MB (1,250,000 words) | `:max_heap` |

  ## Configuration

  Limits can be set per-call:

      PtcRunner.Json.run(program, timeout: 5000, max_heap: 5_000_000)

  Or as application-level defaults in `config.exs`:

      config :ptc_runner,
        default_timeout: 2000,
        default_max_heap: 2_500_000
  """

  alias PtcRunner.Context
  alias PtcRunner.Json.Interpreter

  # Default resource limits
  @default_timeout 1000
  @default_max_heap 1_250_000

  @typedoc """
  Execution metrics for a program run.
  """
  @type metrics :: %{
          duration_ms: integer(),
          memory_bytes: integer()
        }

  @typedoc """
  Evaluator function that takes AST and context and returns result with memory.
  """
  @type eval_fn :: (any(), Context.t() ->
                      {:ok, any(), map()}
                      | {:error, {atom(), String.t()} | {atom(), String.t(), any()}})

  @doc """
  Executes an AST in an isolated sandbox process.

  ## Arguments
    - ast: The AST to execute
    - context: The execution context
    - opts: Options (timeout, max_heap, eval_fn)
      - `:eval_fn` - Custom evaluator function (default: Interpreter.eval/2)
      - `:timeout` - Timeout in milliseconds (default: 1000, configurable via `:default_timeout`)
      - `:max_heap` - Max heap size in words (default: 1_250_000, configurable via `:default_max_heap`)

  ## Returns
    - `{:ok, result, metrics, memory}` on success
    - `{:error, reason}` on failure
  """
  @spec execute(any(), Context.t(), keyword()) ::
          {:ok, any(), metrics(), map()}
          | {:error,
             {atom(), non_neg_integer()} | {atom(), String.t()} | {atom(), String.t(), any()}}

  def execute(ast, context, opts \\ []) do
    default_timeout = Application.get_env(:ptc_runner, :default_timeout, @default_timeout)
    default_max_heap = Application.get_env(:ptc_runner, :default_max_heap, @default_max_heap)

    timeout = Keyword.get(opts, :timeout, default_timeout)
    max_heap = Keyword.get(opts, :max_heap, default_max_heap)
    eval_fn = Keyword.get(opts, :eval_fn, &Interpreter.eval/2)

    # Spawn isolated process with resource limits
    start_time = System.monotonic_time(:millisecond)

    parent = self()

    {pid, ref} =
      Process.spawn(
        fn ->
          # Set process priority to normal within the process
          Process.flag(:priority, :normal)
          result = eval_fn.(ast, context)
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
          {:ok, value, eval_memory} ->
            {:ok, value, %{duration_ms: duration, memory_bytes: memory}, eval_memory}

          {:error, reason, eval_ctx} ->
            # Error with eval_ctx (e.g., from tool execution error with recorded tool_calls)
            # Return as a 4-tuple success with error tagged in the value
            {:ok, {:error_with_ctx, reason}, %{duration_ms: duration, memory_bytes: memory},
             eval_ctx}

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
