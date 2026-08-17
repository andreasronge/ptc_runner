defmodule PtcRunner.Kernel.CommandRunOutcome do
  @moduledoc """
  Converts a sealed execution outcome into the public command DTO.

  Hosts and the CLI share this seam: `settle/6` opens
  `PtcRunner.Kernel.ExecutionOutcome` under a publication authority and
  projects a `PtcRunner.Kernel.CommandOutcome`. Do not add a second public
  projection.
  """

  alias PtcRunner.Kernel.ArtifactPublisher
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.LLMUsageSummary
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultContractDiagnostic
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.ValueContractDiagnostic

  @doc """
  Opens one execution outcome and projects the public command DTO.

  `provider_activity` is the sealed boolean already decided for the run, not
  a reconstruction from process state.
  """
  @spec settle(
          term(),
          PublicationAuthority.t(),
          binary(),
          :normal | :private,
          map(),
          boolean()
        ) :: {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def settle(outcome, authority, run_ref, result_class, artifact_state, provider_activity)
      when result_class in [:normal, :private] and is_map(artifact_state) and
             is_boolean(provider_activity) do
    case ExecutionOutcome.open(outcome, authority) do
      {:ok, evidence} ->
        project(
          evidence,
          ArtifactPublisher.publish(evidence, authority),
          run_ref,
          provider_activity
        )

      {:error, reason} ->
        operation_failure(
          run_ref,
          reason,
          result_class,
          artifact_state,
          provider_activity,
          :incomplete
        )
    end
  rescue
    _exception ->
      internal_failure(
        run_ref,
        provider_activity,
        result_class,
        artifact_state,
        :incomplete
      )
  catch
    _kind, _reason ->
      internal_failure(
        run_ref,
        provider_activity,
        result_class,
        artifact_state,
        :incomplete
      )
  end

  @doc false
  @spec project(map(), {:ok, map()} | {:error, map()}, binary(), boolean()) ::
          {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def project(evidence, settlement, run_ref, provider_activity)
      when is_map(evidence) and is_binary(run_ref) and is_boolean(provider_activity) do
    case settlement do
      {:ok, %{result_class: result_class, artifact_state: artifact_state}} ->
        project_success(evidence, result_class, artifact_state, run_ref, provider_activity)

      {:error, %{result_class: result_class, artifact_state: artifact_state} = report} ->
        project_failure(
          evidence,
          report,
          result_class,
          artifact_state,
          run_ref,
          provider_activity
        )

      _invalid ->
        internal_failure(
          run_ref,
          provider_activity,
          evidence_result_class(evidence),
          settlement_artifact_state(settlement),
          :incomplete
        )
    end
  rescue
    _exception ->
      internal_failure(
        run_ref,
        provider_activity,
        evidence_result_class(evidence),
        settlement_artifact_state(settlement),
        :incomplete
      )
  catch
    _kind, _reason ->
      internal_failure(
        run_ref,
        provider_activity,
        evidence_result_class(evidence),
        settlement_artifact_state(settlement),
        :incomplete
      )
  end

  def project(_evidence, settlement, run_ref, provider_activity),
    do:
      internal_failure(
        run_ref,
        provider_activity == true,
        :normal,
        settlement_artifact_state(settlement),
        :incomplete
      )

  @doc false
  @spec operation_failure(
          binary(),
          CommandDiagnostic.t() | term(),
          :normal | :private,
          map(),
          boolean(),
          :not_started | :incomplete
        ) :: {:error, CommandOutcome.t()}
  def operation_failure(
        run_ref,
        reason,
        result_class,
        artifact_state,
        provider_activity,
        execution_state
      )
      when execution_state in [:not_started, :incomplete] do
    diagnostic =
      case reason do
        %CommandDiagnostic{} = diagnostic -> diagnostic
        _other -> diagnostic(:internal, :internal_error, provider_activity)
      end

    execution = failure_execution(execution_state)

    {:error,
     CommandOutcome.run_classified_error(
       run_ref,
       result_class,
       diagnostic,
       [],
       artifact_state,
       execution
     )}
  rescue
    _exception ->
      internal_failure(
        run_ref,
        provider_activity,
        result_class,
        artifact_state,
        execution_state
      )
  end

  defp failure_execution(:not_started), do: %{"state" => "not_started"}

  defp failure_execution(:incomplete),
    do: %{"state" => "incomplete", "usage" => nil, "evaluation_memory" => nil}

  defp project_success(
         %{result: {:ok, %Result{} = result}} = evidence,
         result_class,
         artifact_state,
         run_ref,
         provider_activity
       )
       when result_class in [:normal, :private] do
    with {:ok, value} <- public_value(result_class, result.value),
         {:ok, usage} <- usage_projection(result.usage, Map.get(evidence, :terminal_batch)),
         {:ok, evaluation_memory} <- evaluation_memory_projection(result.evaluation_memory) do
      {:ok,
       CommandOutcome.run_success(
         run_ref,
         result_class,
         value,
         artifact_state,
         usage,
         evaluation_memory
       )}
    else
      _invalid ->
        internal_failure(run_ref, provider_activity, result_class, artifact_state, :incomplete)
    end
  end

  defp project_success(_evidence, _result_class, artifact_state, run_ref, provider_activity),
    do: internal_failure(run_ref, provider_activity, :normal, artifact_state, :incomplete)

  defp project_failure(
         evidence,
         report,
         result_class,
         artifact_state,
         run_ref,
         provider_activity
       )
       when result_class in [:normal, :private] do
    diagnostics = failure_diagnostics(evidence, report, result_class, provider_activity)

    case diagnostics do
      [primary | secondary] ->
        {:error,
         CommandOutcome.run_classified_error(
           run_ref,
           result_class,
           primary,
           secondary,
           artifact_state,
           execution_evidence(evidence)
         )}

      [] ->
        internal_failure(run_ref, provider_activity, result_class, artifact_state, :incomplete)
    end
  end

  defp project_failure(
         _evidence,
         _report,
         _result_class,
         artifact_state,
         run_ref,
         provider_activity
       ),
       do: internal_failure(run_ref, provider_activity, :normal, artifact_state, :incomplete)

  defp failure_diagnostics(evidence, report, result_class, provider_activity) do
    ([publication_primary(report)] ++
       Map.get(report, :secondary_errors, []) ++
       result_failure(evidence))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&failure_diagnostic(&1, provider_activity, result_class))
    |> Enum.uniq_by(&{&1.phase, &1.code, &1.subject})
    |> Enum.sort_by(&precedence/1)
    |> Enum.uniq_by(&DiagnosticCatalog.compound_category(&1.phase, &1.code))
    |> Enum.take(7)
  end

  defp publication_primary(%{
         artifact_state: %{"result" => "recovery_written"},
         error: {:result, :destination_collision} = collision
       }),
       do: collision

  defp publication_primary(%{
         artifact_state: %{"result" => "recovery_written"},
         error: :destination_collision
       }),
       do: {:result, :destination_collision}

  defp publication_primary(%{artifact_state: %{"result" => state}})
       when state in ["recovery_written", "finalization_uncertain"],
       do: {:result, :result_publication_failed}

  defp publication_primary(report), do: Map.get(report, :error)

  defp result_failure(%{result: {:error, %Error{} = error}}), do: [error]
  defp result_failure(_evidence), do: []

  defp failure_diagnostic(
         %Error{
           kind: :workflow_failed,
           reason: reason,
           details: %{replay_request_hash: _request_hash}
         },
         provider_activity,
         :private
       )
       when reason in [:explicit_failure, :pmap_error, :pcalls_error, :llm_provider_failed],
       do: diagnostic(:execution, :workflow_failed, provider_activity)

  defp failure_diagnostic(failure, provider_activity, _result_class),
    do: failure_diagnostic(failure, provider_activity)

  defp failure_diagnostic(%CommandDiagnostic{} = diagnostic, _provider_activity), do: diagnostic

  defp failure_diagnostic({:error, {:result_contract_failed, details}}, provider_activity),
    do: result_contract_diagnostic(details, provider_activity)

  defp failure_diagnostic({:result_contract_failed, details}, provider_activity),
    do: result_contract_diagnostic(details, provider_activity)

  defp failure_diagnostic(%Error{kind: :provider_cleanup_error}, _provider_activity),
    do: diagnostic(:result_cleanup, :provider_cleanup_failed, true)

  defp failure_diagnostic(%Error{kind: :event_sink_error}, provider_activity),
    do: diagnostic(:execution, :event_sink_unavailable, provider_activity)

  defp failure_diagnostic(%Error{kind: :inspection_sink_error}, provider_activity),
    do: diagnostic(:execution, :inspection_sink_unavailable, provider_activity)

  defp failure_diagnostic(
         %Error{kind: :limit_exceeded, reason: :terminal_result_exceeded},
         provider_activity
       ),
       do: diagnostic(:result_cleanup, :result_limit_exceeded, provider_activity)

  defp failure_diagnostic(
         %Error{kind: :limit_exceeded, details: %{limit: :run_duration_ms}},
         provider_activity
       ),
       do: diagnostic(:execution, :run_timeout, provider_activity)

  defp failure_diagnostic(%Error{kind: :limit_exceeded}, provider_activity),
    do: diagnostic(:execution, :runtime_limit_exceeded, provider_activity)

  defp failure_diagnostic(
         %Error{
           kind: :workflow_failed,
           reason: :result_contract_failed,
           details: details
         },
         provider_activity
       ) do
    case ResultContractDiagnostic.retain_details(details) do
      {:ok, retained} -> result_contract_diagnostic(retained, provider_activity)
      :error -> diagnostic(:execution, :workflow_failed, provider_activity)
    end
  end

  defp failure_diagnostic(
         %Error{kind: :workflow_failed, details: %{result_projection: true}},
         provider_activity
       ),
       do: diagnostic(:result_cleanup, :result_invalid, provider_activity)

  defp failure_diagnostic(
         %Error{
           kind: :workflow_failed,
           reason: reason,
           details: %{replay_request_hash: request_hash}
         },
         provider_activity
       )
       when reason in [:explicit_failure, :pmap_error, :pcalls_error, :llm_provider_failed] do
    case LLMReplayDiagnostic.message(request_hash) do
      {:ok, message} ->
        diagnostic(:execution, :replay_fixture_missing, provider_activity,
          message: message,
          source: CommandSource.fixed(:runtime)
        )

      :error ->
        diagnostic(:execution, :workflow_failed, provider_activity)
    end
  end

  defp failure_diagnostic(
         %Error{
           kind: :workflow_failed,
           reason: reason,
           details: %{
             failure_kind: "llm-provider-error",
             llm_provider_failure: provider_failure,
             llm_provider_retryable?: retryable?
           }
         },
         provider_activity
       )
       when reason in [:explicit_failure, :pmap_error, :pcalls_error, :llm_provider_failed] do
    diagnostic(
      :execution,
      llm_failure_code(provider_failure, retryable?),
      provider_activity
    )
  end

  defp failure_diagnostic(
         %Error{
           kind: :workflow_failed,
           reason: :runtime_limit_exceeded,
           details: %{limit: :subordinate_evaluations, limit_value: limit}
         },
         provider_activity
       ) do
    case RuntimeLimitDiagnostic.subordinate_evaluations_message(limit) do
      {:ok, message} ->
        diagnostic(:execution, :runtime_limit_exceeded, provider_activity,
          message: message,
          source: CommandSource.fixed(:runtime)
        )

      :error ->
        diagnostic(:execution, :workflow_failed, provider_activity)
    end
  end

  defp failure_diagnostic(
         %Error{
           kind: :workflow_failed,
           reason: :runtime_limit_exceeded,
           details: %{limit: :agent_turns, limit_value: limit}
         },
         provider_activity
       ) do
    case RuntimeLimitDiagnostic.agent_turns_message(limit) do
      {:ok, message} ->
        diagnostic(:execution, :runtime_limit_exceeded, provider_activity, message: message)

      :error ->
        diagnostic(:execution, :workflow_failed, provider_activity)
    end
  end

  defp failure_diagnostic(%Error{kind: :workflow_failed}, provider_activity),
    do: diagnostic(:execution, :workflow_failed, provider_activity)

  defp failure_diagnostic({stage, :destination_collision}, provider_activity)
       when stage in [:trace, :inspection, :result],
       do: diagnostic(:publication, :destination_collision, provider_activity)

  defp failure_diagnostic({stage, _reason}, provider_activity)
       when stage in [:trace, :inspection, :result],
       do: diagnostic(:publication, publication_code(stage), provider_activity)

  defp failure_diagnostic(:recovery_cleanup_failed, provider_activity),
    do: diagnostic(:publication, :recovery_cleanup_failed, provider_activity)

  defp failure_diagnostic(_reason, provider_activity),
    do: diagnostic(:internal, :internal_error, provider_activity)

  defp llm_failure_code(:authentication_failed, false), do: :llm_authentication_failed
  defp llm_failure_code(:payment_required, false), do: :llm_payment_required
  defp llm_failure_code(:rate_limited, true), do: :llm_rate_limited
  defp llm_failure_code(:tool_calling_unsupported, false), do: :llm_tool_calling_unsupported
  defp llm_failure_code(:not_found, false), do: :llm_model_not_found
  defp llm_failure_code(:invalid_request, false), do: :llm_request_invalid
  defp llm_failure_code(:denied, false), do: :llm_access_denied
  defp llm_failure_code(:timeout, true), do: :llm_timeout
  defp llm_failure_code(_failure, true), do: :llm_provider_unavailable
  defp llm_failure_code(_failure, false), do: :llm_provider_failed

  defp result_contract_diagnostic(details, provider_activity) when is_map(details) do
    source = result_contract_source(details)
    {source, path} = ValueContractDiagnostic.diagnostic_parts(source, details)

    opts = [source: source, path: path]

    opts =
      case {details, source} do
        {%{agent_turns: turns, constraint: constraint}, %CommandSource{}} ->
          case ResultContractDiagnostic.message(turns, constraint) do
            {:ok, message} -> Keyword.put(opts, :message, message)
            :error -> opts
          end

        _ordinary_or_source_less_contract_failure ->
          opts
      end

    diagnostic(:result_cleanup, :result_contract_failed, provider_activity, opts)
  end

  defp result_contract_diagnostic(_details, provider_activity),
    do: diagnostic(:result_cleanup, :result_contract_failed, provider_activity)

  defp result_contract_source(%{contract_source: name}) when is_binary(name) do
    case CommandSource.new(:result_contract, name) do
      {:ok, source} -> source
      {:error, :invalid_command_source} -> nil
    end
  end

  defp result_contract_source(_details), do: nil

  defp publication_code(:trace), do: :trace_publication_failed
  defp publication_code(:inspection), do: :inspection_publication_failed
  defp publication_code(:result), do: :result_publication_failed

  defp diagnostic(phase, code, provider_activity, opts \\ []) do
    opts = Keyword.put(opts, :provider_activity, provider_activity)

    case CommandDiagnostic.new(phase, code, opts) do
      {:ok, diagnostic} ->
        diagnostic

      {:error, _reason} ->
        CommandDiagnostic.new!(:internal, :internal_error, provider_activity: true)
    end
  end

  defp precedence(diagnostic) do
    case DiagnosticCatalog.compound_precedence(diagnostic.phase, diagnostic.code) do
      {:ok, key} -> key
      :error -> {9, 0}
    end
  end

  defp execution_evidence(%{result: {:ok, %Result{} = result}} = evidence) do
    with {:ok, usage} <- usage_projection(result.usage, Map.get(evidence, :terminal_batch)),
         {:ok, memory} <- evaluation_memory_projection(result.evaluation_memory) do
      %{
        "state" => "finished",
        "outcome" => "ok",
        "diagnostic" => nil,
        "usage" => usage,
        "evaluation_memory" => memory
      }
    else
      _invalid -> %{"state" => "incomplete", "usage" => nil, "evaluation_memory" => nil}
    end
  end

  defp execution_evidence(%{result: {:error, %Error{usage: usage}}} = evidence) do
    usage =
      case usage_projection(usage, Map.get(evidence, :terminal_batch)) do
        {:ok, value} -> value
        _invalid -> nil
      end

    %{"state" => "incomplete", "usage" => usage, "evaluation_memory" => nil}
  end

  defp execution_evidence(_report), do: %{"state" => "not_started"}

  defp public_value(:private, _value), do: {:ok, nil}
  defp public_value(:normal, value), do: json_value(value)

  defp usage_projection(usage, terminal_batch) when is_map(usage) do
    with {:ok, capability_calls} <- capability_calls(Map.get(usage, :capability_calls)),
         {:ok, evaluations_by_mission} <-
           count_map(Map.get(usage, :evaluations_by_mission, %{})),
         {:ok, events_dropped} <- count_map(Map.get(usage, :events_dropped, %{})),
         values <-
           %{
             "remaining_ms" => Map.get(usage, :remaining_ms),
             "capability_calls" => capability_calls,
             "subordinate_evaluations" => Map.get(usage, :subordinate_evaluations),
             "evaluations_by_mission" => evaluations_by_mission,
             "protocol_errors" => Map.get(usage, :protocol_errors),
             "evaluation_memory_bytes" => Map.get(usage, :evaluation_memory_bytes),
             "evaluation_history_bytes" => Map.get(usage, :evaluation_history_bytes),
             "evaluation_continuation_bytes" => Map.get(usage, :evaluation_continuation_bytes),
             "events_dropped" => events_dropped
           }
           |> Map.merge(llm_usage_projection(terminal_batch)),
         true <-
           Enum.all?(values, fn
             {_key, value} when is_map(value) ->
               true

             {_key, value} when is_list(value) ->
               true

             {"llm_usage_state", value} ->
               value in ["available", "unavailable"]

             {key, nil}
             when key in [
                    "llm_usage",
                    "llm_usage_by_model",
                    "unattributed_model_calls"
                  ] ->
               true

             {_key, value} ->
               nonnegative?(value)
           end) do
      {:ok, values}
    else
      _invalid -> {:error, :invalid_usage}
    end
  end

  defp usage_projection(_usage, _terminal_batch), do: {:error, :invalid_usage}

  defp llm_usage_projection({:ok, events}) do
    case LLMUsageSummary.terminal(events) do
      {:ok, summary} -> Map.put(summary, "llm_usage_state", "available")
      {:error, :invalid_event_batch} -> unavailable_llm_usage()
    end
  end

  defp llm_usage_projection(_terminal_batch), do: unavailable_llm_usage()

  defp unavailable_llm_usage do
    %{
      "llm_usage_state" => "unavailable",
      "llm_usage" => nil,
      "llm_usage_by_model" => nil,
      "unattributed_model_calls" => nil
    }
  end

  defp capability_calls(calls) when is_map(calls) do
    Enum.reduce_while(calls, {:ok, %{}}, fn
      {scope, counts}, {:ok, acc} when scope in [:workflow, :mission] and is_map(counts) ->
        case count_map(counts) do
          {:ok, counts} ->
            scoped = Map.new(counts, fn {name, count} -> {"#{scope}/#{name}", count} end)
            {:cont, {:ok, Map.merge(acc, scoped)}}

          {:error, _reason} = error ->
            {:halt, error}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_usage}}
    end)
  end

  defp capability_calls(_calls), do: {:error, :invalid_usage}

  defp count_map(counts) when is_map(counts) do
    if Enum.all?(counts, fn {name, count} ->
         is_binary(name) and byte_size(name) in 1..128 and nonnegative?(count)
       end) do
      {:ok, counts}
    else
      {:error, :invalid_usage}
    end
  end

  defp count_map(_counts), do: {:error, :invalid_usage}

  defp evaluation_memory_projection(memory) when is_map(memory) do
    values =
      Map.new(
        [:defined_count, :history_count, :memory_bytes, :history_bytes, :bytes],
        fn key -> {Atom.to_string(key), Map.get(memory, key)} end
      )

    if Enum.all?(values, fn {_key, value} -> nonnegative?(value) end),
      do: {:ok, values},
      else: {:error, :invalid_evaluation_memory}
  end

  defp evaluation_memory_projection(_memory), do: {:error, :invalid_evaluation_memory}

  defp nonnegative?(value), do: is_integer(value) and value >= 0

  defp json_value(value) do
    with {:ok, encoded} <- Jason.encode(value), do: Jason.decode(encoded)
  end

  defp internal_failure(
         run_ref,
         provider_activity,
         result_class,
         artifact_state,
         execution_state
       ) do
    diagnostic = diagnostic(:internal, :internal_error, provider_activity)

    {:error,
     CommandOutcome.run_classified_error(
       run_ref,
       result_class,
       diagnostic,
       [],
       artifact_state,
       failure_execution(execution_state)
     )}
  end

  defp default_artifact_state,
    do: %{
      "trace" => "not_requested",
      "inspection" => "not_requested",
      "result" => "not_requested"
    }

  defp evidence_result_class(%{result_class: result_class})
       when result_class in [:normal, :private],
       do: result_class

  defp evidence_result_class(_evidence), do: :normal

  defp settlement_artifact_state({_status, %{artifact_state: artifact_state}})
       when is_map(artifact_state),
       do: artifact_state

  defp settlement_artifact_state(_settlement), do: default_artifact_state()
end
