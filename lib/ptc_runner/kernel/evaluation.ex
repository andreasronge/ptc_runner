defmodule PtcRunner.Kernel.Evaluation do
  @moduledoc """
  Internal subordinate PTC-Lisp evaluation boundary.

  Evaluation reserves the single transactional mission-continuation lease,
  executes source exclusively against a mission environment, and commits
  candidate memory/history only after successful bounded completion. Every
  failure path releases the lease without changing the prior continuation.

  An ordinary successful value is projected as `:continued`; an explicit
  `(return value)` is projected as `:returned`; and `(fail value)` is projected
  as `:failed`. Continued and returned evaluations atomically commit native
  memory and exact bounded history before exposing only an inert public value.
  Continued results additionally expose bounded chronological prints for the
  next agent turn.
  """

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.TrustedTool

  @doc "Evaluates bounded subordinate source with optional canonical event collection."
  @spec evaluate_source(RunState.t(), map(), binary(), non_neg_integer()) :: map()
  def evaluate_source(state, mission_environment, source, timeout_ms) when is_binary(source) do
    evaluate_source(state, mission_environment, source, timeout_ms, nil, nil)
  end

  @spec evaluate_source(RunState.t(), map(), binary(), non_neg_integer(), term()) :: map()
  def evaluate_source(state, mission_environment, source, timeout_ms, event_sink)
      when is_binary(source) do
    evaluate_source(state, mission_environment, source, timeout_ms, event_sink, nil)
  end

  @spec evaluate_source(RunState.t(), map(), binary(), non_neg_integer(), term(), term()) :: map()
  def evaluate_source(
        state,
        mission_environment,
        source,
        timeout_ms,
        event_sink,
        inspection_sink
      )
      when is_binary(source) do
    with :ok <- source_within_limit(source, RunState.limits(state).subordinate_source_bytes),
         {:ok, memory, history, lease} <- RunState.reserve_evaluation(state) do
      evaluate_with_lease(
        state,
        mission_environment,
        source,
        timeout_ms,
        {memory, history, lease},
        event_sink,
        inspection_sink
      )
    else
      {:error, :busy} -> failure(:busy, :evaluation_in_progress)
      {:error, :limit_exceeded} -> failure(:limit_exceeded, :subordinate_evaluations)
      {:error, :source_exceeded} -> failure(:result_exceeded, :subordinate_source_bytes)
      {:error, :run_closed} -> failure(:limit_exceeded, :run_closed)
    end
  end

  defp evaluate_with_lease(
         state,
         environment,
         source,
         timeout_ms,
         {memory, history, lease},
         event_sink,
         inspection_sink
       ) do
    limits = RunState.limits(state)

    timeout_ms =
      Enum.min([timeout_ms, limits.evaluation_timeout_ms, RunState.remaining_ms(state)])

    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    evaluation_id = Events.id("mission-evaluation")
    started_ms = System.monotonic_time(:millisecond)
    source_hash = sha256(source)
    source_bytes = byte_size(source)

    with :ok <-
           inspection_source(
             inspection_sink,
             evaluation_id,
             source,
             source_hash,
             source_bytes
           ),
         :ok <-
           Events.emit(state, event_sink, "evaluation-started", %{
             evaluation_id: evaluation_id,
             environment: :mission,
             program_kind: :"ptc-lisp",
             source_hash: source_hash,
             source_bytes: source_bytes
           }) do
      result =
        execute_with_lease(
          state,
          environment,
          source,
          timeout_ms,
          {memory, history, lease},
          %{event_sink: event_sink, inspection_sink: inspection_sink},
          deadline_ms
        )

      _ = maybe_emit_limit(state, event_sink, result)

      _ =
        Events.emit(state, event_sink, "evaluation-stopped", %{
          evaluation_id: evaluation_id,
          environment: :mission,
          status: result.outcome,
          continuation: RunState.evaluation_memory_summary(state),
          duration_ms: Events.duration_ms(started_ms)
        })

      result
    else
      {:error, :inspection_sink_error} ->
        :ok = RunState.release_evaluation(state, lease)
        :ok = RunState.fail(state, :inspection_sink_error, :inspection_sink_error)
        failure(:evaluation_error, :inspection_sink_error)

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
         {memory, history, lease},
         capture,
         deadline_ms
       ) do
    limits = RunState.limits(state)

    options = [
      context: environment.data,
      memory: memory,
      turn_history: history,
      tools:
        mission_tools(
          environment,
          state,
          timeout_ms,
          capture.event_sink,
          capture.inspection_sink
        ),
      prelude: bundle_prelude(environment),
      timeout: timeout_ms,
      compile_timeout: timeout_ms,
      run_deadline_ms: deadline_ms,
      max_heap: limits.evaluation_heap_words,
      max_program_bytes: limits.subordinate_source_bytes,
      filter_context: false,
      caller: :kernel,
      preserve_runtime_callables: true
    ]

    mission_calls_before = mission_capability_call_count(state)

    case Lisp.run_native(source, options) do
      {:ok, %{return: {:__ptc_fail__, value}}} ->
        :ok = RunState.release_evaluation(state, lease)
        %{outcome: :failed, value: Lisp.externalize_value(value)}

      {:ok, step} ->
        commit_result(state, lease, history, step)

      {:error, step} ->
        release_failure(state, lease, step, mission_calls_before)
    end
  end

  defp commit_result(state, lease, history, step) do
    candidate_history = history_after_success(history, step.return)

    case RunState.commit_evaluation(state, lease, step.memory, candidate_history) do
      :ok ->
        classify_success(step)

      {:error, :memory_exceeded} ->
        %{outcome: :memory_exceeded}

      {:error, :history_exceeded} ->
        %{outcome: :history_exceeded}

      {:error, _reason} ->
        %{outcome: :evaluation_error, kind: :state}
    end
  end

  defp classify_success(%{return: {:__ptc_return__, value}}) do
    %{outcome: :returned, value: Lisp.externalize_value(value)}
  end

  defp classify_success(step) do
    %{
      outcome: :continued,
      value: Lisp.externalize_value(step.return),
      prints: step.prints || []
    }
  end

  defp history_after_success(history, {:__ptc_return__, _value}), do: history
  defp history_after_success(history, value), do: Enum.take(history ++ [value], -3)

  defp release_failure(state, lease, step, mission_calls_before) do
    capability_activity? =
      mission_capability_call_count(state) > mission_calls_before or
        evaluator_capability_activity?(step)

    :ok = RunState.release_evaluation(state, lease)

    details =
      step.fail
      |> Map.get(:details, %{})
      |> Map.put(:message, String.slice(step.fail.message || "evaluation failed", 0, 4_096))
      |> Map.put(:capability_activity?, capability_activity?)

    result = %{
      outcome: :evaluation_error,
      kind: step.fail.reason,
      details: details
    }

    case evaluation_retryable(step, capability_activity?) do
      retryable? when is_boolean(retryable?) -> Map.put(result, :retryable?, retryable?)
      nil -> result
    end
  end

  defp evaluation_retryable(_step, true), do: false

  defp evaluation_retryable(
         %{fail: %{reason: :prelude_contract_error, details: %{phase: phase}}},
         false
       )
       when phase in [:input, :output],
       do: true

  defp evaluation_retryable(_step, false), do: nil

  defp evaluator_capability_activity?(step) do
    tool_calls = Map.get(step, :tool_calls, [])
    ledger_activity? = is_list(tool_calls) and tool_calls != []

    marker_activity? =
      get_in(step, [Access.key(:fail), Access.key(:details), :capability_activity?]) == true

    ledger_activity? or marker_activity?
  end

  defp mission_capability_call_count(state) do
    state
    |> RunState.usage()
    |> get_in([:capability_calls, :mission])
    |> Map.values()
    |> Enum.sum()
  end

  defp mission_tools(environment, state, timeout_ms, event_sink, inspection_sink) do
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
           event_sink,
           inspection_sink
         )
       end}
    end)
    |> Map.merge(RuntimeTools.tools(state, environment, event_sink, :mission))
    |> Map.new(fn {name, callback} -> {name, %TrustedTool{function: callback}} end)
  end

  defp bundle_prelude(%{bundle: %{prelude: prelude}}), do: prelude
  defp bundle_prelude(_environment), do: nil

  defp source_within_limit(source, limit),
    do: if(byte_size(source) <= limit, do: :ok, else: {:error, :source_exceeded})

  defp failure(kind, reason), do: %{outcome: kind, kind: kind, reason: reason}

  defp maybe_emit_limit(state, event_sink, %{outcome: outcome} = result)
       when outcome in [
              :timeout,
              :memory_exceeded,
              :history_exceeded,
              :result_exceeded,
              :limit_exceeded
            ] do
    Events.emit(state, event_sink, "limit-exceeded", %{
      reason: Map.get(result, :reason, outcome),
      environment: :mission
    })
  end

  defp maybe_emit_limit(_state, _event_sink, _result), do: :ok

  defp inspection_source(nil, _evaluation_id, _source, _source_hash, _source_bytes), do: :ok

  defp inspection_source(sink, evaluation_id, source, source_hash, source_bytes) do
    InspectionSink.emit(
      sink,
      "evaluation-source",
      %{evaluation_id: evaluation_id},
      %{
        environment: :mission,
        program_kind: :"ptc-lisp",
        source: source,
        source_hash: source_hash,
        source_bytes: source_bytes
      }
    )
  end

  defp sha256(source),
    do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
end
