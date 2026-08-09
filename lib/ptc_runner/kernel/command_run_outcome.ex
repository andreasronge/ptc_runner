defmodule PtcRunner.Kernel.CommandRunOutcome do
  @moduledoc false

  alias PtcRunner.Kernel.ArtifactPublisher
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.Result

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
         %{result: {:ok, %Result{} = result}},
         result_class,
         artifact_state,
         run_ref,
         provider_activity
       )
       when result_class in [:normal, :private] do
    with {:ok, value} <- public_value(result_class, result.value),
         {:ok, usage} <- usage_projection(result.usage),
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
    diagnostics = failure_diagnostics(evidence, report, provider_activity)

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

  defp failure_diagnostics(evidence, report, provider_activity) do
    ([publication_primary(report)] ++
       Map.get(report, :secondary_errors, []) ++
       result_failure(evidence))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&failure_diagnostic(&1, provider_activity))
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

  defp failure_diagnostic(%CommandDiagnostic{} = diagnostic, _provider_activity), do: diagnostic

  defp failure_diagnostic({:error, {:result_contract_failed, _details}}, provider_activity),
    do: diagnostic(:result_cleanup, :result_contract_failed, provider_activity)

  defp failure_diagnostic({:result_contract_failed, _details}, provider_activity),
    do: diagnostic(:result_cleanup, :result_contract_failed, provider_activity)

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
         %Error{kind: :workflow_failed, details: %{result_projection: true}},
         provider_activity
       ),
       do: diagnostic(:result_cleanup, :result_invalid, provider_activity)

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

  defp publication_code(:trace), do: :trace_publication_failed
  defp publication_code(:inspection), do: :inspection_publication_failed
  defp publication_code(:result), do: :result_publication_failed

  defp diagnostic(phase, code, provider_activity) do
    case CommandDiagnostic.new(phase, code, provider_activity: provider_activity) do
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

  defp execution_evidence(%{result: {:ok, %Result{} = result}}) do
    with {:ok, usage} <- usage_projection(result.usage),
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

  defp execution_evidence(%{result: {:error, %Error{usage: usage}}}) do
    usage =
      case usage_projection(usage) do
        {:ok, value} -> value
        _invalid -> nil
      end

    %{"state" => "incomplete", "usage" => usage, "evaluation_memory" => nil}
  end

  defp execution_evidence(_report), do: %{"state" => "not_started"}

  defp public_value(:private, _value), do: {:ok, nil}
  defp public_value(:normal, value), do: json_value(value)

  defp usage_projection(usage) when is_map(usage) do
    with {:ok, capability_calls} <- capability_calls(Map.get(usage, :capability_calls)),
         {:ok, events_dropped} <- count_map(Map.get(usage, :events_dropped, %{})),
         values <- %{
           "remaining_ms" => Map.get(usage, :remaining_ms),
           "capability_calls" => capability_calls,
           "subordinate_evaluations" => Map.get(usage, :subordinate_evaluations),
           "protocol_errors" => Map.get(usage, :protocol_errors),
           "evaluation_memory_bytes" => Map.get(usage, :evaluation_memory_bytes),
           "evaluation_history_bytes" => Map.get(usage, :evaluation_history_bytes),
           "evaluation_continuation_bytes" => Map.get(usage, :evaluation_continuation_bytes),
           "events_dropped" => events_dropped
         },
         true <-
           Enum.all?(values, fn
             {_key, value} when is_map(value) -> true
             {_key, value} -> nonnegative?(value)
           end) do
      {:ok, values}
    else
      _invalid -> {:error, :invalid_usage}
    end
  end

  defp usage_projection(_usage), do: {:error, :invalid_usage}

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
