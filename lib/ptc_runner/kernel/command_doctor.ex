defmodule PtcRunner.Kernel.CommandDoctor do
  @moduledoc false

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.DoctorEnvironment
  alias PtcRunner.Kernel.DoctorPlan
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.LLMUsageSummary
  alias PtcRunner.Kernel.ModelSelectorDisclosure
  alias PtcRunner.Kernel.OwnerFailure
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
        try do
          case local_checks(host, catalog, prepared, runtime) do
            {:ok, checks} ->
              doctor_success(:doctor, arguments, run_ref, host, catalog, prepared, %{
                checks: checks,
                provider_activity: false,
                usage: inert_usage()
              })

            {:finding, checks, %CommandDiagnostic{} = diagnostic} ->
              doctor_failure(
                :doctor,
                arguments,
                run_ref,
                host,
                catalog,
                prepared,
                checks,
                {diagnostic, []}
              )

            {:error, diagnostic} ->
              {:error, arguments_outcome(arguments, run_ref, diagnostic)}
          end
        after
          if prepared, do: PreparedRun.close(prepared)
        end

      {:error, %CommandDiagnostic{phase: :application} = diagnostic} ->
        application_failure(:doctor, arguments, run_ref, host, catalog, diagnostic)

      {:error, diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}
    end
  end

  defp preparation(%CommandArguments{application: nil}, _catalog, _run_ref), do: {:ok, nil}

  defp preparation(arguments, catalog, run_ref),
    do: CommandAcquisition.prepare_request(arguments, catalog, run_ref)

  defp local_checks(host, catalog, prepared, runtime) do
    environment = DoctorEnvironment.facts()

    with {:ok, rows} <- DoctorPlan.new(catalog, prepared, environment, :default),
         {:ok, services} <- runtime_services(host, runtime),
         {:ok, findings} <- RunCoordinator.local_check_findings(prepared, catalog, services),
         {:ok, settled} <-
           DoctorPlan.settle_local(rows, findings, prepared, catalog, environment),
         {:ok, checks} <- DoctorPlan.checks(settled) do
      case findings do
        [] -> {:ok, checks}
        [primary | _rest] -> {:finding, checks, primary}
      end
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

      {:error, %CommandDiagnostic{phase: :application} = diagnostic} ->
        application_failure({:doctor, :connect}, arguments, run_ref, host, catalog, diagnostic)

      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}
    end
  end

  defp connect_prepared(arguments, run_ref, host, catalog, prepared, runtime) do
    with :ok <- maybe_setup_environment(host, prepared, runtime),
         {:ok, report} <- connect_checks(host, catalog, prepared, run_ref, runtime) do
      doctor_success({:doctor, :connect}, arguments, run_ref, host, catalog, prepared, report)
    else
      {:finding, checks, %CommandDiagnostic{} = diagnostic, secondary} ->
        doctor_failure(
          {:doctor, :connect},
          arguments,
          run_ref,
          host,
          catalog,
          prepared,
          checks,
          {diagnostic, secondary}
        )

      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}

      {:error, _reason} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic(:internal, :internal_error))}
    end
  end

  defp maybe_setup_environment(host, prepared, runtime) do
    if CommandAcquisition.environment_setup_required?(host, prepared),
      do: CommandRuntime.setup_environment_diagnostic(runtime),
      else: :ok
  end

  # One projection: what the checks found, whether a provider was activated, and
  # what that activity spent. They are produced together and travel together.
  defp doctor_success(mode, arguments, run_ref, host, catalog, prepared, report) do
    %{checks: checks, provider_activity: provider_activity, usage: usage} = report

    with {:ok, aliases} <- DoctorPlan.model_aliases(catalog, prepared) do
      aliases = maybe_add_model_selectors(aliases, host, arguments.options)

      {:ok,
       CommandOutcome.success(mode, run_ref, %{
         "checks" => checks,
         "model_aliases" => aliases,
         "provider_activity" => provider_activity,
         "readiness" => readiness(mode),
         "usage" => usage
       })}
    end
  rescue
    _exception -> connect_interrupted(arguments, run_ref, report.provider_activity)
  catch
    _kind, _reason -> connect_interrupted(arguments, run_ref, report.provider_activity)
  end

  defp doctor_failure(
         mode,
         arguments,
         run_ref,
         host,
         catalog,
         prepared,
         checks,
         {diagnostic, secondary}
       ) do
    provider_activity =
      Enum.any?([diagnostic | secondary], & &1.provider_activity)

    with {:ok, aliases} <- DoctorPlan.model_aliases(catalog, prepared) do
      aliases = maybe_add_model_selectors(aliases, host, arguments.options)

      result = %{
        "checks" => checks,
        "model_aliases" => aliases,
        "provider_activity" => provider_activity,
        "readiness" => "failed",
        "usage" => failure_usage(provider_activity)
      }

      {:error,
       CommandOutcome.doctor_failure(
         mode,
         run_ref,
         result,
         diagnostic,
         secondary
       )}
    end
  rescue
    _exception ->
      connect_interrupted(arguments, run_ref, diagnostic_activity(diagnostic, secondary))
  catch
    _kind, _reason ->
      connect_interrupted(arguments, run_ref, diagnostic_activity(diagnostic, secondary))
  end

  defp application_failure(mode, arguments, run_ref, host, catalog, diagnostic) do
    environment = DoctorEnvironment.facts()

    with {:ok, rows} <-
           DoctorPlan.application_failure(catalog, diagnostic, environment, plan_mode(mode)),
         {:ok, checks} <- DoctorPlan.checks(rows),
         {:ok, aliases} <- DoctorPlan.model_aliases(catalog, nil) do
      result = %{
        "checks" => checks,
        "model_aliases" => maybe_add_model_selectors(aliases, host, arguments.options),
        "provider_activity" => false,
        "readiness" => "failed",
        "usage" => inert_usage()
      }

      {:error, CommandOutcome.doctor_failure(mode, run_ref, result, diagnostic)}
    else
      {:error, _reason} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic(:internal, :internal_error))}
    end
  rescue
    _exception ->
      {:error, arguments_outcome(arguments, run_ref, diagnostic(:internal, :internal_error))}
  catch
    _kind, _reason ->
      {:error, arguments_outcome(arguments, run_ref, diagnostic(:internal, :internal_error))}
  end

  defp plan_mode(:doctor), do: :default
  defp plan_mode({:doctor, :connect}), do: :connect

  defp readiness(:doctor), do: "unverified"
  defp readiness({:doctor, :connect}), do: "ready"

  defp diagnostic_activity(diagnostic, secondary),
    do: Enum.any?([diagnostic | secondary], & &1.provider_activity)

  defp maybe_add_model_selectors(aliases, host, %{show_model_selectors: true}),
    do: ModelSelectorDisclosure.annotate(aliases, host)

  defp maybe_add_model_selectors(aliases, _host, _options), do: aliases

  defp connect_interrupted(arguments, run_ref, provider_activity),
    do: {:error, arguments_outcome(arguments, run_ref, projection_diagnostic(provider_activity))}

  defp connect_checks(host, catalog, prepared, run_ref, runtime) do
    environment = DoctorEnvironment.facts()

    case DoctorPlan.new(catalog, prepared, environment, :connect) do
      {:ok, rows} ->
        connect_operation(host, catalog, prepared, rows, environment, run_ref, runtime)

      {:error, _reason} ->
        {:error, diagnostic(:internal, :internal_error)}
    end
  end

  defp connect_operation(
         _host,
         _catalog,
         %PreparedRun{provider_declarations: []},
         rows,
         _environment,
         _run_ref,
         _runtime
       ),
       do: connect_projection(rows, false, inert_usage())

  defp connect_operation(host, catalog, prepared, rows, environment, run_ref, runtime) do
    with {:ok, services} <- runtime_services(host, runtime),
         {:ok, execution} <- ProviderExecution.new(catalog, services, []),
         {:ok, authority} <-
           PublicationAuthority.authorize(
             run_ref,
             [],
             prepared.effective_event_policy,
             prepared.effective_data_class
           ) do
      connect_settlement(rows, prepared, catalog, environment, execution, authority)
    else
      {:error, _reason} -> {:error, diagnostic(:internal, :internal_error)}
    end
  end

  defp connect_settlement(rows, prepared, catalog, environment, execution, authority) do
    case RunCoordinator.connect(prepared, authority, execution) do
      {:ok, result} ->
        case DoctorPlan.settle_connect(rows, result, prepared, catalog) do
          {:ok, settled} ->
            connect_projection(
              settled,
              ConnectivityResult.provider_activity(result),
              probe_usage(ConnectivityResult.usage(result), catalog)
            )

          {:error, _reason} ->
            {:error, active_diagnostic(:internal, :internal_error)}
        end

      {:error, %CommandDiagnostic{} = diagnostic} ->
        connect_failure_projection(rows, diagnostic, prepared, catalog, environment)

      {:error, %OwnerFailure{} = failure} ->
        {:error, connect_failure_diagnostic(failure)}

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

  defp connect_failure_projection(rows, diagnostic, prepared, catalog, environment) do
    with {:ok, settled} <-
           DoctorPlan.settle_failure(rows, diagnostic, prepared, catalog, environment),
         {:ok, checks} <- DoctorPlan.checks(settled) do
      {:finding, checks, diagnostic, []}
    else
      {:error, _reason} -> {:error, diagnostic}
    end
  end

  defp operation_diagnostic(:execution_session_unavailable),
    do: active_diagnostic(:internal, :internal_error)

  defp operation_diagnostic(_reason), do: diagnostic(:internal, :internal_error)

  @doc false
  @spec connect_failure_diagnostic(term()) :: CommandDiagnostic.t()
  def connect_failure_diagnostic(failure) do
    {_reason, provider_activity, _stage} =
      OwnerFailure.evidence_or_unknown(failure, :internal_error, :incomplete)

    if provider_activity,
      do: active_diagnostic(:internal, :internal_error),
      else: diagnostic(:internal, :internal_error)
  end

  defp connect_projection(rows, provider_activity, usage) do
    case DoctorPlan.checks(rows) do
      {:ok, checks} ->
        {:ok, %{checks: checks, provider_activity: provider_activity, usage: usage}}

      {:error, _reason} ->
        {:error, projection_diagnostic(provider_activity)}
    end
  end

  # What the probes spent, attributed by alias on the row shape a run reports.
  # An account the report cannot name is not published with a hole in it: the
  # whole thing is reported as unavailable instead.
  defp probe_usage(entries, catalog) do
    entries
    |> Enum.reduce_while([], fn entry, calls ->
      case attribution(Map.get(catalog.descriptors, entry.name), entry) do
        {:ok, call} -> {:cont, [call | calls]}
        :nothing_spent -> {:cont, calls}
        :unattributable -> {:halt, :unattributable}
      end
    end)
    |> case do
      :unattributable -> unattributed_usage()
      calls -> attributed_usage(calls |> Enum.reverse() |> LLMUsageSummary.alias_rows())
    end
  end

  # Only a workflow model alias appears in `model_aliases`, so only such an
  # alias has a row a reader could check the spend against. A probed occurrence
  # that is not one and reported nothing has nothing to account for; one that
  # reported something leaves the account unattributable, as does an occurrence
  # whose descriptor cannot be read at all.
  defp attribution(%{workflow_llm?: true, installation_revision: revision}, entry),
    do: {:ok, {entry.name, revision, entry.usage}}

  defp attribution(%{}, %{usage: nil}), do: :nothing_spent
  defp attribution(_descriptor, _entry), do: :unattributable

  # A command that activated no provider spent nothing, and an empty account is
  # the true one. A failure that did activate one may have been billed for work
  # no result accounts for, so it reports the spend as unavailable rather than
  # as zero.
  defp failure_usage(false), do: inert_usage()
  defp failure_usage(true), do: unattributed_usage()

  defp inert_usage, do: attributed_usage([])

  defp attributed_usage(rows),
    do: %{"llm_usage_state" => "available", "llm_usage" => rows}

  defp unattributed_usage,
    do: %{"llm_usage_state" => "unavailable", "llm_usage" => nil}

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
