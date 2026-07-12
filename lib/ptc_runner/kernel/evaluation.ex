defmodule PtcRunner.Kernel.Evaluation do
  @moduledoc false

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Lisp

  @spec evaluate_source(RunState.t(), map(), binary(), non_neg_integer()) :: map()
  def evaluate_source(state, mission_environment, source, timeout_ms) when is_binary(source) do
    evaluate_source(state, mission_environment, source, timeout_ms, nil)
  end

  @spec evaluate_source(RunState.t(), map(), binary(), non_neg_integer(), term()) :: map()
  def evaluate_source(state, mission_environment, source, timeout_ms, event_sink)
      when is_binary(source) do
    with :ok <- source_within_limit(source, RunState.limits(state).subordinate_source_bytes),
         {:ok, memory, lease} <- RunState.reserve_evaluation(state) do
      evaluate_with_lease(
        state,
        mission_environment,
        source,
        timeout_ms,
        memory,
        lease,
        event_sink
      )
    else
      {:error, :busy} -> failure(:busy, :evaluation_in_progress)
      {:error, :limit_exceeded} -> failure(:limit_exceeded, :subordinate_evaluations)
      {:error, :source_exceeded} -> failure(:result_exceeded, :subordinate_source_bytes)
      {:error, :run_closed} -> failure(:limit_exceeded, :run_closed)
    end
  end

  defp evaluate_with_lease(state, environment, source, timeout_ms, memory, lease, event_sink) do
    limits = RunState.limits(state)

    timeout_ms =
      Enum.min([timeout_ms, limits.evaluation_timeout_ms, RunState.remaining_ms(state)])

    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    evaluation_id = Events.id("mission-evaluation")
    started_ms = System.monotonic_time(:millisecond)

    case Events.emit(state, event_sink, "evaluation-started", %{
           evaluation_id: evaluation_id,
           environment: :mission
         }) do
      :ok ->
        result =
          execute_with_lease(
            state,
            environment,
            source,
            timeout_ms,
            memory,
            lease,
            event_sink,
            deadline_ms
          )

        _ = maybe_emit_limit(state, event_sink, result)

        _ =
          Events.emit(state, event_sink, "evaluation-stopped", %{
            evaluation_id: evaluation_id,
            environment: :mission,
            status: result.outcome,
            duration_ms: Events.duration_ms(started_ms)
          })

        result

      {:error, :event_sink_error} ->
        :ok = RunState.release_evaluation(state, lease)
        failure(:evaluation_error, :event_sink_error)
    end
  end

  defp execute_with_lease(
         state,
         environment,
         source,
         timeout_ms,
         memory,
         lease,
         event_sink,
         deadline_ms
       ) do
    limits = RunState.limits(state)

    options = [
      context: environment.data,
      memory: memory,
      tools: mission_tools(environment, state, timeout_ms, event_sink),
      prelude: bundle_prelude(environment),
      timeout: timeout_ms,
      compile_timeout: timeout_ms,
      run_deadline_ms: deadline_ms,
      max_heap: limits.evaluation_heap_words,
      max_program_bytes: limits.subordinate_source_bytes,
      filter_context: false,
      caller: :in_process_v1,
      preserve_runtime_callables: true
    ]

    case Lisp.run_native(source, options) do
      {:ok, %{return: {:__ptc_fail__, value}}} ->
        :ok = RunState.release_evaluation(state, lease)
        %{outcome: :failed, value: Lisp.externalize_value(value)}

      {:ok, step} ->
        commit_result(state, lease, step)

      {:error, step} ->
        release_failure(state, lease, step)
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

  defp mission_tools(environment, state, timeout_ms, event_sink) do
    environment.capabilities
    |> Map.new(fn {name, _capability} ->
      {name,
       fn arguments ->
         Dispatcher.dispatch(
           state,
           :mission,
           environment,
           name,
           arguments,
           timeout_ms,
           event_sink
         )
       end}
    end)
    |> Map.merge(RuntimeTools.tools(state, environment, event_sink, :mission))
  end

  defp bundle_prelude(%{bundle: %{prelude: prelude}}), do: prelude
  defp bundle_prelude(_environment), do: nil

  defp source_within_limit(source, limit),
    do: if(byte_size(source) <= limit, do: :ok, else: {:error, :source_exceeded})

  defp returned_value({:__ptc_return__, value}), do: value
  defp returned_value(value), do: value
  defp failure(kind, reason), do: %{outcome: kind, kind: kind, reason: reason}

  defp maybe_emit_limit(state, event_sink, %{outcome: outcome} = result)
       when outcome in [:timeout, :memory_exceeded, :result_exceeded, :limit_exceeded] do
    Events.emit(state, event_sink, "limit-exceeded", %{
      reason: Map.get(result, :reason, outcome),
      environment: :mission
    })
  end

  defp maybe_emit_limit(_state, _event_sink, _result), do: :ok
end
