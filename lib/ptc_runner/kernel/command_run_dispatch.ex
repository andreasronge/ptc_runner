defmodule PtcRunner.Kernel.CommandRunDispatch do
  @moduledoc false

  alias PtcRunner.Kernel.CommandDestination
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRunOutcome
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.OwnerFailure
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator

  @spec dispatch(CommandPreparation.t(), CommandRuntime.t()) ::
          {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def dispatch(%CommandPreparation{} = preparation, %CommandRuntime{} = runtime) do
    case CommandDestination.preflight(preparation) do
      {:ok, authority} -> execute_preflighted(preparation, runtime, authority)
      {:error, %CommandOutcome{} = outcome} -> {:error, outcome}
    end
  end

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
        case OwnerFailure.evidence(failure) do
          {:ok, reason, provider_activity, execution_state} ->
            operation_failure(
              preparation,
              reason,
              authority_artifact_state(authority),
              provider_activity,
              execution_state
            )

          {:error, :invalid_owner_failure} ->
            operation_failure(
              preparation,
              :internal_error,
              authority_artifact_state(authority),
              false,
              :not_started
            )
        end

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
    do: CommandRuntime.setup_environment(runtime)

  defp maybe_setup_environment(_preparation, _runtime), do: :ok

  defp provider_execution(
         %CommandPreparation{prepared_run: %{provider_declarations: []}},
         %CommandRuntime{authorization_targets: []}
       ),
       do: {:ok, nil}

  defp provider_execution(
         %CommandPreparation{prepared_run: %{provider_declarations: []}},
         _runtime
       ),
       do: {:error, :invalid_provider_execution}

  defp provider_execution(preparation, runtime),
    do:
      ProviderExecution.new(
        preparation.catalog,
        preparation.runtime_services,
        runtime.authorization_targets
      )

  defp execute_run(preparation, authority, nil, _runtime),
    do: RunCoordinator.execute(preparation.prepared_run, authority)

  defp execute_run(preparation, authority, execution, runtime),
    do:
      RunCoordinator.execute(
        preparation.prepared_run,
        authority,
        execution,
        runtime.authorization_notifier
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
