defmodule PtcRunner.Kernel.Evaluation do
  @moduledoc false

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp

  @spec evaluate_source(RunState.t(), map(), binary(), non_neg_integer()) :: map()
  def evaluate_source(state, mission_environment, source, timeout_ms) when is_binary(source) do
    with :ok <- source_within_limit(source, RunState.limits(state).subordinate_source_bytes),
         {:ok, memory, lease} <- RunState.reserve_evaluation(state) do
      evaluate_with_lease(state, mission_environment, source, timeout_ms, memory, lease)
    else
      {:error, :busy} -> failure(:busy, :evaluation_in_progress)
      {:error, :limit_exceeded} -> failure(:limit_exceeded, :subordinate_evaluations)
      {:error, :source_exceeded} -> failure(:result_exceeded, :subordinate_source_bytes)
      {:error, :run_closed} -> failure(:limit_exceeded, :run_closed)
    end
  end

  defp evaluate_with_lease(state, environment, source, timeout_ms, memory, lease) do
    limits = RunState.limits(state)

    options = [
      context: environment.data,
      memory: memory,
      tools: mission_tools(environment, state, timeout_ms),
      timeout: min(timeout_ms, limits.evaluation_timeout_ms),
      max_heap: limits.evaluation_heap_words,
      max_program_bytes: limits.subordinate_source_bytes,
      filter_context: false,
      caller: :in_process_v1,
      preserve_runtime_callables: true
    ]

    case Lisp.run_native(source, options) do
      {:ok, step} -> commit_result(state, lease, step)
      {:error, step} -> release_failure(state, lease, step)
    end
  end

  defp commit_result(state, lease, step) do
    case RunState.commit_evaluation(state, lease, step.memory) do
      :ok ->
        %{outcome: :returned, value: step.return |> returned_value() |> Lisp.externalize_value()}

      {:error, :memory_exceeded} ->
        %{outcome: :memory_exceeded}

      {:error, _reason} ->
        %{outcome: :evaluation_error, kind: :state}
    end
  end

  defp release_failure(state, lease, step) do
    :ok = RunState.release_evaluation(state, lease)

    %{
      outcome: :evaluation_error,
      kind: step.fail.reason,
      details: %{message: String.slice(step.fail.message || "evaluation failed", 0, 4_096)}
    }
  end

  defp mission_tools(environment, state, timeout_ms) do
    Map.new(environment.capabilities, fn {name, _capability} ->
      {name,
       fn arguments ->
         Dispatcher.dispatch(state, :mission, environment, name, arguments, timeout_ms)
       end}
    end)
  end

  defp source_within_limit(source, limit),
    do: if(byte_size(source) <= limit, do: :ok, else: {:error, :source_exceeded})

  defp returned_value({:__ptc_return__, value}), do: value
  defp returned_value(value), do: value
  defp failure(kind, reason), do: %{outcome: kind, kind: kind, reason: reason}
end
