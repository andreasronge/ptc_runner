defmodule PtcRunner.Kernel.Runner do
  @moduledoc """
  Internal implementation of `PtcRunner.Kernel.run/2`.

  It owns run-state lifetime, workflow evaluation, runtime-tool wiring,
  subordinate-evaluation routing, canonical lifecycle events, public value
  projection, and terminal error normalization.
  """

  alias PtcRunner.Kernel.AgentConfigDiagnostic
  alias PtcRunner.Kernel.BoundedPrints
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.EvaluatorEvidence
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMBudget
  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.ProjectionError
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultContractDiagnostic
  alias PtcRunner.Kernel.ResultIdentity
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Kernel.TerminalResultLimit
  alias PtcRunner.Kernel.ToolGrant
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.DataKeys
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.EvaluatorErrorCatalog
  alias PtcRunner.Lisp.Result, as: LispResult
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Lisp.ShippedExportCatalog
  alias PtcRunner.LLM.OutputLimit

  # Matches the bound `PtcRunner.Kernel.AnalysisSession` already applies when
  # projecting `prints` into a caller-facing result.
  @execution_prints_count 128
  @execution_prints_bytes 65_536

  @spec run(binary(), RunConfig.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  @doc "Executes one validated run configuration and always tears down run state."
  def run(entry_source, %RunConfig{} = config) when is_binary(entry_source) do
    {result, _terminal_batch} = run_and_events(entry_source, config)
    result
  end

  @doc false
  @spec run_and_events(binary(), RunConfig.t()) ::
          {{:ok, Result.t()} | {:error, Error.t()}, {:ok, [map()]} | {:error, atom()}}
  def run_and_events(entry_source, %RunConfig{} = config) when is_binary(entry_source) do
    case EventSink.claim(config.event_sink, config.claim_id, config.run_started_metadata) do
      :ok ->
        run_claimed_attempt(entry_source, config)

      {:error, :event_sink_already_claimed} ->
        {event_sink_error(%{}), {:error, :event_sink_error}}

      {:error, reason}
      when reason in [:event_sink_claimed_by_other, :event_sink_error] ->
        result =
          apply_provider_cleanup_failure(
            event_sink_error(%{}),
            RunConfig.close_provider_session(config),
            %{}
          )

        {result, {:error, :event_sink_error}}
    end
  end

  defp run_claimed_attempt(entry_source, config) do
    with :ok <- entry_source_within_limit(entry_source, config.limits),
         {:ok, state} <-
           RunState.start(config.limits,
             provider_session: config.provider_session,
             run_deadline: config.run_deadline
           ) do
      try do
        case transfer_provider_cleanup(config, state) do
          :ok ->
            run_claimed(entry_source, config, state)

          {:error, reason} ->
            close_run_state(state)

            usage = preflight_usage(config)

            result =
              reason
              |> configuration_error(usage)
              |> apply_provider_cleanup_failure(
                RunConfig.close_provider_session(config),
                usage
              )

            finalize_result(result, usage, config.event_sink)
        end
      after
        stop_run_state(state)
      end
    else
      {:error, reason} ->
        usage = preflight_usage(config)

        result =
          reason
          |> configuration_error(usage)
          |> apply_provider_cleanup_failure(RunConfig.close_provider_session(config), usage)

        finalize_result(result, usage, config.event_sink)
    end
  end

  defp transfer_provider_cleanup(config, state) do
    RunConfig.bind_provider_session(config, self(), state.pid, state.provider_tracker)
  end

  defp preflight_usage(config),
    do: %{llm_budget: LLMBudget.initial_terminal_projection(config.limits)}

  defp run_claimed(entry_source, config, state) do
    reporter = PtcRunner.LiveStatus.maybe_start(config, state)

    try do
      execution =
        try do
          result = run_workflow(entry_source, config, state)
          {:ok, apply_terminal_failure(result, state)}
        catch
          kind, reason ->
            {:raised, kind, reason, __STACKTRACE__}
        after
          close_run_state(state)
        end

      usage = run_state_usage(state, config.limits)
      cleanup = RunConfig.close_provider_session(config)

      case execution do
        {:ok, result} ->
          result = apply_provider_cleanup_failure(result, cleanup, usage)
          {final_result, _events} = finalized = finalize_result(result, usage, config.event_sink)

          {live_reason, live_limit} = live_terminal_outcome(final_result)

          _ =
            PtcRunner.LiveStatus.complete(
              reporter,
              outcome(final_result),
              live_reason,
              live_limit,
              live_evaluation_error(final_result, config.event_sink)
            )

          finalized

        # An unexpected internal exception keeps its original reason and stack
        # trace. A cleanup failure must not replace a programming defect with a
        # tidier diagnostic.
        {:raised, kind, reason, stacktrace} ->
          :erlang.raise(kind, reason, stacktrace)
      end
    catch
      kind, reason ->
        _ = PtcRunner.LiveStatus.complete(reporter, :error, :internal_error, nil)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      PtcRunner.LiveStatus.stop(reporter)
    end
  end

  defp finalize_result(result, usage, sink) do
    stopped_data =
      %{
        outcome: outcome(result),
        reason: terminal_reason(result),
        usage: usage
      }
      |> maybe_put_result_hash(result)
      |> maybe_put_failure_taxonomy(result)

    case EventSink.finalize_and_events(sink, stopped_data) do
      {:ok, %{events: events, dropped: dropped}} ->
        final_usage = Map.put(usage, :events_dropped, dropped)
        {put_result_usage(result, final_usage), {:ok, events}}

      {:error, :event_sink_error} ->
        failed_usage = Map.put(usage, :events_dropped, %{"event-sink" => 1})

        terminal_result =
          case result do
            {:error, %Error{kind: :provider_cleanup_error}} ->
              put_result_usage(result, failed_usage)

            _other ->
              event_sink_error(failed_usage)
          end

        {terminal_result, {:error, :event_sink_error}}
    end
  end

  defp run_workflow(entry_source, config, state) do
    timeout_ms = min(config.limits.workflow_timeout_ms, RunState.remaining_ms(state))
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    evaluation_id = Events.id("workflow-evaluation")
    started_ms = System.monotonic_time(:millisecond)

    case Events.emit(state, config.event_sink, "evaluation-started", %{
           evaluation_id: evaluation_id,
           environment: :workflow
         }) do
      :ok ->
        result =
          execute_workflow(entry_source, config, state, timeout_ms, deadline_ms, evaluation_id)

        _ = maybe_emit_workflow_limit(state, config.event_sink, result)

        _ =
          Events.emit(state, config.event_sink, "evaluation-stopped", %{
            evaluation_id: evaluation_id,
            environment: :workflow,
            status: outcome(result),
            duration_ms: Events.duration_ms(started_ms)
          })

        result

      {:error, :event_sink_error} ->
        event_sink_error(RunState.usage(state))
    end
  end

  defp execute_workflow(entry_source, config, state, timeout_ms, deadline_ms, evaluation_id) do
    opts = [
      context: config.input,
      tools: workflow_tools(config, state, deadline_ms, evaluation_id),
      prelude: bundle_prelude(config.workflow_environment),
      shipped_export_owners: ShippedExportCatalog.load(),
      attached_component_ids: Environment.shipped_component_ids(config.workflow_environment),
      timeout: timeout_ms,
      compile_timeout: timeout_ms,
      run_deadline_ms: deadline_ms,
      pmap_timeout: config.limits.parallel_timeout_ms,
      max_heap: config.limits.workflow_heap_words,
      max_parallel_workers: config.limits.live_provider_tasks,
      max_program_bytes: config.limits.entry_source_bytes,
      loop_limit: config.limits.workflow_loop_iterations,
      filter_context: false,
      caller: :kernel,
      telemetry_run: state.pid,
      strict_data: true,
      data_grants: DataKeys.source_referenceable_forms(config.input),
      component_catalog: Environment.catalog(config.workflow_environment),
      inspect_only: config.inspect_only
    ]

    case Lisp.run_native(entry_source, opts) do
      {:ok, %{return: {:__ptc_fail__, value}} = step} ->
        capture_execution_failure(
          config,
          state,
          evaluation_id,
          step,
          explicit_failure_error(value, state),
          %{explicit_failure_value: value}
        )

      {:ok, step} ->
        with {:ok, value} <-
               Lisp.project_boundary_value(LispResult.unwrap_return(step.return), :kernel_json),
             {:ok, value} <- project_result(value, config.result_projection) do
          if TerminalResultLimit.within_limit?(value, config.limits.terminal_result_bytes) do
            value = RetainedSize.detach_binaries(value)
            :ok = capture_execution_prints(config, state, evaluation_id, step.prints)

            {:ok,
             %Result{
               value: value,
               usage: RunState.usage(state),
               evaluation_memory: RunState.evaluation_memory_summary(state)
             }}
          else
            capture_execution_failure(
              config,
              state,
              evaluation_id,
              step,
              %Error{
                kind: :limit_exceeded,
                reason: :terminal_result_exceeded,
                details: %{
                  limit: :terminal_result_bytes,
                  limit_value: config.limits.terminal_result_bytes
                },
                usage: RunState.usage(state)
              }
            )
          end
        else
          {:error, {:invalid_result_projection, projection_error}} ->
            capture_execution_failure(
              config,
              state,
              evaluation_id,
              step,
              %Error{
                kind: :workflow_failed,
                reason: :invalid_result_projection,
                details: %{result_projection: true},
                usage: RunState.usage(state)
              },
              %{projection_error: inspect(projection_error, limit: 10)}
            )

          {:error, reason} ->
            capture_execution_failure(
              config,
              state,
              evaluation_id,
              step,
              %Error{
                kind: :workflow_failed,
                reason: ProjectionError.kind(reason),
                details: %{
                  result_projection: true,
                  projection_error: inspect(reason, limit: 10)
                },
                usage: RunState.usage(state)
              }
            )
        end

      {:error, step} ->
        capture_execution_failure(
          config,
          state,
          evaluation_id,
          step,
          %Error{
            kind: workflow_error_kind(step.fail.reason, config.event_sink),
            reason: step.fail.reason,
            details:
              workflow_error_details(
                step.fail,
                timeout_ms,
                config.limits,
                config.event_sink
              )
              |> Map.merge(authenticated_replay_metadata(step.fail.details, state)),
            usage: RunState.usage(state)
          }
          |> maybe_promote_authenticated_limit_error(step.fail.details, state),
          workflow_inspection_details(step.fail, config.event_sink)
        )
    end
  end

  # Routes `step.prints` and the built `%Error{}.details` into the private
  # inspection artifact, correlated by the workflow `evaluation_id`. Neither
  # ever reaches the public envelope or canonical trace: the sink is the
  # `0600` artifact, not an event. A capture failure fails the run closed the
  # same way a capability's inspection capture does, by marking `RunState` so
  # `apply_terminal_failure/2` replaces the result after this returns.
  defp capture_execution_failure(config, state, evaluation_id, step, %Error{} = error) do
    capture_execution_failure(config, state, evaluation_id, step, error, %{})
  end

  defp capture_execution_failure(
         config,
         state,
         evaluation_id,
         step,
         %Error{} = public_error,
         private_details
       )
       when is_map(private_details) do
    {explicit_value, private_details} = take_explicit_failure_value(private_details)

    private_details = Map.merge(private_details, boundary_producer_details(step))
    private_error = %{public_error | details: Map.merge(public_error.details, private_details)}

    # Only the value emit decides retention: a later diagnostics failure does
    # not unwrite a value the sink already accepted.
    retention =
      case emit_explicit_failure_value(config, evaluation_id, explicit_value) do
        {:ok, retention} ->
          :ok =
            emit_execution_diagnostics_or_fail(config, state, evaluation_id, step, private_error)

          retention

        {:error, :inspection_sink_error} ->
          :ok = RunState.fail(state, :inspection_sink_error, :inspection_sink_error)
          :unwritten
      end

    {:error, put_explicit_failure_retention(public_error, explicit_value, retention)}
  end

  # The retention outcome is the one fact about an explicit failure the
  # payload-free envelope can carry: it names where the value went without
  # naming the value. Only the terminal workflow-fail path supplies one, so
  # every other failure keeps the details map it already had.
  defp put_explicit_failure_retention(error, :absent, _retention), do: error

  defp put_explicit_failure_retention(error, {:present, _value}, retention),
    do: %{error | details: Map.put(error.details, :explicit_failure_retention, retention)}

  # A direct return of one successful `kernel-eval` result is the narrow case
  # where the evaluator's return-origin marker and ledger together prove
  # boundary-value provenance. Retain only the child evaluation identity.
  # Transformed values deliberately remain unresolved; equal BEAM terms are
  # not by themselves dataflow evidence.
  defp boundary_producer_details(step) do
    boundary_value = LispResult.unwrap_return(Map.get(step, :return))

    with :direct_tool_call <- Map.get(step, :return_origin),
         %{name: "kernel-eval"} = call <- List.last(Map.get(step, :tool_calls, [])) do
      evaluation_ids =
        case direct_boundary_producer_id(call, boundary_value) do
          nil -> []
          evaluation_id -> [evaluation_id]
        end

      %{
        boundary_producer: %{
          evaluation_ids: evaluation_ids,
          complete?: not Map.get(call, :result_truncated, false)
        }
      }
    else
      _other -> %{}
    end
  end

  defp direct_boundary_producer_id(
         %{error: nil, result: result},
         boundary_value
       )
       when result == boundary_value do
    get_in(result, [:value, :evaluation_id]) ||
      get_in(result, [:value, "evaluation_id"]) ||
      get_in(result, ["value", :evaluation_id]) ||
      get_in(result, ["value", "evaluation_id"])
  end

  defp direct_boundary_producer_id(_call, _boundary_value), do: nil

  # A successful workflow's `step.prints` are as diagnostically valuable as a
  # failing one's — they are the first thing anyone adds to see why a run
  # returned the wrong value — so this applies the same private-artifact-only
  # capture and fail-closed-on-sink-error rule `capture_execution_failure/5`
  # applies on the error paths.
  defp capture_execution_prints(config, state, evaluation_id, prints) do
    case emit_execution_prints(config.inspection_sink, evaluation_id, prints) do
      :ok ->
        :ok

      {:error, :inspection_sink_error} ->
        :ok = RunState.fail(state, :inspection_sink_error, :inspection_sink_error)
    end
  end

  defp emit_execution_diagnostics_or_fail(config, state, evaluation_id, step, error) do
    case emit_execution_diagnostics(config.inspection_sink, evaluation_id, step.prints, error) do
      :ok ->
        :ok

      {:error, :inspection_sink_error} ->
        RunState.fail(state, :inspection_sink_error, :inspection_sink_error)
    end
  end

  defp emit_execution_diagnostics(nil, _evaluation_id, _prints, _error), do: :ok

  defp emit_execution_diagnostics(sink, evaluation_id, prints, error) do
    with :ok <- emit_execution_prints(sink, evaluation_id, prints) do
      emit_execution_error(sink, evaluation_id, error)
    end
  end

  defp emit_execution_prints(nil, _evaluation_id, _prints), do: :ok
  defp emit_execution_prints(_sink, _evaluation_id, []), do: :ok

  defp emit_execution_prints(sink, evaluation_id, prints) do
    {bounded, truncated?} =
      BoundedPrints.bound(prints, @execution_prints_count, @execution_prints_bytes)

    InspectionSink.emit(
      sink,
      "execution-prints",
      %{evaluation_id: evaluation_id},
      %{environment: :workflow, prints: bounded, truncated: truncated?}
    )
  end

  defp emit_execution_error(sink, evaluation_id, %Error{
         kind: kind,
         reason: reason,
         details: details
       }) do
    InspectionSink.emit(
      sink,
      "execution-error",
      %{evaluation_id: evaluation_id},
      %{
        environment: :workflow,
        kind: kind,
        reason: reason,
        details: inspection_error_details(reason, details)
      }
    )
  end

  # Presence is tagged so a Lisp fail value cannot collide with a sentinel.
  defp take_explicit_failure_value(private_details) do
    if Map.has_key?(private_details, :explicit_failure_value) do
      {value, rest} = Map.pop!(private_details, :explicit_failure_value)
      {{:present, value}, rest}
    else
      {:absent, private_details}
    end
  end

  defp emit_explicit_failure_value(_config, _evaluation_id, :absent), do: {:ok, nil}

  defp emit_explicit_failure_value(%{inspection_sink: nil}, _evaluation_id, {:present, _value}),
    do: {:ok, :unrequested}

  defp emit_explicit_failure_value(config, evaluation_id, {:present, value}) do
    case admitted_explicit_failure_json(value, config.limits.terminal_result_bytes) do
      {:ok, json} ->
        with :ok <-
               InspectionSink.emit(
                 config.inspection_sink,
                 "explicit-failure-value",
                 %{evaluation_id: evaluation_id},
                 %{environment: :workflow, value: json}
               ) do
          {:ok, :retained}
        end

      refusal ->
        {:ok, refusal}
    end
  end

  # A value the boundary cannot project and one that projects but does not fit
  # are different facts about the same silent drop, and telling a caller their
  # small value broke a byte ceiling would send them after the wrong remedy.
  defp admitted_explicit_failure_json(value, max_bytes) do
    with {:ok, projected} <- Lisp.project_boundary_value(value, :kernel_json),
         {:ok, json} <- JSONValue.normalize(projected),
         {:ok, encoded} <- DeterministicJSON.encode(json) do
      if byte_size(encoded) <= max_bytes, do: {:ok, json}, else: :oversized
    else
      _closed -> :unrepresentable
    end
  end

  # `capture_execution_failure/6` merges the private `boundary_producer` fact
  # into the same details map the authenticated result-contract diagnostic
  # owns, so split them before projecting: only the contract half holds
  # structs the sink cannot serialize.
  defp inspection_error_details(:result_contract_failed, details) do
    boundary = Map.take(details, [:boundary_producer])
    contract = Map.drop(details, [:boundary_producer])

    case ResultContractDiagnostic.inspection_details(contract) do
      {:ok, projected} -> Map.merge(projected, boundary)
      :error -> boundary
    end
  end

  defp inspection_error_details(:phase_return_contract_failed, details) do
    boundary = Map.take(details, [:boundary_producer])
    contract = Map.drop(details, [:boundary_producer])

    case ResultContractDiagnostic.phase_inspection_details(contract) do
      {:ok, projected} -> Map.merge(projected, boundary)
      :error -> boundary
    end
  end

  defp inspection_error_details(_reason, details), do: details

  defp project_result(value, :native), do: {:ok, value}

  defp project_result(value, :json) do
    case StrictJSON.admit_with_locations(value) do
      {:ok, projected} -> {:ok, projected}
      {:error, reason} -> {:error, {:invalid_result_projection, reason}}
    end
  end

  defp mission_environments(config),
    do: Map.new(config.missions, fn {name, mission} -> {name, mission.environment} end)

  defp mission_renderings(config, field),
    do:
      Map.new(config.missions, fn {name, mission} ->
        {name, Map.fetch!(mission.inventory, field)}
      end)

  defp workflow_tools(%{inspect_only: true}, _state, _validation_deadline_ms, _evaluation_id),
    do: %{}

  defp workflow_tools(config, state, validation_deadline_ms, evaluation_id) do
    state
    |> ToolGrant.capability_callbacks(
      :workflow,
      config.workflow_environment,
      %{
        timeout_ms: config.limits.workflow_timeout_ms,
        validation_heap_words: config.limits.workflow_heap_words,
        evaluation_lease: nil,
        validation_deadline_ms: validation_deadline_ms,
        mission_name: nil
      },
      config.event_sink,
      config.inspection_sink
    )
    |> Map.put(
      "kernel-eval",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-eval",
        RuntimeTools.kernel_eval(
          state,
          mission_environments(config),
          config.limits,
          config.event_sink,
          config.inspection_sink,
          admission: :block,
          parent_evaluation_id: evaluation_id
        )
      )
    )
    |> Map.put(
      "kernel-check-source",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-check-source",
        RuntimeTools.kernel_check_source(
          state,
          mission_environments(config),
          config.limits,
          config.event_sink
        )
      )
    )
    |> Map.put(
      "kernel-mission-inventory",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-mission-inventory",
        RuntimeTools.mission_inventory(
          state,
          mission_renderings(config, :rendered),
          config.event_sink
        )
      )
    )
    |> Map.put(
      "kernel-mission-model-context",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-mission-model-context",
        RuntimeTools.mission_model_context(
          state,
          mission_renderings(config, :model_rendered),
          config.event_sink
        )
      )
    )
    |> Map.put(
      "kernel-result-contract",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-result-contract",
        RuntimeTools.result_contract(config.result_contract, config.phase_return_contracts)
      )
    )
    |> RuntimeTools.maybe_put_result_contract_failure(
      state,
      config.event_sink,
      config.result_contract,
      config.result_contract_source,
      config.workflow_environment
    )
    |> RuntimeTools.maybe_put_phase_return_contract_failure(
      state,
      config.event_sink,
      config.phase_return_contracts,
      config.workflow_environment
    )
    |> RuntimeTools.maybe_put_llm_provider_failure(
      state,
      config.event_sink,
      config.workflow_environment
    )
    |> RuntimeTools.maybe_put_runtime_limit_failure(
      state,
      config.event_sink,
      config.limits,
      config.workflow_environment
    )
    |> RuntimeTools.maybe_put_agent_loop_tools(
      state,
      config.event_sink,
      config.workflow_environment
    )
    |> RuntimeTools.trusted_tools(
      config.limits,
      ToolGrant.capability_contracts(config.workflow_environment)
    )
  end

  defp bundle_prelude(%{bundle: %{prelude: prelude}}), do: prelude
  defp bundle_prelude(_environment), do: nil

  defp entry_source_within_limit(source, limits) do
    if byte_size(source) <= limits.entry_source_bytes,
      do: :ok,
      else: {:error, :entry_source_exceeded}
  end

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, _error}), do: :error
  defp terminal_reason({:ok, _result}), do: nil
  defp terminal_reason({:error, %Error{reason: reason}}), do: reason

  defp live_terminal_outcome({:ok, _result}), do: {nil, nil}

  defp live_terminal_outcome({:error, %Error{details: details, reason: reason}}) do
    case RuntimeLimitDiagnostic.details_message(details) do
      {:ok, limit, message} -> {message, limit}
      :error -> {live_failure_reason(reason, details), nil}
    end
  end

  defp live_failure_reason(_reason, %{message: message})
       when is_binary(message) and message != "",
       do: message

  defp live_failure_reason(reason, _details), do: reason

  defp live_evaluation_error({:error, %Error{} = error}, sink) do
    result_class =
      case EventSink.policy(sink) do
        :normal -> :normal
        _private_or_unavailable -> :private
      end

    EvaluatorEvidence.envelope_value(result_class, error)
  end

  defp live_evaluation_error(_result, _sink), do: nil

  defp maybe_put_result_hash(stopped_data, {:ok, %Result{value: value}}) do
    case ResultIdentity.hash(value) do
      {:ok, result_hash} -> Map.put(stopped_data, :result_hash, result_hash)
      {:error, _reason} -> stopped_data
    end
  end

  defp maybe_put_result_hash(stopped_data, _result), do: stopped_data

  defp maybe_put_failure_taxonomy(
         stopped_data,
         {:error, %Error{reason: reason, details: details}}
       )
       when reason in [:explicit_failure, :pmap_error, :pcalls_error] do
    taxonomy =
      details
      |> SafeMetadata.retain_failure_taxonomy_fields()

    Map.merge(stopped_data, taxonomy)
  end

  defp maybe_put_failure_taxonomy(
         stopped_data,
         {:error, %Error{reason: :llm_provider_failed, details: details}}
       ) do
    Map.merge(stopped_data, SafeMetadata.retain_failure_taxonomy_fields(details))
  end

  defp maybe_put_failure_taxonomy(
         stopped_data,
         {:error, %Error{reason: :phase_return_contract_failed}}
       ),
       do: Map.put(stopped_data, :failure_kind, "phase-return-contract-failed")

  defp maybe_put_failure_taxonomy(
         stopped_data,
         {:error,
          %Error{
            reason: :result_contract_failed,
            details: %{agent_turns: turns, constraint: constraint}
          }}
       )
       when turns in 1..128 and is_atom(constraint) do
    Map.merge(stopped_data, %{
      failure_kind: "result-contract",
      agent_turns: turns,
      constraint: constraint
    })
  end

  defp maybe_put_failure_taxonomy(
         stopped_data,
         {:error,
          %Error{
            reason: :runtime_limit_exceeded,
            details: %{limit: :agent_turns, limit_value: limit, limit_reason: limit_reason}
          }}
       )
       when limit in 1..128 do
    if RuntimeLimitDiagnostic.agent_turns_reason?(limit_reason) do
      Map.merge(stopped_data, %{
        failure_kind: "turn-limit",
        limit: :agent_turns,
        limit_value: limit,
        limit_reason: limit_reason
      })
    else
      stopped_data
    end
  end

  defp maybe_put_failure_taxonomy(
         stopped_data,
         {:error,
          %Error{
            reason: :runtime_limit_exceeded,
            details: %{limit: :max_transcript_chars, limit_value: limit}
          }}
       )
       when limit in 1..1_000_000 do
    Map.merge(stopped_data, %{
      failure_kind: "transcript-limit",
      limit: :max_transcript_chars,
      limit_value: limit
    })
  end

  defp maybe_put_failure_taxonomy(
         stopped_data,
         {:error, %Error{reason: :model_output_truncated, details: details}}
       ) do
    case retain_model_output_truncation(details) do
      {:ok, retained} -> Map.merge(stopped_data, retained)
      :error -> stopped_data
    end
  end

  defp maybe_put_failure_taxonomy(stopped_data, _result), do: stopped_data

  defp put_result_usage({:ok, %Result{} = result}, usage), do: {:ok, %{result | usage: usage}}
  defp put_result_usage({:error, %Error{} = error}, usage), do: {:error, %{error | usage: usage}}

  defp event_sink_error(usage) do
    {:error,
     %Error{
       kind: :event_sink_error,
       reason: :event_sink_error,
       details: %{},
       usage: usage
     }}
  end

  defp explicit_failure_error(value, state) do
    case SafeMetadata.named_quota_refusal(value) do
      {:ok, details} ->
        if RunState.named_quota_refusal?(state, details) do
          %Error{
            kind: :limit_exceeded,
            reason: :capability_quota,
            details: details,
            usage: RunState.usage(state)
          }
        else
          explicit_failure_taxonomy(value, state)
        end

      :error ->
        case SafeMetadata.budget_refusal(value) do
          {:ok, details} ->
            if RunState.budget_refusal?(state, details) do
              %Error{
                kind: :limit_exceeded,
                reason: details.limit,
                details: details,
                usage: RunState.usage(state)
              }
            else
              explicit_failure_taxonomy(value, state)
            end

          :error ->
            explicit_failure_taxonomy(value, state)
        end
    end
  end

  defp explicit_failure_taxonomy(value, state) do
    %Error{
      kind: :workflow_failed,
      reason: :explicit_failure,
      details:
        value
        |> SafeMetadata.failure_taxonomy()
        |> Map.merge(
          value
          |> LLMReplayDiagnostic.failure_metadata()
          |> authenticated_replay_metadata(state)
        ),
      usage: RunState.usage(state)
    }
  end

  defp maybe_promote_authenticated_limit_error(
         %Error{reason: reason, usage: usage} = error,
         details,
         state
       )
       when reason in [:pmap_error, :pcalls_error] and is_map(details) do
    case SafeMetadata.retain_named_quota_refusal_fields(details) do
      %{limit: _limit} = quota ->
        if RunState.named_quota_refusal?(state, quota) do
          %Error{
            kind: :limit_exceeded,
            reason: :capability_quota,
            details: quota,
            usage: usage
          }
        else
          maybe_promote_budget_error(error, details, state)
        end

      %{} ->
        maybe_promote_budget_error(error, details, state)
    end
  end

  defp maybe_promote_authenticated_limit_error(error, _details, _state), do: error

  defp maybe_promote_budget_error(%Error{usage: usage} = error, details, state) do
    case SafeMetadata.retain_budget_refusal_fields(details) do
      %{limit: limit} = budget ->
        if RunState.budget_refusal?(state, budget) do
          %Error{
            kind: :limit_exceeded,
            reason: limit,
            details: budget,
            usage: usage
          }
        else
          error
        end

      %{} ->
        error
    end
  end

  defp apply_provider_cleanup_failure(
         result,
         :ok,
         _usage
       ),
       do: result

  defp apply_provider_cleanup_failure(
         _result,
         {:error, :provider_cleanup_failed},
         usage
       ) do
    {:error,
     %Error{
       kind: :provider_cleanup_error,
       reason: :provider_cleanup_failed,
       details: %{},
       usage: usage
     }}
  end

  defp close_run_state(state) do
    RunState.close_and_drain(state)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_run_state(state) do
    close_run_state(state)
    RunState.stop(state)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp run_state_usage(state, limits) do
    RunState.usage(state)
  catch
    :exit, _reason -> %{llm_budget: LLMBudget.unavailable_terminal_projection(limits)}
  end

  defp apply_terminal_failure(result, state) do
    case RunState.terminal_failure(state) do
      nil ->
        result

      %{kind: :event_sink_error} ->
        event_sink_error(RunState.usage(state))

      %{kind: kind, reason: reason} = failure ->
        details =
          case failure do
            %{details: details} when is_map(details) -> details
            _missing -> %{}
          end

        {:error,
         %Error{
           kind: kind,
           reason: reason,
           details: details,
           usage: RunState.usage(state)
         }}
    end
  end

  defp maybe_emit_workflow_limit(
         _state,
         _sink,
         {:error, %Error{kind: :limit_exceeded, details: %{limit: limit}}}
       )
       when limit in [:max_calls, :protocol_errors, :llm_total_tokens, :llm_cost_microusd],
       do: :ok

  defp maybe_emit_workflow_limit(
         _state,
         _sink,
         {:error, %Error{kind: :limit_exceeded, details: %{limit: limit, name: _name}}}
       )
       when limit in [
              :workflow_capability_calls,
              :workflow_capability_calls_per_name,
              :mission_capability_calls,
              :mission_capability_calls_per_name
            ],
       do: :ok

  defp maybe_emit_workflow_limit(
         state,
         sink,
         {:error, %Error{kind: :limit_exceeded, reason: reason, details: details}}
       ),
       do:
         Events.emit(
           state,
           sink,
           "limit-exceeded",
           Map.merge(
             %{reason: reason},
             Map.take(details, [
               :limit,
               :limit_ms,
               :limit_value,
               :limit_bindings,
               :alias,
               :phase
             ])
           )
         )

  defp maybe_emit_workflow_limit(_state, _sink, _result), do: :ok

  defp workflow_error_kind(reason, _sink)
       when reason in [
              :timeout,
              :compile_timeout,
              :compile_memory_exceeded,
              :memory_exceeded,
              :program_too_large,
              :model_output_truncated
            ],
       do: :limit_exceeded

  defp workflow_error_kind(reason, sink) do
    if EvaluatorErrorCatalog.kind?(reason) and EventSink.policy(sink) == :normal do
      :evaluation_failed
    else
      :workflow_failed
    end
  end

  defp workflow_error_details(%{reason: reason} = fail, timeout_ms, limits, _sink)
       when reason in [:timeout, :compile_timeout] do
    # A parallel-deadline timeout also surfaces as :timeout; attributing it
    # to the sandbox limit would name a limit that never fired. The two
    # stable messages distinguish which bound won: pmap_timeout, or the run
    # deadline clamping a later-started operation.
    cond do
      reason == :timeout and parallel_message?(fail, Helpers.parallel_timeout_message()) ->
        %{
          message: "parallel_timeout_ms exceeded during execution",
          limit: :parallel_timeout_ms,
          limit_ms: limits.parallel_timeout_ms,
          phase: :execution
        }

      reason == :timeout and parallel_message?(fail, Helpers.parallel_run_deadline_message()) ->
        # The cap is min(workflow_timeout_ms, remaining run duration), so
        # the binding limit is whichever produced this evaluation's window.
        limit =
          if timeout_ms == limits.workflow_timeout_ms,
            do: :workflow_timeout_ms,
            else: :run_duration_ms

        limit_ms = Map.fetch!(limits, limit)

        %{
          message: "#{limit} expired during a parallel operation",
          limit: limit,
          limit_ms: limit_ms,
          phase: :execution
        }

      true ->
        limit =
          if timeout_ms == limits.workflow_timeout_ms,
            do: :workflow_timeout_ms,
            else: :run_duration_ms

        limit_ms = Map.fetch!(limits, limit)

        phase = if reason == :compile_timeout, do: :compilation, else: :execution

        %{
          message: "#{limit} exceeded during #{phase} after #{timeout_ms}ms",
          limit: limit,
          limit_ms: limit_ms,
          phase: phase
        }
    end
  end

  defp workflow_error_details(
         %{reason: :model_output_truncated, details: details},
         _timeout_ms,
         _limits,
         _sink
       ) do
    case retain_model_output_truncation(details) do
      {:ok, retained} -> retained
      :error -> %{}
    end
  end

  # A heap kill is already classified as a limit failure, but it carried no
  # limit metadata, so the command and the Live card both reported it as an
  # unnamed runtime limit. The ceiling the sandbox was armed with is
  # `workflow_heap_words`, and it is the one to name.
  defp workflow_error_details(%{reason: :memory_exceeded}, _timeout_ms, limits, _sink),
    do: %{
      message: "workflow_heap_words exceeded during execution",
      limit: :workflow_heap_words,
      limit_value: limits.workflow_heap_words
    }

  defp workflow_error_details(
         %{reason: :compile_memory_exceeded},
         _timeout_ms,
         limits,
         _sink
       ),
       do: %{
         message: "workflow_heap_words exceeded during compilation",
         limit: :workflow_heap_words,
         limit_value: limits.workflow_heap_words,
         phase: :compilation
       }

  defp workflow_error_details(
         %{reason: :llm_provider_failed, details: details} = fail,
         _timeout_ms,
         _limits,
         sink
       ) do
    if EventSink.policy(sink) != :normal do
      workflow_error_details_for_class(:private, fail)
    else
      retained = SafeMetadata.retain_llm_provider_failure_fields(details)

      if map_size(retained) == 2,
        do:
          retained
          |> Map.put(:failure_kind, "llm-provider-error")
          |> Map.merge(LLMReplayDiagnostic.retain_candidate_metadata(details)),
        else: %{}
    end
  end

  defp workflow_error_details(
         %{
           reason: :runtime_limit_exceeded,
           details: %{limit: :subordinate_evaluations, limit_value: limit}
         },
         _timeout_ms,
         limits,
         _sink
       )
       when limit == limits.subordinate_evaluations do
    %{limit: :subordinate_evaluations, limit_value: limit}
  end

  defp workflow_error_details(
         %{reason: :result_contract_failed, details: details},
         _timeout_ms,
         _limits,
         _sink
       ) do
    case ResultContractDiagnostic.retain_details(details) do
      {:ok, retained} -> retained
      :error -> %{}
    end
  end

  defp workflow_error_details(
         %{reason: :phase_return_contract_failed, details: details},
         _timeout_ms,
         _limits,
         _sink
       ) do
    case ResultContractDiagnostic.retain_phase_details(details) do
      {:ok, retained} -> retained
      :error -> %{}
    end
  end

  defp workflow_error_details(
         %{
           reason: :runtime_limit_exceeded,
           details:
             %{limit: :agent_turns, limit_value: limit, limit_reason: limit_reason} = details
         },
         _timeout_ms,
         _limits,
         _sink
       )
       when limit in 1..128 do
    if RuntimeLimitDiagnostic.agent_turns_reason?(limit_reason) do
      base = %{limit: :agent_turns, limit_value: limit, limit_reason: limit_reason}

      case details do
        %{last_evaluator_failure: %{kind: kind, details: eval_details}} ->
          if EvaluatorErrorCatalog.kind?(kind) and is_map(eval_details) do
            Map.put(base, :last_evaluator_failure, %{kind: kind, details: eval_details})
          else
            base
          end

        _other ->
          base
      end
    else
      %{}
    end
  end

  defp workflow_error_details(
         %{reason: :invalid_agent_config, details: details},
         _timeout_ms,
         _limits,
         _sink
       ) do
    case AgentConfigDiagnostic.retain_details(details) do
      {:ok, retained} -> retained
      :error -> %{}
    end
  end

  defp workflow_error_details(
         %{
           reason: :runtime_limit_exceeded,
           details: %{limit: :max_transcript_chars, limit_value: limit}
         },
         _timeout_ms,
         _limits,
         _sink
       )
       when limit in 1..1_000_000 do
    %{limit: :max_transcript_chars, limit_value: limit}
  end

  defp workflow_error_details(fail, _timeout_ms, _limits, sink)
       when not is_nil(sink) do
    cond do
      EvaluatorErrorCatalog.kind?(fail.reason) and EventSink.policy(sink) == :normal ->
        fail.details || %{}

      EvaluatorErrorCatalog.kind?(fail.reason) ->
        workflow_error_details_for_class(:private, fail)

      true ->
        details =
          case EventSink.policy(sink) do
            :normal -> workflow_error_details_for_class(:normal, fail)
            _private_or_unavailable -> workflow_error_details_for_class(:private, fail)
          end

        details
        |> Map.merge(SafeMetadata.retain_failure_taxonomy_fields(fail.details))
    end
  end

  # Public private-run Errors stay generic; the inspection record still gets
  # the admitted evaluator details so authorized analysis can name the kind.
  defp workflow_inspection_details(fail, sink) do
    if EvaluatorErrorCatalog.kind?(fail.reason) and EventSink.policy(sink) != :normal do
      fail.details || %{}
    else
      %{}
    end
  end

  defp retain_model_output_truncation(%{
         limit: :max_tokens,
         limit_value: value,
         limit_bindings: bindings,
         alias: alias_name
       }) do
    with {:ok, limit} <-
           OutputLimit.normalize(%{name: :max_tokens, value: value, bindings: bindings}),
         true <- OutputLimit.valid_alias?(alias_name) do
      {:ok,
       %{
         limit: :max_tokens,
         limit_value: limit.value,
         limit_bindings: limit.bindings,
         alias: alias_name
       }}
    else
      _invalid -> :error
    end
  end

  defp retain_model_output_truncation(%{alias: alias_name}) do
    if OutputLimit.valid_alias?(alias_name), do: {:ok, %{alias: alias_name}}, else: :error
  end

  defp retain_model_output_truncation(_details), do: :error

  # Both stable parallel messages are compared by suffix because the
  # evaluator prefixes messages with their reason.
  defp parallel_message?(fail, stable_message) do
    case Map.get(fail, :message) do
      message when is_binary(message) -> String.ends_with?(message, stable_message)
      _other -> false
    end
  end

  defp workflow_error_details_for_class(:private, _fail),
    do: %{message: "private workflow failed"}

  defp workflow_error_details_for_class(:normal, fail),
    do: %{message: String.slice(fail.message || "workflow failed", 0, 4_096)}

  defp authenticated_replay_metadata(metadata, state) do
    case LLMReplayDiagnostic.retain_candidate_metadata(metadata) do
      %{replay_request_hash: request_hash} = retained ->
        if RunState.replay_miss?(state, request_hash), do: retained, else: %{}

      %{} ->
        %{}
    end
  end

  defp configuration_error(reason, usage),
    do: {:error, %Error{kind: :configuration_error, reason: reason, details: %{}, usage: usage}}
end
