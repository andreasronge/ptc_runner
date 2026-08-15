defmodule PtcRunner.Kernel.Runner do
  @moduledoc """
  Internal implementation of `PtcRunner.Kernel.run/2`.

  It owns run-state lifetime, workflow evaluation, runtime-tool wiring,
  subordinate-evaluation routing, canonical lifecycle events, public value
  projection, and terminal error normalization.
  """

  alias PtcRunner.Kernel.BoundedPrints
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.ProjectionError
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultContractDiagnostic
  alias PtcRunner.Kernel.ResultIdentity
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Kernel.ToolGrant
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Result, as: LispResult
  alias PtcRunner.Lisp.RetainedSize

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

            result =
              reason
              |> configuration_error(%{})
              |> apply_provider_cleanup_failure(
                RunConfig.close_provider_session(config),
                %{}
              )

            finalize_result(result, %{}, config.event_sink)
        end
      after
        stop_run_state(state)
      end
    else
      {:error, reason} ->
        result =
          reason
          |> configuration_error(%{})
          |> apply_provider_cleanup_failure(RunConfig.close_provider_session(config), %{})

        finalize_result(result, %{}, config.event_sink)
    end
  end

  defp transfer_provider_cleanup(config, state) do
    RunConfig.bind_provider_session(config, self(), state.pid, state.provider_tracker)
  end

  defp run_claimed(entry_source, config, state) do
    execution =
      try do
        result = run_workflow(entry_source, config, state)
        result = apply_terminal_failure(result, state)
        {:ok, result}
      catch
        kind, reason ->
          {:raised, kind, reason, __STACKTRACE__}
      after
        close_run_state(state)
      end

    usage = run_state_usage(state)
    cleanup = RunConfig.close_provider_session(config)

    case execution do
      {:ok, result} ->
        result = apply_provider_cleanup_failure(result, cleanup, usage)
        finalize_result(result, usage, config.event_sink)

      # An unexpected internal exception keeps its original reason and stack
      # trace. A cleanup failure must not replace a programming defect with a
      # tidier diagnostic.
      {:raised, kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)
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
      timeout: timeout_ms,
      compile_timeout: timeout_ms,
      run_deadline_ms: deadline_ms,
      pmap_timeout: config.limits.parallel_timeout_ms,
      max_heap: config.limits.workflow_heap_words,
      max_parallel_workers: config.limits.live_provider_tasks,
      max_program_bytes: config.limits.entry_source_bytes,
      filter_context: false,
      caller: :kernel
    ]

    case Lisp.run_native(entry_source, opts) do
      {:ok, %{return: {:__ptc_fail__, value}} = step} ->
        capture_execution_failure(
          config,
          state,
          evaluation_id,
          step,
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
        )

      {:ok, step} ->
        with {:ok, value} <-
               Lisp.project_boundary_value(LispResult.unwrap_return(step.return), :kernel_json),
             {:ok, value} <- project_result(value, config.result_projection) do
          if terminal_result_within_limit?(value, config.limits.terminal_result_bytes) do
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
                details: %{},
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
            kind: workflow_error_kind(step.fail.reason),
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
    private_details = Map.merge(private_details, boundary_producer_details(step))
    private_error = %{public_error | details: Map.merge(public_error.details, private_details)}

    case emit_execution_diagnostics(
           config.inspection_sink,
           evaluation_id,
           step.prints,
           private_error
         ) do
      :ok ->
        :ok

      {:error, :inspection_sink_error} ->
        :ok = RunState.fail(state, :inspection_sink_error, :inspection_sink_error)
    end

    {:error, public_error}
  end

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

  defp emit_execution_error(_sink, _evaluation_id, %Error{details: details})
       when map_size(details) == 0,
       do: :ok

  defp emit_execution_error(sink, evaluation_id, %Error{
         kind: kind,
         reason: reason,
         details: details
       }) do
    InspectionSink.emit(
      sink,
      "execution-error",
      %{evaluation_id: evaluation_id},
      %{environment: :workflow, kind: kind, reason: reason, details: details}
    )
  end

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
        RuntimeTools.mission_inventory(state, mission_renderings(config, :rendered))
      )
    )
    |> Map.put(
      "kernel-mission-model-context",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-mission-model-context",
        RuntimeTools.mission_model_context(state, mission_renderings(config, :model_rendered))
      )
    )
    |> Map.put(
      "kernel-result-contract",
      RuntimeTools.instrument(
        state,
        config.event_sink,
        :workflow,
        "kernel-result-contract",
        RuntimeTools.result_contract(config.result_contract)
      )
    )
    |> RuntimeTools.maybe_put_result_contract_failure(
      state,
      config.event_sink,
      config.result_contract,
      config.result_contract_source,
      config.workflow_environment.bundle
    )
    |> RuntimeTools.maybe_put_runtime_limit_failure(
      state,
      config.event_sink,
      config.limits,
      config.workflow_environment.bundle
    )
    |> RuntimeTools.trusted_tools(config.limits)
  end

  defp bundle_prelude(%{bundle: %{prelude: prelude}}), do: prelude
  defp bundle_prelude(_environment), do: nil

  defp entry_source_within_limit(source, limits) do
    if byte_size(source) <= limits.entry_source_bytes,
      do: :ok,
      else: {:error, :entry_source_exceeded}
  end

  defp terminal_result_within_limit?(value, limit) do
    case {RetainedSize.bytes_with_cap(value, limit), safe_encoded_size(value)} do
      {bytes, encoded} when is_integer(bytes) and bytes <= limit and encoded <= limit -> true
      _ -> false
    end
  end

  defp safe_encoded_size(value) do
    :erlang.external_size(value)
  rescue
    _exception -> :infinity
  end

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, _error}), do: :error
  defp terminal_reason({:ok, _result}), do: nil
  defp terminal_reason({:error, %Error{reason: reason}}), do: reason

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
            details: %{limit: :agent_turns, limit_value: limit}
          }}
       )
       when limit in 1..128 do
    Map.merge(stopped_data, %{
      failure_kind: "turn-limit",
      limit: :agent_turns,
      limit_value: limit
    })
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

  defp run_state_usage(state) do
    RunState.usage(state)
  catch
    :exit, _reason -> %{}
  end

  defp apply_terminal_failure(result, state) do
    case RunState.terminal_failure(state) do
      nil ->
        result

      %{kind: :event_sink_error} ->
        event_sink_error(RunState.usage(state))

      %{kind: kind, reason: reason} ->
        {:error,
         %Error{
           kind: kind,
           reason: reason,
           details: %{},
           usage: RunState.usage(state)
         }}
    end
  end

  defp maybe_emit_workflow_limit(
         state,
         sink,
         {:error, %Error{kind: :limit_exceeded, reason: reason}}
       ),
       do: Events.emit(state, sink, "limit-exceeded", %{reason: reason})

  defp maybe_emit_workflow_limit(_state, _sink, _result), do: :ok

  defp workflow_error_kind(reason)
       when reason in [:timeout, :compile_timeout, :memory_exceeded, :program_too_large],
       do: :limit_exceeded

  defp workflow_error_kind(_reason), do: :workflow_failed

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

        %{
          message: "#{limit} expired during a parallel operation",
          limit: limit,
          limit_ms: timeout_ms,
          phase: :execution
        }

      true ->
        limit =
          if timeout_ms == limits.workflow_timeout_ms,
            do: :workflow_timeout_ms,
            else: :run_duration_ms

        phase = if reason == :compile_timeout, do: :compilation, else: :execution

        %{
          message: "#{limit} exceeded during #{phase} after #{timeout_ms}ms",
          limit: limit,
          limit_ms: timeout_ms,
          phase: phase
        }
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
         %{
           reason: :runtime_limit_exceeded,
           details: %{limit: :agent_turns, limit_value: limit}
         },
         _timeout_ms,
         _limits,
         _sink
       )
       when limit in 1..128 do
    %{limit: :agent_turns, limit_value: limit}
  end

  defp workflow_error_details(fail, _timeout_ms, _limits, sink)
       when not is_nil(sink) do
    details =
      case EventSink.policy(sink) do
        :normal -> workflow_error_details_for_class(:normal, fail)
        _private_or_unavailable -> workflow_error_details_for_class(:private, fail)
      end

    Map.merge(details, SafeMetadata.retain_failure_taxonomy_fields(fail.details))
  end

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
