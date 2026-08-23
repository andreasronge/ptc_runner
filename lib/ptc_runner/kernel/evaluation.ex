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

  Mission-scoped evaluation is strict for `data/<name>`: a missing grant is a
  runtime error that lists the same granted names the mission inventory
  publishes, calling a granted value is `not_callable` naming the symbol, and
  `data/params` without a supplied params map names `kernel/eval-with` and
  `kernel/eval-source-with`. `PtcRunner.Lisp.run/2` stays permissive.
  """

  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.ProjectionError
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.TerminalResultLimit
  alias PtcRunner.Kernel.ToolGrant
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.EvaluatorErrorCatalog
  alias PtcRunner.Lisp.DataKeys
  alias PtcRunner.Lisp.TrustedTool

  @missing_data_params_message "data/params is not available because this evaluation supplied no params. " <>
                                 "Pass a params map through kernel/eval-with or kernel/eval-source-with."

  @doc "Evaluates bounded subordinate source for an explicitly named mission."
  @spec evaluate_source(
          RunState.t(),
          binary(),
          map(),
          binary(),
          non_neg_integer(),
          term(),
          term(),
          keyword()
        ) :: map()
  def evaluate_source(
        state,
        mission_name,
        mission_environment,
        source,
        timeout_ms,
        event_sink \\ nil,
        inspection_sink \\ nil,
        opts \\ []
      )
      when is_binary(mission_name) and is_binary(source) and is_list(opts) do
    evaluation_id = Events.id("mission-evaluation")
    started_ms = System.monotonic_time(:millisecond)

    projection_boundary =
      opts
      |> Keyword.get(:projection_boundary, :kernel_json)
      |> validate_projection_boundary!()

    admission =
      opts
      |> Keyword.get(:admission, :fail_fast)
      |> validate_admission!()

    parent_evaluation_id =
      opts
      |> Keyword.get(:parent_evaluation_id)
      |> validate_parent_evaluation_id!()

    result_limit_bytes =
      opts
      |> Keyword.get(:result_limit_bytes)
      |> validate_result_limit!()

    result =
      evaluate_detailed(
        state,
        mission_environment,
        source,
        timeout_ms,
        %{event_sink: event_sink, inspection_sink: inspection_sink, admission: admission},
        {
          evaluation_id,
          started_ms,
          Keyword.get(opts, :after_started_hook),
          projection_boundary,
          Keyword.fetch(opts, :params),
          parent_evaluation_id,
          result_limit_bytes
        },
        mission_name
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
         evaluation_context,
         mission_name
       ) do
    admission = Map.get(capture, :admission, :fail_fast)

    with :ok <- source_within_limit(source, RunState.limits(state).subordinate_source_bytes),
         {:ok, memory, history, lease} <-
           RunState.reserve_evaluation_with_limit_proof(state, mission_name, admission) do
      evaluate_with_lease(
        state,
        mission_environment,
        source,
        timeout_ms,
        {memory, history, lease},
        capture,
        evaluation_context,
        mission_name
      )
    else
      {:error, :busy} ->
        failure(:busy, :evaluation_in_progress)

      {:error, :admission_timeout} ->
        failure(:busy, :admission_timeout)

      {:error, :limit_exceeded} ->
        preflight_limit(
          state,
          capture.event_sink,
          :limit_exceeded,
          :subordinate_evaluations,
          mission_name
        )

      {:error, {:limit_exceeded, proof}} ->
        state
        |> preflight_limit(
          capture.event_sink,
          :limit_exceeded,
          :subordinate_evaluations,
          mission_name
        )
        |> Map.put(:limit_proof, proof)

      {:error, :source_exceeded} ->
        preflight_limit(
          state,
          capture.event_sink,
          :result_exceeded,
          :subordinate_source_bytes,
          mission_name
        )

      {:error, :run_closed} ->
        preflight_limit(state, capture.event_sink, :limit_exceeded, :run_closed, mission_name)

      {:error, :deadline_expired} ->
        preflight_limit(
          state,
          capture.event_sink,
          :limit_exceeded,
          :deadline_expired,
          mission_name
        )
    end
  end

  defp evaluate_with_lease(
         state,
         environment,
         source,
         timeout_ms,
         {memory, history, lease},
         capture,
         {
           evaluation_id,
           started_ms,
           after_started_hook,
           projection_boundary,
           params,
           parent_evaluation_id,
           result_limit_bytes
         },
         mission_name
       ) do
    limits = RunState.limits(state)

    timeout_ms =
      Enum.min([timeout_ms, limits.evaluation_timeout_ms, RunState.remaining_ms(state)])

    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    source_hash = sha256(source)
    source_bytes = byte_size(source)

    with :ok <-
           Events.emit(
             state,
             capture.event_sink,
             "evaluation-started",
             put_parent_evaluation_id(
               %{
                 evaluation_id: evaluation_id,
                 environment: :mission,
                 mission_name: mission_name,
                 program_kind: :"ptc-lisp",
                 source_hash: source_hash,
                 source_bytes: source_bytes
               },
               parent_evaluation_id
             )
           ),
         :ok <-
           inspection_source(
             capture.inspection_sink,
             evaluation_id,
             source,
             source_hash,
             source_bytes,
             mission_name
           ),
         :ok <- after_started(after_started_hook) do
      result =
        execute_with_lease(
          state,
          environment,
          source,
          timeout_ms,
          {memory, history, lease},
          capture,
          {deadline_ms, projection_boundary, params, mission_name, evaluation_id,
           result_limit_bytes}
        )

      _ = maybe_emit_limit(state, capture.event_sink, result, mission_name)

      duration_ms = Events.duration_ms(started_ms)

      _ =
        Events.emit(
          state,
          capture.event_sink,
          "evaluation-stopped",
          put_parent_evaluation_id(
            %{
              evaluation_id: evaluation_id,
              environment: :mission,
              mission_name: mission_name,
              status: result.outcome,
              continuation: RunState.evaluation_memory_summary(state),
              duration_ms: duration_ms
            },
            parent_evaluation_id
          )
        )

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

  defp validate_admission!(admission) when admission in [:fail_fast, :block], do: admission

  defp validate_admission!(admission) do
    raise ArgumentError,
          "invalid admission mode #{inspect(admission)}; expected :fail_fast or :block"
  end

  defp validate_parent_evaluation_id!(nil), do: nil

  defp validate_parent_evaluation_id!(parent_evaluation_id)
       when is_binary(parent_evaluation_id) and byte_size(parent_evaluation_id) in 1..256 do
    if String.valid?(parent_evaluation_id) do
      parent_evaluation_id
    else
      raise ArgumentError, "invalid parent evaluation ID"
    end
  end

  defp validate_parent_evaluation_id!(_parent_evaluation_id) do
    raise ArgumentError, "invalid parent evaluation ID"
  end

  defp validate_result_limit!(nil), do: nil
  defp validate_result_limit!(limit) when is_integer(limit) and limit > 0, do: limit

  defp validate_result_limit!(limit) do
    raise ArgumentError,
          "invalid result limit #{inspect(limit)}; expected a positive integer or nil"
  end

  defp put_parent_evaluation_id(data, nil), do: data

  defp put_parent_evaluation_id(data, parent_evaluation_id),
    do: Map.put(data, :parent_evaluation_id, parent_evaluation_id)

  defp execute_with_lease(
         state,
         environment,
         source,
         timeout_ms,
         {memory, history, lease},
         capture,
         {deadline_ms, projection_boundary, params, mission_name, evaluation_id,
          result_limit_bytes}
       ) do
    limits = RunState.limits(state)

    options = [
      context: evaluation_data(environment.data, params),
      memory: memory,
      turn_history: history,
      tools:
        mission_tools(
          environment,
          state,
          timeout_ms,
          capture.event_sink,
          capture.inspection_sink,
          lease,
          deadline_ms,
          mission_name
        ),
      prelude: bundle_prelude(environment),
      timeout: timeout_ms,
      compile_timeout: timeout_ms,
      compile_max_heap: limits.evaluation_heap_words,
      run_deadline_ms: deadline_ms,
      pmap_timeout: limits.parallel_timeout_ms,
      max_heap: limits.evaluation_heap_words,
      max_parallel_workers: limits.live_provider_tasks,
      max_program_bytes: limits.subordinate_source_bytes,
      filter_context: false,
      caller: :kernel,
      preserve_runtime_callables: true,
      link: true,
      strict_data: true,
      data_grants: DataKeys.source_referenceable_forms(environment.data),
      missing_data_params_message: @missing_data_params_message
    ]

    mission_calls_before = mission_capability_calls(state)

    result = Lisp.run_native(source, options)

    case inspection_analysis(
           capture.inspection_sink,
           evaluation_id,
           result,
           environment,
           mission_name
         ) do
      :ok ->
        classify_evaluation_result(
          result,
          state,
          environment,
          lease,
          history,
          mission_calls_before,
          projection_boundary,
          result_limit_bytes,
          evaluation_id
        )

      {:error, :inspection_sink_error} ->
        :ok = RunState.release_evaluation(state, lease)
        :ok = RunState.fail(state, :inspection_sink_error, :inspection_sink_error)
        failure(:evaluation_error, :inspection_sink_error)
    end
  end

  defp classify_evaluation_result(
         result,
         state,
         environment,
         lease,
         history,
         mission_calls_before,
         projection_boundary,
         result_limit_bytes,
         evaluation_id
       ) do
    case result do
      {:ok, %{return: {:__ptc_fail__, value}} = step} ->
        :ok = RunState.clear_last_evaluator_failure(state)

        release_explicit_failure(
          state,
          environment,
          lease,
          step,
          value,
          mission_calls_before,
          projection_boundary,
          result_limit_bytes
        )
        |> put_terminal_provider_failure(step)
        |> put_terminal_host_failure(step)

      {:ok, step} ->
        :ok = RunState.clear_last_evaluator_failure(state)

        commit_result(
          state,
          environment,
          lease,
          history,
          step,
          mission_calls_before,
          projection_boundary,
          result_limit_bytes
        )
        |> put_terminal_provider_failure(step)
        |> put_terminal_host_failure(step)

      {:error, step} ->
        maybe_record_evaluator_failure(state, evaluation_id, step)

        release_failure(state, environment, lease, step, mission_calls_before)
        |> put_terminal_provider_failure(step)
        |> put_terminal_host_failure(step)
    end
  end

  defp maybe_record_evaluator_failure(state, evaluation_id, step) do
    reason = step.fail.reason
    details = step.fail.details || %{}

    if EvaluatorErrorCatalog.kind?(reason) do
      RunState.record_last_evaluator_failure(state, %{
        evaluation_id: evaluation_id,
        environment: :mission,
        kind: reason,
        details: details
      })
    else
      :ok
    end
  end

  defp evaluation_data(data, :error), do: data
  defp evaluation_data(data, {:ok, params}), do: Map.put(data, "params", params)

  defp commit_result(
         state,
         environment,
         lease,
         history,
         step,
         mission_calls_before,
         projection_boundary,
         result_limit_bytes
       ) do
    case Lisp.project_boundary_value(step.return, projection_boundary) do
      {:ok, projected_return} ->
        if result_within_limit?(projected_return, result_limit_bytes) do
          commit_projected_result(
            state,
            environment,
            lease,
            history,
            step,
            projected_return,
            mission_calls_before
          )
        else
          :ok = RunState.release_evaluation(state, lease)
          result_limit_failure(step)
        end

      {:error, reason} ->
        :ok = RunState.release_evaluation(state, lease)
        projection_failure(step, reason)
    end
  end

  defp commit_projected_result(
         state,
         environment,
         lease,
         history,
         step,
         projected_return,
         mission_calls_before
       ) do
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
        commit_limit_failure(
          :memory_exceeded,
          :evaluation_memory_bytes,
          "candidate definitions exceeded the retained evaluation-memory limit",
          state,
          environment,
          step,
          mission_calls_before
        )

      {:error, :history_exceeded} ->
        commit_limit_failure(
          :history_exceeded,
          :evaluation_history_bytes,
          "candidate result exceeded the retained evaluation-history limit",
          state,
          environment,
          step,
          mission_calls_before
        )

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

  defp commit_limit_failure(
         kind,
         reason,
         message,
         state,
         environment,
         step,
         mission_calls_before
       ) do
    {capability_activity?, unsafe_activity?} =
      evaluation_activity(state, environment, step, mission_calls_before)

    %{
      outcome: kind,
      kind: kind,
      reason: reason,
      details: %{
        phase: :commit,
        message: message,
        capability_activity?: capability_activity?
      },
      prints: Map.get(step, :prints, []),
      continuation_effect: :preserved,
      capability_activity?: capability_activity?,
      retryable?: not unsafe_activity?
    }
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

  defp result_limit_failure(step) do
    %{
      outcome: :result_exceeded,
      kind: :result_exceeded,
      reason: :terminal_result_bytes,
      prints: Map.get(step, :prints, []),
      continuation_effect: :preserved
    }
  end

  defp result_within_limit?(_value, nil), do: true

  defp result_within_limit?({:__ptc_return__, value}, limit),
    do: result_within_limit?(value, limit)

  defp result_within_limit?(value, limit) do
    TerminalResultLimit.within_limit?(value, limit)
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
         projection_boundary,
         result_limit_bytes
       ) do
    {capability_activity?, unsafe_activity?} =
      evaluation_activity(state, environment, step, mission_calls_before)

    capability_failure? = capability_failure?(step, value)

    :ok = RunState.release_evaluation(state, lease)

    case Lisp.project_boundary_value(value, projection_boundary) do
      {:ok, projected} ->
        if result_within_limit?(projected, result_limit_bytes) do
          %{
            outcome: :failed,
            value: projected,
            prints: Map.get(step, :prints, []),
            continuation_effect: :preserved,
            capability_activity?: capability_activity?,
            capability_failure?: capability_failure?,
            retryable?: not unsafe_activity?
          }
        else
          result_limit_failure(step)
        end

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

    result =
      if evaluation_status.terminal_provider_failure?,
        do: Map.put(result, :terminal_provider_failure?, true),
        else: result

    if evaluation_status.terminal_host_failure?,
      do: Map.put(result, :terminal_host_failure?, true),
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

  defp put_terminal_host_failure(result, step) do
    if terminal_host_failure?(step),
      do: Map.put(result, :terminal_host_failure?, true),
      else: result
  end

  defp terminal_host_failure?(step) do
    step
    |> Map.get(:tool_calls, [])
    |> List.wrap()
    |> Enum.any?(fn
      %{
        result: %{
          status: :error,
          kind: :capability_unavailable,
          reason: :input_validation_unavailable
        }
      } ->
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

  @doc false
  def mission_tools(
        environment,
        state,
        timeout_ms,
        event_sink,
        inspection_sink,
        evaluation_lease,
        validation_deadline_ms,
        mission_name
      ) do
    limits = RunState.limits(state)

    state
    |> ToolGrant.capability_callbacks(
      :mission,
      environment,
      %{
        timeout_ms: timeout_ms,
        validation_heap_words: limits.evaluation_heap_words,
        evaluation_lease: evaluation_lease,
        validation_deadline_ms: validation_deadline_ms,
        mission_name: mission_name
      },
      event_sink,
      inspection_sink
    )
    |> Map.new(fn {name, callback} -> {name, %TrustedTool{function: callback}} end)
  end

  defp bundle_prelude(%{bundle: %{prelude: prelude}}), do: prelude
  defp bundle_prelude(_environment), do: nil

  defp source_within_limit(source, limit),
    do: if(byte_size(source) <= limit, do: :ok, else: {:error, :source_exceeded})

  defp failure(kind, reason),
    do: %{outcome: kind, kind: kind, reason: reason, continuation_effect: :preserved}

  defp preflight_limit(state, event_sink, kind, reason, mission_name) do
    result = failure(kind, reason)
    _ = maybe_emit_limit(state, event_sink, result, mission_name)
    result
  end

  defp maybe_emit_limit(state, event_sink, %{outcome: outcome} = result, mission_name)
       when outcome in [
              :timeout,
              :memory_exceeded,
              :history_exceeded,
              :result_exceeded,
              :limit_exceeded
            ] do
    data = %{
      reason: Map.get(result, :reason, outcome),
      environment: :mission,
      mission_name: mission_name
    }

    Events.emit(state, event_sink, "limit-exceeded", data)
  end

  defp maybe_emit_limit(_state, _event_sink, _result, _mission_name), do: :ok

  defp inspection_source(
         nil,
         _evaluation_id,
         _source,
         _source_hash,
         _source_bytes,
         _mission_name
       ),
       do: :ok

  defp inspection_source(sink, evaluation_id, source, source_hash, source_bytes, mission_name) do
    InspectionSink.emit(
      sink,
      "evaluation-source",
      %{evaluation_id: evaluation_id},
      %{
        environment: :mission,
        mission_name: mission_name,
        program_kind: :"ptc-lisp",
        source: source,
        source_hash: source_hash,
        source_bytes: source_bytes
      }
    )
  end

  defp inspection_analysis(nil, _evaluation_id, _result, _environment, _mission_name), do: :ok

  defp inspection_analysis(
         _sink,
         _evaluation_id,
         {_status, %{prelude_calls: nil}},
         _environment,
         _mission_name
       ),
       do: :ok

  defp inspection_analysis(
         sink,
         evaluation_id,
         {_status, %{prelude_calls: calls}},
         environment,
         mission_name
       )
       when is_list(calls) do
    case prelude_call_components(calls, bundle_prelude(environment)) do
      {:ok, calls} ->
        InspectionSink.emit(
          sink,
          "evaluation-analysis",
          %{evaluation_id: evaluation_id},
          %{environment: :mission, mission_name: mission_name, prelude_calls: calls}
        )

      :error ->
        {:error, :inspection_sink_error}
    end
  end

  defp prelude_call_components([], _prelude), do: {:ok, []}

  defp prelude_call_components(calls, %Lisp.Prelude{} = prelude) do
    component_by_namespace =
      prelude.metadata
      |> Map.get(:components, [])
      |> Enum.flat_map(fn component ->
        Enum.map(component.namespaces, &{&1, component.id})
      end)
      |> Map.new()

    Enum.reduce_while(calls, {:ok, []}, fn ref, {:ok, entries} ->
      namespace = ref |> String.split("/", parts: 2) |> hd()

      case Map.fetch(component_by_namespace, namespace) do
        {:ok, component_id} ->
          {:cont, {:ok, [%{ref: ref, component_id: component_id} | entries]}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, entries} ->
        {:ok, entries |> Enum.reverse() |> Enum.sort_by(&{&1.ref, &1.component_id})}

      :error ->
        :error
    end
  end

  defp prelude_call_components(_calls, _prelude), do: :error

  defp sha256(source),
    do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
end
