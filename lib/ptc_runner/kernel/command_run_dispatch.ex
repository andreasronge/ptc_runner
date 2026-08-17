defmodule PtcRunner.Kernel.CommandRunDispatch do
  @moduledoc false

  alias PtcRunner.Kernel.CommandDestination
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRunOutcome
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.OwnerFailure
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator

  @spec dispatch(CommandPreparation.t(), CommandRuntime.t()) ::
          {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def dispatch(%CommandPreparation{} = preparation, %CommandRuntime{} = runtime) do
    case dispatch_after_preflight(CommandDestination.preflight(preparation), preparation, runtime) do
      {status, outcome, _rejection} -> {status, outcome}
    end
  end

  @doc false
  @spec dispatch_frontend(
          CommandPreparation.t(),
          CommandRuntime.t(),
          :standalone | :mix
        ) ::
          {:ok, CommandOutcome.t(), nil}
          | {:error, CommandOutcome.t(), PtcRunner.Kernel.CommandRejection.t() | nil}
  def dispatch_frontend(
        %CommandPreparation{} = preparation,
        %CommandRuntime{} = runtime,
        frontend
      )
      when frontend in [:standalone, :mix] do
    preparation
    |> CommandDestination.preflight_frontend(frontend)
    |> dispatch_after_preflight(preparation, runtime)
  end

  defp dispatch_after_preflight({:ok, authority}, preparation, runtime),
    do: with_rejection(execute_preflighted(preparation, runtime, authority))

  defp dispatch_after_preflight({:ok, authority, nil}, preparation, runtime),
    do: with_rejection(execute_preflighted(preparation, runtime, authority))

  defp dispatch_after_preflight({:error, %CommandOutcome{} = outcome}, _preparation, _runtime),
    do: {:error, outcome, nil}

  defp dispatch_after_preflight(
         {:error, %CommandOutcome{} = outcome, rejection},
         _preparation,
         _runtime
       ),
       do: {:error, outcome, rejection}

  defp with_rejection({status, %CommandOutcome{} = outcome}) when status in [:ok, :error],
    do: {status, outcome, nil}

  defp execute_preflighted(preparation, runtime, authority) do
    with :ok <- maybe_setup_environment(preparation, runtime),
         {:ok, execution} <- provider_execution(preparation, runtime) do
      execute_started(preparation, runtime, authority, execution)
    else
      {:error, reason} ->
        operation_failure(
          preparation,
          reason,
          authority_artifact_state(authority),
          false,
          :not_started
        )
    end
  rescue
    _exception ->
      operation_failure(
        preparation,
        :internal_error,
        authority_artifact_state(authority),
        provider_bearing?(preparation),
        :not_started
      )
  catch
    _kind, _reason ->
      operation_failure(
        preparation,
        :internal_error,
        authority_artifact_state(authority),
        provider_bearing?(preparation),
        :not_started
      )
  after
    PublicationAuthority.close(authority)
    CommandPreparation.close(preparation)
  end

  defp execute_started(preparation, runtime, authority, execution) do
    case execute_run(preparation, authority, execution, runtime) do
      {:ok, outcome} ->
        CommandRunOutcome.settle(
          outcome,
          authority,
          preparation.run_ref,
          result_class(preparation),
          authority_artifact_state(authority),
          provider_bearing?(preparation)
        )

      {:error, %CommandOutcome{} = outcome} ->
        {:error, outcome}

      {:error, %CommandDiagnostic{provider_activity: provider_activity} = diagnostic} ->
        operation_failure(
          preparation,
          diagnostic,
          authority_artifact_state(authority),
          provider_activity,
          if(provider_activity, do: :incomplete, else: :not_started)
        )

      {:error, %OwnerFailure{} = failure} ->
        {reason, provider_activity, execution_state} =
          OwnerFailure.evidence_or_unknown(failure, :internal_error, :incomplete)

        operation_failure(
          preparation,
          reason,
          authority_artifact_state(authority),
          provider_activity,
          execution_state
        )

      {:error, reason} ->
        operation_failure(
          preparation,
          reason,
          authority_artifact_state(authority),
          false,
          :not_started
        )
    end
  rescue
    _exception -> post_execution_internal_failure(preparation, authority)
  catch
    _kind, _reason -> post_execution_internal_failure(preparation, authority)
  end

  defp post_execution_internal_failure(preparation, authority),
    do:
      operation_failure(
        preparation,
        :internal_error,
        authority_artifact_state(authority),
        provider_bearing?(preparation),
        :incomplete
      )

  defp maybe_setup_environment(%{environment_setup_required: true}, runtime),
    do: CommandRuntime.setup_environment_diagnostic(runtime)

  defp maybe_setup_environment(_preparation, _runtime), do: :ok

  defp provider_execution(preparation, runtime) do
    case authorization_rejection(preparation, runtime.authorization_targets) do
      nil -> requested_execution(preparation, runtime)
      diagnostic -> {:error, diagnostic}
    end
  end

  # `ProviderExecution.new/3` answers one reason for every unusable execution,
  # which leaves an argument mistake indistinguishable from a broken catalog.
  # The two mistakes an operator actually makes with `--authorize-mcp` are
  # decided here, against the same selection the execution would be bound to.
  defp authorization_rejection(_preparation, []), do: nil

  defp authorization_rejection(%CommandPreparation{} = preparation, targets) do
    selected = MapSet.new(preparation.prepared_run.provider_declarations, & &1.name)
    descriptors = preparation.catalog.descriptors

    Enum.find_value(targets, fn name ->
      cond do
        not MapSet.member?(selected, name) ->
          authorization_diagnostic(:authorization_target_unknown, name)

        not match?(%{authorization_mode: :oauth}, descriptors[name]) ->
          authorization_diagnostic(:authorization_not_applicable, name)

        true ->
          nil
      end
    end)
  end

  # The subject names the alias the operator typed, which is the whole value of
  # classifying this at all. The parser already admits only alias-shaped names,
  # so a name the subject grammar refuses cannot be reached from the CLI; it
  # declines to reject rather than build a diagnostic it cannot name.
  defp authorization_diagnostic(code, name) do
    case CommandSubject.provider(name, :local) do
      {:ok, subject} ->
        CommandDiagnostic.new!(:local_preflight, code, subject: subject, provider_activity: false)

      {:error, _reason} ->
        nil
    end
  end

  defp requested_execution(
         %CommandPreparation{prepared_run: %{provider_declarations: []}},
         %CommandRuntime{authorization_targets: []}
       ),
       do: {:ok, nil}

  defp requested_execution(
         %CommandPreparation{prepared_run: %{provider_declarations: []}},
         _runtime
       ),
       do: {:error, :invalid_provider_execution}

  defp requested_execution(preparation, runtime),
    do:
      ProviderExecution.new(
        preparation.catalog,
        preparation.runtime_services,
        runtime.authorization_targets
      )

  defp execute_run(preparation, authority, nil, runtime),
    do: RunCoordinator.execute(preparation.prepared_run, authority, runtime.live_status)

  defp execute_run(preparation, authority, execution, runtime),
    do:
      RunCoordinator.execute(
        preparation.prepared_run,
        authority,
        execution,
        runtime.authorization_notifier,
        runtime.live_status
      )

  defp operation_failure(
         preparation,
         reason,
         artifact_state,
         provider_activity,
         execution_state
       ) do
    CommandRunOutcome.operation_failure(
      preparation.run_ref,
      reason,
      result_class(preparation),
      artifact_state,
      provider_activity,
      execution_state
    )
  end

  defp result_class(preparation),
    do:
      if(preparation.prepared_run.effective_event_policy == :private, do: :private, else: :normal)

  defp authority_artifact_state(authority) do
    authority
    |> PublicationAuthority.destination_options()
    |> Map.new()
    |> CommandDestination.requested_artifact_state()
  rescue
    _exception -> CommandDestination.requested_artifact_state(%{})
  end

  defp provider_bearing?(preparation),
    do: preparation.prepared_run.provider_declarations != []
end
