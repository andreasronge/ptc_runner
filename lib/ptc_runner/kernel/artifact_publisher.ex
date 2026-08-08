defmodule PtcRunner.Kernel.ArtifactPublisher do
  @moduledoc false

  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.TraceLog

  @artifact_names [:trace, :inspection, :result]

  @type report :: %{
          required(:result_class) => :normal | :private,
          required(:artifact_state) => %{binary() => binary()},
          required(:written) => [atom()],
          required(:failed) => [atom()],
          required(:withheld) => [atom()],
          required(:secondary_errors) => [term()],
          optional(:result) => term(),
          optional(:error) => term()
        }

  @spec publish(ExecutionOutcome.publication_evidence(), PublicationAuthority.t()) ::
          {:ok, report()} | {:error, report()}
  def publish(evidence, authority), do: publish(evidence, authority, %{})

  @doc false
  @spec publish(ExecutionOutcome.publication_evidence(), PublicationAuthority.t(), map()) ::
          {:ok, report()} | {:error, report()}
  def publish(evidence, authority, fault_hooks)
      when is_map(evidence) and is_map(fault_hooks) do
    states = initial_states(authority)

    base = %{
      result_class: evidence.result_class,
      artifact_state: states,
      written: [],
      failed: [],
      withheld: [],
      secondary_errors: []
    }

    result =
      if PublicationAuthority.authorized?(authority) do
        do_publish(evidence, authority, base, fault_hooks)
      else
        {:error,
         Map.merge(base, %{
           error: :invalid_execution_outcome,
           withheld: [:trace, :inspection, :result]
         })}
      end

    case result do
      {:error, report} ->
        report = attach_failure_result(report, evidence)
        cleanup_unpublished(authority, report)
        {:error, report}

      success ->
        success
    end
  end

  def publish(_evidence, _authority, _fault_hooks),
    do:
      {:error,
       %{
         result_class: :normal,
         artifact_state: initial_states(nil),
         written: [],
         failed: [],
         withheld: @artifact_names,
         secondary_errors: [],
         error: :invalid_execution_outcome
       }}

  defp do_publish(%{terminal_batch: {:error, _reason}} = evidence, authority, report, hooks) do
    with {:ok, report} <- maybe_cleanup_recovery(evidence, authority, report),
         {:ok, report} <- publish_unrecoverable_observations(evidence, authority, report, hooks) do
      result_execution(evidence, report)
    end
  end

  defp do_publish(%{result_contract: {:error, _details}} = evidence, authority, report, hooks) do
    with {:ok, report} <- maybe_cleanup_recovery(evidence, authority, report),
         {:ok, report} <- publish_observations(evidence, authority, report, hooks) do
      {:error, Map.put(report, :error, evidence.result_contract)}
    else
      {:error, report} -> {:error, preserve_primary_error(report, evidence.result_contract)}
    end
  end

  defp do_publish(%{result: {:ok, %Result{value: value}}} = evidence, authority, report, hooks) do
    case evidence.result_class do
      :private -> publish_private(evidence, authority, report, hooks, value)
      :normal -> publish_normal(evidence, authority, report, hooks, value)
    end
  end

  defp do_publish(evidence, authority, report, hooks) do
    with {:ok, report} <- maybe_cleanup_recovery(evidence, authority, report),
         {:ok, report} <- publish_observations(evidence, authority, report, hooks) do
      result_execution(evidence, report)
    end
  end

  defp publish_normal(evidence, authority, report, hooks, value) do
    case recovery_handle(authority) do
      nil ->
        with {:ok, report} <- publish_observations(evidence, authority, report, hooks),
             {:ok, encoded, report} <- prepare_result(authority, value, :normal, report),
             {:ok, report} <- publish_normal_result(authority, report, encoded, hooks),
             {:ok, report} <- result_execution(evidence, report) do
          {:ok, Map.put(report, :result, evidence.result)}
        end

      recovery ->
        with {:ok, encoded, report} <- prepare_result(authority, value, :normal, report),
             {:ok, report} <- materialize_recovery(recovery, report, encoded, hooks),
             {:ok, report} <- publish_observations(evidence, authority, report, hooks),
             {:ok, report} <- finalize_recovery(recovery, authority, report),
             {:ok, report} <- result_execution(evidence, report) do
          {:ok, Map.put(report, :result, evidence.result)}
        end
    end
  end

  defp publish_private(evidence, authority, report, hooks, value) do
    case recovery_handle(authority) do
      nil ->
        case publish_observations(evidence, authority, report, hooks) do
          {:ok, report} ->
            fail(report, :private_result_requires_private_destination, [:trace, :inspection], [
              :result
            ])

          {:error, report} ->
            {:error, report}
        end

      recovery ->
        with {:ok, encoded, report} <- prepare_result(authority, value, :private, report),
             {:ok, report} <- materialize_recovery(recovery, report, encoded, hooks),
             {:ok, report} <- publish_observations(evidence, authority, report, hooks),
             {:ok, report} <- finalize_recovery(recovery, authority, report),
             {:ok, report} <- result_execution(evidence, report) do
          {:ok, Map.put(report, :result, evidence.result)}
        end
    end
  end

  defp publish_observations(evidence, authority, report, hooks) do
    case publish_trace(evidence, authority, report, hooks) do
      {:ok, report} -> publish_inspection(evidence, authority, report, hooks)
      {:error, report} -> {:error, report}
    end
  end

  defp publish_unrecoverable_observations(evidence, authority, report, hooks),
    do: publish_observations(evidence, authority, report, hooks)

  defp publish_trace(
         %{terminal_batch: {:ok, events}, result_class: class},
         authority,
         report,
         hooks
       ) do
    case handle(authority, :trace) do
      nil ->
        {:ok, with_withheld(report, :trace)}

      trace ->
        case TraceLog.publish_handle(trace, events, class == :private, hook(hooks, :trace)) do
          :ok ->
            {:ok, with_written(report, :trace)}

          {:error, :publication_committed} ->
            {:error, committed_failure(report, :trace)}

          {:error, reason} ->
            {:error, publication_failure(report, :trace, reason)}
        end
    end
  end

  defp publish_trace(_evidence, _authority, report, _hooks),
    do: {:ok, with_withheld(report, :trace)}

  defp publish_inspection(%{inspection: :disabled}, _authority, report, _hooks),
    do: {:ok, with_withheld(report, :inspection)}

  defp publish_inspection(%{inspection: {:error, reason}}, _authority, report, _hooks),
    do: {:error, publication_failure(report, :inspection, reason)}

  defp publish_inspection(
         %{inspection: {:ok, records}, terminal_batch: {:ok, events}},
         authority,
         report,
         hooks
       ) do
    case handle(authority, :inspect) do
      nil ->
        {:error, publication_failure(report, :inspection, :missing_destination)}

      inspection ->
        case InspectionArtifact.persist_handle(
               inspection,
               records,
               events,
               hook(hooks, :inspection)
             ) do
          :ok -> {:ok, with_written(report, :inspection)}
          {:error, reason} -> {:error, publication_failure(report, :inspection, reason)}
        end
    end
  end

  defp publish_inspection(_evidence, _authority, report, _hooks),
    do: {:ok, with_withheld(report, :inspection)}

  defp publish_normal_result(authority, report, encoded, hooks) do
    case handle(authority, :output) do
      nil ->
        {:ok, with_withheld(report, :result)}

      output ->
        case ResultArtifact.persist_prepared_handle(
               output,
               encoded,
               :normal,
               hook(hooks, :result)
             ) do
          :ok -> {:ok, with_written(report, :result)}
          {:error, reason} -> {:error, publication_failure(report, :result, reason)}
        end
    end
  end

  defp materialize_recovery(recovery, report, encoded, hooks) do
    case ResultArtifact.persist_prepared_handle(
           recovery,
           encoded,
           :private,
           hook(hooks, :result)
         ) do
      :ok ->
        {:ok, with_recovery_written(report, :result)}

      {:error, {:recovery_written, reason}} ->
        {:error, with_error(report, :recovery_written, :result, reason)}

      {:error, {:finalization_uncertain, reason}} ->
        {:error, with_error(report, :finalization_uncertain, :result, reason)}

      {:error, :directory_sync_failed} ->
        # `sync_and_retain/1` has already marked the recovery owner to keep the
        # complete value. Leave it available for inspection; authority cleanup
        # will close the retained handle after the failed publication is
        # reported.
        {:error, publication_failure(report, :result, :directory_sync_failed)}

      {:error, reason} ->
        case PublicationHandle.unlink(recovery) do
          :ok ->
            {:error, publication_failure(report, :result, reason)}

          {:error, _cleanup_reason} ->
            {:error, recovery_cleanup_failure(report, :result, reason)}
        end
    end
  end

  defp prepare_result(authority, value, class, report) do
    case result_handle(authority) do
      nil ->
        {:ok, nil, report}

      %PublicationHandle{kind: :recovery} = _handle ->
        case ResultArtifact.prepare(value, class, :private) do
          {:ok, encoded} -> {:ok, encoded, report}
          {:error, reason} -> {:error, publication_failure(report, :result, reason)}
        end

      %PublicationHandle{} ->
        case ResultArtifact.prepare(value, class, :normal) do
          {:ok, encoded} -> {:ok, encoded, report}
          {:error, reason} -> {:error, publication_failure(report, :result, reason)}
        end
    end
  end

  defp finalize_recovery(recovery, authority, report) do
    requested = requested_result(authority)

    case PublicationHandle.verify(recovery) do
      :ok ->
        case PublicationAuthority.requested_result_handle(authority) do
          %PublicationHandle{} = requested_handle ->
            finalize_recovery_link(recovery, authority, requested, requested_handle, report)

          _other ->
            {:error, with_error(report, :recovery_written, :result, :result_publication_failed)}
        end

      _invalid_recovery ->
        {:error, with_error(report, :finalization_uncertain, :result, :result_publication_failed)}
    end
  end

  defp finalize_recovery_link(recovery, authority, requested, requested_handle, report) do
    case PublicationHandle.link_to(recovery, requested, requested_handle) do
      :ok -> finalize_linked(recovery, authority, report)
      error -> finalize_link_failure(error, recovery, requested, report)
    end
  end

  defp finalize_linked(recovery, authority, report) do
    case PublicationAuthority.release_requested_result(authority) do
      :ok ->
        case PublicationHandle.unlink(recovery) do
          :ok ->
            {:ok, with_state(report, :result, "written")}

          {:error, reason} ->
            {:error, with_error(report, :finalization_uncertain, :result, reason)}
        end

      {:error, _reason} ->
        {:error, with_error(report, :finalization_uncertain, :result, :result_publication_failed)}
    end
  end

  defp finalize_link_failure(
         {:error, :publication_collision},
         recovery,
         _requested,
         report
       ) do
    if PublicationHandle.recovery_reachable?(recovery),
      do: {:error, with_error(report, :recovery_written, :result, :destination_collision)},
      else:
        {:error, with_error(report, :finalization_uncertain, :result, :result_publication_failed)}
  end

  defp finalize_link_failure(
         {:error, :requested_reservation_lost},
         recovery,
         _requested,
         report
       ) do
    if PublicationHandle.recovery_reachable?(recovery),
      do: {:error, with_error(report, :recovery_written, :result, :result_publication_failed)},
      else:
        {:error, with_error(report, :finalization_uncertain, :result, :result_publication_failed)}
  end

  defp finalize_link_failure(
         {:error, :publication_rollback_recovered},
         _recovery,
         _requested,
         report
       ),
       do: {:error, with_error(report, :recovery_written, :result, :result_publication_failed)}

  defp finalize_link_failure(
         {:error, :publication_finalization_uncertain},
         _recovery,
         _requested,
         report
       ),
       do:
         {:error,
          with_error(report, :finalization_uncertain, :result, :result_publication_failed)}

  defp finalize_link_failure({:error, _reason}, recovery, requested, report) do
    cond do
      linked_to_requested?(recovery, requested) ->
        {:error, with_error(report, :finalization_uncertain, :result, :result_publication_failed)}

      PublicationHandle.recovery_reachable?(recovery) ->
        {:error, with_error(report, :recovery_written, :result, :result_publication_failed)}

      true ->
        {:error, with_error(report, :finalization_uncertain, :result, :result_publication_failed)}
    end
  end

  defp maybe_cleanup_recovery(_evidence, authority, report) do
    case recovery_handle(authority) do
      nil ->
        {:ok, report}

      recovery ->
        case PublicationHandle.unlink(recovery) do
          :ok ->
            {:ok, with_withheld(report, :result)}

          {:error, _reason} ->
            {:error, recovery_cleanup_failure(report, :result, :recovery_cleanup_failed)}
        end
    end
  end

  defp result_execution(%{result: {:ok, _result}}, report), do: {:ok, report}

  defp result_execution(%{result: {:error, error}}, report),
    do: {:error, Map.put(report, :error, error)}

  defp handle(authority, key), do: Map.get(PublicationAuthority.handles(authority), key)

  defp result_handle(authority), do: handle(authority, :output) || recovery_handle(authority)

  defp recovery_handle(authority), do: Map.get(PublicationAuthority.handles(authority), :recovery)

  defp requested_result(authority) do
    authority
    |> PublicationAuthority.destination_options()
    |> Keyword.get(:private_output)
  end

  defp linked_to_requested?(recovery, requested) do
    PublicationHandle.recovery_reachable?(recovery) and
      case File.lstat(requested, time: :posix) do
        {:ok, %{major_device: major, minor_device: minor, inode: inode}} ->
          {major, minor, inode} == PublicationHandle.identity(recovery)

        _other ->
          false
      end
  end

  defp initial_states(nil), do: Map.new(@artifact_names, &{Atom.to_string(&1), "not_requested"})

  defp initial_states(authority) do
    options =
      if PublicationAuthority.valid?(authority),
        do: PublicationAuthority.destination_options(authority),
        else: []

    %{
      "trace" => if(Keyword.has_key?(options, :trace), do: "not_written", else: "not_requested"),
      "inspection" =>
        if(Keyword.has_key?(options, :inspect), do: "not_written", else: "not_requested"),
      "result" =>
        if(Keyword.has_key?(options, :output) or Keyword.has_key?(options, :private_output),
          do: "not_written",
          else: "not_requested"
        )
    }
  end

  defp with_state(report, key, state),
    do: %{report | artifact_state: Map.put(report.artifact_state, Atom.to_string(key), state)}

  defp with_written(report, key),
    do:
      report
      |> with_state(key, "written")
      |> update_class(:written, key)

  defp with_recovery_written(report, key),
    do:
      report
      |> with_state(key, "recovery_written")
      |> update_class(:written, key)

  defp with_withheld(report, key), do: update_class(report, :withheld, key)

  defp publication_failure(report, key, reason),
    do:
      report
      |> with_error(:failed, key, publication_reason(reason))
      |> with_unwritten_withheld()
      |> Map.put(:error, {key, publication_reason(reason)})

  defp committed_failure(report, key),
    do:
      report
      |> with_error(:written, key, :publication_committed)
      |> with_unwritten_withheld()
      |> Map.put(:error, {key, :publication_committed})

  defp recovery_cleanup_failure(report, key, reason),
    do:
      report
      |> with_error(:failed, key, reason)
      |> with_unwritten_withheld()
      |> Map.put(:error, :recovery_cleanup_failed)

  defp publication_reason(:publication_collision), do: :destination_collision
  defp publication_reason(reason), do: reason

  defp with_error(report, state, key, reason) when is_atom(state) do
    state = Atom.to_string(state)
    report = with_state(report, key, state)

    report =
      case state do
        "failed" -> update_class(report, :failed, key)
        "written" -> update_class(report, :written, key)
        "recovery_written" -> update_class(report, :written, key)
        "finalization_uncertain" -> update_class(report, :written, key)
        _other -> report
      end

    if reason, do: Map.put(report, :error, reason), else: report
  end

  defp update_class(report, field, key),
    do: Map.update!(report, field, fn classes -> Enum.uniq([key | classes]) end)

  defp with_unwritten_withheld(report) do
    Enum.reduce(@artifact_names, report, fn key, report ->
      state = Map.fetch!(report.artifact_state, Atom.to_string(key))

      if state in ["not_requested", "not_written"],
        do: with_withheld(report, key),
        else: report
    end)
  end

  defp fail(report, error, _written, _withheld) do
    report =
      report
      |> with_unwritten_withheld()
      |> Map.put(:error, error)

    {:error, report}
  end

  defp hook(hooks, key), do: Map.get(hooks, key)

  defp preserve_primary_error(report, primary) do
    secondary = Map.fetch!(report, :error)

    report
    |> Map.put(:error, primary)
    |> Map.update!(:secondary_errors, &(&1 ++ [secondary]))
  end

  defp attach_failure_result(
         %{error: {:error, {:result_contract_failed, _details}}} = report,
         _evidence
       ),
       do: report

  defp attach_failure_result(report, evidence) do
    if failure_result_required?(report) do
      Map.put(report, :result, safe_result(evidence.result, evidence.result_class))
    else
      report
    end
  end

  defp failure_result_required?(%{failed: failed, artifact_state: states} = report) do
    failed != [] or
      Map.get(states, "result") in ["recovery_written", "finalization_uncertain"] or
      publication_error?(Map.get(report, :error))
  end

  defp publication_error?({key, _reason}) when key in @artifact_names, do: true
  defp publication_error?(_error), do: false

  defp safe_result({:ok, %Result{} = result}, :private),
    do: {:ok, %Result{result | value: :redacted}}

  defp safe_result(result, _class), do: result

  defp cleanup_unpublished(authority, report) do
    handles = PublicationAuthority.handles(authority)

    Enum.each([:trace, :inspection, :output, :result_reservation], fn key ->
      state = Map.get(report.artifact_state, Atom.to_string(public_key(key)))

      if state in ["not_written", "failed"] do
        case Map.get(handles, key) do
          %PublicationHandle{} = handle ->
            _ = PublicationHandle.remove(handle)

          _missing ->
            :ok
        end
      end
    end)
  end

  defp public_key(:output), do: :result
  defp public_key(key), do: key
end
