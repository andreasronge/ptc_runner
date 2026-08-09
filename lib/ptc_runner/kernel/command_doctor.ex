defmodule PtcRunner.Kernel.CommandDoctor do
  @moduledoc false

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.DoctorEnvironment
  alias PtcRunner.Kernel.DoctorPlan
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator

  @spec dispatch(CommandArguments.t(), binary(), CommandRuntime.t()) ::
          {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def dispatch(
        %CommandArguments{options: options} = arguments,
        run_ref,
        %CommandRuntime{} = runtime
      ) do
    case CommandAcquisition.with_catalog(Map.get(options, :host_config), fn host, catalog ->
           mode_outcome(arguments, run_ref, host, catalog, runtime)
         end) do
      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}

      result ->
        result
    end
  end

  defp mode_outcome(
         %CommandArguments{options: %{connect: true}} = arguments,
         run_ref,
         host,
         catalog,
         runtime
       ),
       do: connect_outcome(arguments, run_ref, host, catalog, runtime)

  defp mode_outcome(arguments, run_ref, host, catalog, runtime),
    do: local_outcome(arguments, run_ref, host, catalog, runtime)

  defp local_outcome(arguments, run_ref, host, catalog, runtime) do
    case preparation(arguments, catalog, run_ref) do
      {:ok, prepared} ->
        result = local_checks(host, catalog, prepared, runtime)
        if prepared, do: PreparedRun.close(prepared)

        case result do
          {:ok, checks} ->
            {:ok,
             CommandOutcome.success(:doctor, run_ref, %{
               "checks" => checks,
               "provider_activity" => false
             })}

          {:error, diagnostic} ->
            {:error, arguments_outcome(arguments, run_ref, diagnostic)}
        end

      {:error, diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}
    end
  end

  defp preparation(%CommandArguments{application: nil}, _catalog, _run_ref), do: {:ok, nil}

  defp preparation(arguments, catalog, run_ref),
    do: CommandAcquisition.prepare_request(arguments, catalog, run_ref)

  defp local_checks(host, catalog, prepared, runtime) do
    with {:ok, rows} <- DoctorPlan.new(catalog, prepared, DoctorEnvironment.facts(), :default),
         {:ok, services} <- runtime_services(host, runtime),
         :ok <- RunCoordinator.local_checks(prepared, catalog, services),
         {:ok, settled} <- DoctorPlan.settle_pending(rows),
         {:ok, checks} <- DoctorPlan.checks(settled) do
      {:ok, checks}
    else
      {:error, %CommandDiagnostic{} = diagnostic} -> {:error, diagnostic}
      {:error, _reason} -> {:error, diagnostic(:internal, :internal_error)}
    end
  end

  defp runtime_services(nil, runtime),
    do: ProviderRuntimeServices.new(provider_application_mode: runtime.provider_application_mode)

  defp runtime_services(host, runtime),
    do:
      HostInstallation.runtime_services(host,
        provider_application_mode: runtime.provider_application_mode
      )

  defp connect_outcome(arguments, run_ref, host, catalog, runtime) do
    case preparation(arguments, catalog, run_ref) do
      {:ok, prepared} ->
        try do
          connect_prepared(arguments, run_ref, host, catalog, prepared, runtime)
        after
          PreparedRun.close(prepared)
        end

      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}
    end
  end

  defp connect_prepared(arguments, run_ref, host, catalog, prepared, runtime) do
    case connect_checks(host, catalog, prepared, run_ref, runtime) do
      {:ok, checks, provider_activity} ->
        connect_success(arguments, run_ref, checks, provider_activity)

      {:error, diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}
    end
  end

  defp connect_success(arguments, run_ref, checks, provider_activity) do
    {:ok,
     CommandOutcome.success({:doctor, :connect}, run_ref, %{
       "checks" => checks,
       "provider_activity" => provider_activity
     })}
  rescue
    _exception -> connect_interrupted(arguments, run_ref, provider_activity)
  catch
    _kind, _reason -> connect_interrupted(arguments, run_ref, provider_activity)
  end

  defp connect_interrupted(arguments, run_ref, provider_activity),
    do: {:error, arguments_outcome(arguments, run_ref, projection_diagnostic(provider_activity))}

  defp connect_checks(host, catalog, prepared, run_ref, runtime) do
    case DoctorPlan.new(catalog, prepared, DoctorEnvironment.facts(), :connect) do
      {:ok, rows} -> connect_operation(host, catalog, prepared, rows, run_ref, runtime)
      {:error, _reason} -> {:error, diagnostic(:internal, :internal_error)}
    end
  end

  defp connect_operation(
         _host,
         _catalog,
         %PreparedRun{provider_declarations: []},
         rows,
         _run_ref,
         _runtime
       ),
       do: connect_projection(rows, false)

  defp connect_operation(host, catalog, prepared, rows, run_ref, runtime) do
    with {:ok, services} <- runtime_services(host, runtime),
         {:ok, execution} <- ProviderExecution.new(catalog, services, []),
         {:ok, authority} <-
           PublicationAuthority.authorize(
             run_ref,
             [],
             prepared.effective_event_policy,
             prepared.effective_data_class
           ) do
      connect_settlement(rows, prepared, catalog, execution, authority)
    else
      {:error, _reason} -> {:error, diagnostic(:internal, :internal_error)}
    end
  end

  defp connect_settlement(rows, prepared, catalog, execution, authority) do
    case RunCoordinator.connect(prepared, authority, execution) do
      {:ok, result} ->
        case DoctorPlan.settle_connect(rows, result, prepared, catalog) do
          {:ok, settled} -> connect_projection(settled, true)
          {:error, _reason} -> {:error, active_diagnostic(:internal, :internal_error)}
        end

      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, diagnostic}

      {:error, reason} ->
        {:error, operation_diagnostic(reason)}
    end
  rescue
    _exception -> {:error, active_diagnostic(:internal, :internal_error)}
  catch
    _kind, _reason -> {:error, active_diagnostic(:internal, :internal_error)}
  after
    PublicationAuthority.close(authority)
  end

  defp operation_diagnostic(:execution_session_unavailable),
    do: active_diagnostic(:internal, :internal_error)

  defp operation_diagnostic(_reason), do: diagnostic(:internal, :internal_error)

  defp connect_projection(rows, provider_activity) do
    case DoctorPlan.checks(rows) do
      {:ok, checks} -> {:ok, checks, provider_activity}
      {:error, _reason} -> {:error, projection_diagnostic(provider_activity)}
    end
  end

  defp projection_diagnostic(false), do: diagnostic(:internal, :internal_error)
  defp projection_diagnostic(true), do: active_diagnostic(:internal, :internal_error)

  defp arguments_outcome(%CommandArguments{options: %{connect: true}}, run_ref, diagnostic),
    do: CommandOutcome.error({:doctor, :connect}, run_ref, diagnostic)

  defp arguments_outcome(%CommandArguments{}, run_ref, diagnostic),
    do: CommandOutcome.error(:doctor, run_ref, diagnostic)

  defp diagnostic(phase, code), do: CommandDiagnostic.new!(phase, code)

  defp active_diagnostic(phase, code),
    do: CommandDiagnostic.new!(phase, code, provider_activity: true)
end
