defmodule PtcRunner.Kernel.Evaluation do
  @moduledoc """
  Internal subordinate PTC-Lisp evaluation boundary.

  Evaluation reserves the single transactional mission-continuation lease,
  executes source exclusively against a mission environment, and commits
  candidate memory/history only after successful bounded completion. Every
  failure path releases the lease without changing the prior continuation.

  An ordinary successful value is projected as `:continued`; an explicit
  `(return value)` is projected as `:returned`; and `(fail value)` is projected
  as `:failed`. Failed results report whether capability activity occurred,
  whether the failure value is the exact result of the last recorded capability
  call, and whether correcting the program is effect-safe. The latter says only
  that the evaluation performed no write or unknown effect; callers combine all
  three facts with the bounded failure shape before requesting a correction.
  Terminal provider-policy provenance is reported separately. It is derived
  from the private tool ledger for normal outcomes and from the evaluation
  owner for sandbox hard stops, so a later expression failure, timeout, or heap
  kill cannot erase it.

  Continued and returned evaluations atomically commit native memory and exact
  bounded history before exposing only an inert public value. Continued results
  additionally expose bounded chronological prints for the next agent turn.
  Runtime-tool results use the strict `:kernel_json` projection and reject
  ambiguous collections. Code-owned analysis sessions opt into the preserving
  `:public` projection because their trusted frontend formats an Elixir
  observation rather than returning JSON to workflow Lisp.
  """

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.ProjectionError
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.TrustedTool

  @doc "Evaluates bounded subordinate source with optional canonical event collection."
  @spec evaluate_source(RunState.t(), map(), binary(), non_neg_integer()) :: map()
  def evaluate_source(state, mission_environment, source, timeout_ms) when is_binary(source) do
    state
    |> evaluate_source_detailed(mission_environment, source, timeout_ms, nil, nil)
    |> legacy_projection()
  end

  @spec evaluate_source(RunState.t(), map(), binary(), non_neg_integer(), term()) :: map()
  def evaluate_source(state, mission_environment, source, timeout_ms, event_sink)
      when is_binary(source) do
    state
    |> evaluate_source_detailed(mission_environment, source, timeout_ms, event_sink, nil)
    |> legacy_projection()
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
    state
    |> evaluate_source_detailed(
      mission_environment,
      source,
      timeout_ms,
      event_sink,
      inspection_sink
    )
    |> legacy_projection()
  end

  @doc false
  @spec evaluate_source_detailed(
          RunState.t(),
          map(),
          binary(),
          non_neg_integer(),
          term(),
          term(),
          keyword()
        ) :: map()
  def evaluate_source_detailed(
        state,
        mission_environment,
        source,
        timeout_ms,
        event_sink \\ nil,
        inspection_sink \\ nil,
        opts \\ []
      )
      when is_binary(source) and is_list(opts) do
    evaluation_id = Events.id("mission-evaluation")
    started_ms = System.monotonic_time(:millisecond)

    projection_boundary =
      opts
      |> Keyword.get(:projection_boundary, :kernel_json)
      |> validate_projection_boundary!()

    result =
      evaluate_detailed(
        state,
        mission_environment,
        source,
        timeout_ms,
        %{event_sink: event_sink, inspection_sink: inspection_sink},
        {
          evaluation_id,
          started_ms,
          Keyword.get(opts, :after_started_hook),
          projection_boundary
        }
      )

    result
    |> Map.put(:evaluation_id, evaluation_id)
    |> Map.put_new(:duration_ms, Events.duration_ms(started_ms))
    |> Map.put_new(:continuation_effect, :preserved)
  end

  defp evaluate_detailed(
         state,
         mission_environment,
         source,
         timeout_ms,
         capture,
         evaluation_context
       ) do
    with :ok <- source_within_limit(source, RunState.limits(state).subordinate_source_bytes),
         {:ok, memory, history, lease} <- RunState.reserve_evaluation(state) do
      evaluate_with_lease(
        state,
        mission_environment,
        source,
        timeout_ms,
        {memory, history, lease},
        capture,
        evaluation_context
      )
    else
      {:error, :busy} ->
        failure(:busy, :evaluation_in_progress)

      {:error, :limit_exceeded} ->
        preflight_limit(state, capture.event_sink, :limit_exceeded, :subordinate_evaluations)

      {:error, :source_exceeded} ->
        preflight_limit(state, capture.event_sink, :result_exceeded, :subordinate_source_bytes)

      {:error, :run_closed} ->
        preflight_limit(state, capture.event_sink, :limit_exceeded, :run_closed)

      {:error, :deadline_expired} ->
        preflight_limit(state, capture.event_sink, :limit_exceeded, :deadline_expired)
    end
  end

  defp evaluate_with_lease(
         state,
         environment,
         source,
         timeout_ms,
         {memory, history, lease},
         capture,
         {evaluation_id, started_ms, after_started_hook, projection_boundary}
       ) do
    limits = RunState.limits(state)

    timeout_ms =
      Enum.min([timeout_ms, limits.evaluation_timeout_ms, RunState.remaining_ms(state)])

    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    source_hash = sha256(source)
    source_bytes = byte_size(source)

    with :ok <-
           inspection_source(
             capture.inspection_sink,
             evaluation_id,
             source,
             source_hash,
             source_bytes
           ),
         :ok <-
           Events.emit(state, capture.event_sink, "evaluation-started", %{
             evaluation_id: evaluation_id,
             environment: :mission,
             program_kind: :"ptc-lisp",
             source_hash: source_hash,
             source_bytes: source_bytes
           }),
         :ok <- after_started(after_started_hook) do
      result =
        execute_with_lease(
          state,
          environment,
          source,
          timeout_ms,
          {memory, history, lease},
          capture,
          deadline_ms,
          projection_boundary
        )

      _ = maybe_emit_limit(state, capture.event_sink, result)

      duration_ms = Events.duration_ms(started_ms)

      _ =
        Events.emit(state, capture.event_sink, "evaluation-stopped", %{
          evaluation_id: evaluation_id,
          environment: :mission,
          status: result.outcome,
          continuation: RunState.evaluation_memory_summary(state),
          duration_ms: duration_ms
        })

      Map.put(result, :duration_ms, duration_ms)
    else
      {:error, :inspection_sink_error} ->
        :ok = RunState.release_evaluation(state, lease)
        :ok = RunState.fail(state, :inspection_sink_error, :inspection_sink_error)
        failure(:evaluation_error, :inspection_sink_error)

      {:error, :event_sink_error} ->
        :ok = RunState.release_evaluation(state, lease)
        failure(:evaluation_error, :event_sink_error)

      {:error, :evaluation_hook_error} ->
        :ok = RunState.release_evaluation(state, lease)
        failure(:evaluation_error, :evaluation_hook_error)
    end
  end

  defp after_started(nil), do: :ok

  defp after_started(hook) when is_function(hook, 0) do
    case hook.() do
      :ok -> :ok
      _other -> {:error, :evaluation_hook_error}
    end
  rescue
    _exception -> {:error, :evaluation_hook_error}
  catch
    _kind, _reason -> {:error, :evaluation_hook_error}
  end

  defp after_started(_hook), do: {:error, :evaluation_hook_error}

  defp validate_projection_boundary!(boundary) when boundary in [:public, :kernel_json],
    do: boundary

  defp validate_projection_boundary!(boundary) do
    raise ArgumentError,
          "invalid projection boundary #{inspect(boundary)}; expected :public or :kernel_json"
  end

  defp execute_with_lease(
         state,
         environment,
         source,
         timeout_ms,
         {memory, history, lease},
         capture,
         deadline_ms,
         projection_boundary
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
      preserve_runtime_callables: true,
      link: true
    ]

    mission_calls_before = mission_capability_calls(state)

    case Lisp.run_native(source, options) do
      {:ok, %{return: {:__ptc_fail__, value}} = step} ->
        release_explicit_failure(
          state,
          environment,
          lease,
          step,
          value,
          mission_calls_before,
          projection_boundary
        )
        |> put_terminal_provider_failure(step)

      {:ok, step} ->
        commit_result(state, lease, history, step, projection_boundary)
        |> put_terminal_provider_failure(step)

      {:error, step} ->
        release_failure(state, environment, lease, step, mission_calls_before)
        |> put_terminal_provider_failure(step)
    end
  end

  defp commit_result(state, lease, history, step, projection_boundary) do
    case Lisp.project_boundary_value(step.return, projection_boundary) do
      {:ok, projected_return} ->
        commit_projected_result(state, lease, history, step, projected_return)

      {:error, reason} ->
        :ok = RunState.release_evaluation(state, lease)
        projection_failure(step, reason)
    end
  end

  defp commit_projected_result(state, lease, history, step, projected_return) do
    candidate_history = history_after_success(history, step.return)

    case RunState.commit_evaluation(state, lease, step.memory, candidate_history) do
      :ok ->
        step
        |> classify_success(projected_return)
        |> Map.put(
          :continuation_effect,
          if(match?({:__ptc_return__, _value}, step.return),
            do: :committed_without_history,
            else: :committed_with_history
          )
        )

      {:error, :memory_exceeded} ->
        %{
          outcome: :memory_exceeded,
          prints: Map.get(step, :prints, []),
          continuation_effect: :preserved
        }

      {:error, :history_exceeded} ->
        %{
          outcome: :history_exceeded,
          prints: Map.get(step, :prints, []),
          continuation_effect: :preserved
        }

      {:error, :run_closed} ->
        case RunState.terminal_failure(state) do
          %{kind: kind, reason: reason} ->
            %{
              outcome: kind,
              kind: kind,
              reason: reason,
              prints: Map.get(step, :prints, []),
              continuation_effect: :preserved
            }

          nil ->
            %{
              outcome: :limit_exceeded,
              kind: :limit_exceeded,
              reason: :run_closed,
              prints: Map.get(step, :prints, []),
              continuation_effect: :preserved
            }
        end

      {:error, reason} ->
        %{
          outcome: :evaluation_error,
          kind: :state,
          reason: reason,
          prints: Map.get(step, :prints, []),
          continuation_effect: :preserved
        }
    end
  end

  defp classify_success(step, {:__ptc_return__, value}) do
    %{
      outcome: :returned,
      value: value,
      prints: Map.get(step, :prints, [])
    }
  end

  defp classify_success(step, value) do
    %{
      outcome: :continued,
      value: value,
      prints: step.prints
    }
  end

  defp projection_failure(step, reason) do
    %{
      outcome: :evaluation_error,
      kind: ProjectionError.kind(reason),
      details: %{projection_error: inspect(reason, limit: 10)},
      prints: Map.get(step, :prints, []),
      continuation_effect: :preserved,
      retryable?: false
    }
  end

  defp history_after_success(history, {:__ptc_return__, _value}), do: history
  defp history_after_success(history, value), do: Enum.take(history ++ [value], -3)

  defp release_explicit_failure(
         state,
         environment,
         lease,
         step,
         value,
         mission_calls_before,
         projection_boundary
       ) do
    {capability_activity?, unsafe_activity?} =
      evaluation_activity(state, environment, step, mission_calls_before)

    capability_failure? = capability_failure?(step, value)

    :ok = RunState.release_evaluation(state, lease)

    case Lisp.project_boundary_value(value, projection_boundary) do
      {:ok, projected} ->
        %{
          outcome: :failed,
          value: projected,
          prints: Map.get(step, :prints, []),
          continuation_effect: :preserved,
          capability_activity?: capability_activity?,
          capability_failure?: capability_failure?,
          retryable?: not unsafe_activity?
        }

      {:error, reason} ->
        projection_failure(step, reason)
    end
  end

  defp release_failure(state, environment, lease, step, mission_calls_before) do
    # Retryability asks a narrower question than "did anything happen": it asks
    # whether repeating the program could repeat an effect the Kernel cannot undo.
    # A program that read three pages and then exhausted its heap committed
    # nothing, so refusing the retry only spends the agent's remaining turns
    # protecting state that was never mutated. Effects are declared by the host
    # installation, and anything not declared `:read` — including `:unknown` —
    # counts as unsafe, so an undeclared capability keeps the old behaviour.
    {capability_activity?, unsafe_activity?} =
      evaluation_activity(state, environment, step, mission_calls_before)

    {:ok, evaluation_status} = RunState.release_evaluation_status(state, lease)

    details =
      step.fail
      |> Map.get(:details, %{})
      |> Map.put(:message, String.slice(step.fail.message || "evaluation failed", 0, 4_096))
      |> Map.put(:capability_activity?, capability_activity?)

    result = %{
      outcome: :evaluation_error,
      kind: step.fail.reason,
      details: details,
      prints: Map.get(step, :prints, []),
      continuation_effect: :preserved
    }

    result =
      case evaluation_retryable(step, unsafe_activity?) do
        retryable? when is_boolean(retryable?) -> Map.put(result, :retryable?, retryable?)
        nil -> result
      end

    if evaluation_status.terminal_provider_failure?,
      do: Map.put(result, :terminal_provider_failure?, true),
      else: result
  end

  defp evaluation_activity(state, environment, step, mission_calls_before) do
    capability_activity? =
      mission_capability_call_count(state) > call_total(mission_calls_before) or
        evaluator_capability_activity?(step)

    unsafe_activity? =
      unsafe_capability_activity?(state, environment, mission_calls_before) or
        unsafe_ledger_activity?(environment, step)

    {capability_activity?, unsafe_activity?}
  end

  defp evaluation_retryable(_step, true), do: false

  defp evaluation_retryable(
         %{fail: %{reason: :prelude_contract_error, details: %{phase: phase}}},
         false
       )
       when phase in [:input, :output],
       do: true

  # A resource kill says the query was too big, not that the world changed.
  defp evaluation_retryable(%{fail: %{reason: reason}}, false)
       when reason in [:memory_exceeded, :timeout, :parallel_capacity_exceeded],
       do: true

  # Any other failure with no unsafe effect: the program was wrong and nothing
  # the Kernel cannot undo was committed, so the loop's correction path applies.
  # Treating a read as activity that forbids a retry made that path unreachable
  # for any agent whose work begins by reading its evidence.
  defp evaluation_retryable(_step, false), do: nil

  # The counter path sees installed capabilities; the ledger also sees reserved
  # runtime routes, which are not capabilities and declare no effect. Both are
  # reads of frozen or in-process state, so they are named here rather than
  # falling through to "undeclared, therefore unsafe".
  defp unsafe_ledger_activity?(environment, step) do
    step
    |> Map.get(:tool_calls, [])
    |> List.wrap()
    |> Enum.any?(fn call ->
      case Map.get(call, :name) do
        name when is_binary(name) -> not read_only_tool?(environment, name)
        _other -> true
      end
    end)
  end

  defp read_only_tool?(environment, name) do
    read_only_capability?(environment, name) or
      name in RuntimeTools.mission_contract_descriptor()["routes"]
  end

  defp evaluator_capability_activity?(step) do
    tool_calls = Map.get(step, :tool_calls, [])
    ledger_activity? = is_list(tool_calls) and tool_calls != []

    marker_activity? =
      get_in(step, [Access.key(:fail), Access.key(:details), :capability_activity?]) == true

    ledger_activity? or marker_activity?
  end

  # An explicit failure is a capability failure only when evaluator provenance
  # says that a direct tool call or `cap/unwrap!` produced the control signal,
  # and the value matches the last recorded result. Merely rebuilding an equal
  # error-shaped map after a read cannot turn a deliberate failure into a
  # correction request.
  defp capability_failure?(step, value) do
    Map.get(step, :failure_origin) == :capability and
      step
      |> Map.get(:tool_calls, [])
      |> List.wrap()
      |> List.last()
      |> case do
        %{error: nil, result: result} -> result === value
        _other -> false
      end
  end

  defp put_terminal_provider_failure(result, step) do
    if terminal_provider_failure?(step),
      do: Map.put(result, :terminal_provider_failure?, true),
      else: result
  end

  defp terminal_provider_failure?(step) do
    step
    |> Map.get(:tool_calls, [])
    |> List.wrap()
    |> Enum.any?(fn
      %{result: %{status: :error, kind: :provider_error, reason: :denied}} ->
        true

      %{
        result: %{
          status: :error,
          kind: :provider_error,
          reason: :invalid_result,
          details: details
        }
      }
      when details in ["mcp_capability_negotiation_error", "mcp_protocol_error"] ->
        true

      _call ->
        false
    end)
  end

  defp mission_capability_call_count(state), do: call_total(mission_capability_calls(state))

  defp mission_capability_calls(state) do
    state
    |> RunState.usage()
    |> get_in([:capability_calls, :mission])
    |> Kernel.||(%{})
  end

  defp call_total(calls), do: calls |> Map.values() |> Enum.sum()

  # A capability counts as unsafe unless the installation declared it `:read`.
  # Names are compared against the frozen environment rather than the call
  # ledger, so a capability that vanished cannot be assumed harmless.
  defp unsafe_capability_activity?(state, environment, before) do
    state
    |> mission_capability_calls()
    |> Enum.any?(fn {name, count} ->
      count > Map.get(before, name, 0) and not read_only_capability?(environment, name)
    end)
  end

  defp read_only_capability?(environment, name) do
    case Map.fetch(environment.capabilities, name) do
      {:ok, %{effect: :read}} -> true
      _other -> false
    end
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

  defp failure(kind, reason),
    do: %{outcome: kind, kind: kind, reason: reason, continuation_effect: :preserved}

  defp preflight_limit(state, event_sink, kind, reason) do
    result = failure(kind, reason)
    _ = maybe_emit_limit(state, event_sink, result)
    result
  end

  defp legacy_projection(result) do
    result
    |> Map.drop([:continuation_effect, :duration_ms, :evaluation_id])
    |> maybe_drop_terminal_prints()
  end

  defp maybe_drop_terminal_prints(%{outcome: :continued} = result), do: result
  defp maybe_drop_terminal_prints(result), do: Map.delete(result, :prints)

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
