defmodule PtcRunner.Kernel.ProviderApplicationGate do
  @moduledoc """
  Admits selected optional provider applications after the active lifecycle
  begins.

  A host-owned application must already be running. A command-owned VM rejects
  an inherited target, disables dotenv loading for both `:req_llm` and
  `:llm_db`, configures ReqLLM's default HTTP/1 Finch pool as one shard sized
  from the installed `live_provider_tasks` ceiling, and starts the selected
  target without stopping it at session close. A manifest-narrowed effective
  limit does not resize that VM-lifetime pool. Explicit ReqLLM Finch pools or a
  non-HTTP/1 protocol configuration retain their dependency-defined precedence.
  The command VM owns
  the resulting application processes until VM shutdown. Multi-template commands
  admit their union once and seal that set into runtime services, so subsequent
  acquisitions reuse only applications this command admitted. Once selected
  applications are admitted, adapter-owned VM-global metadata is warmed before
  the run clock begins, so its one-time load does not consume a bounded provider
  worker's heap.

  OTP application startup is deliberately synchronous here:
  `Application.ensure_all_started/1` is not cancellable and offers no timeout.
  A stuck application callback can therefore require terminating the command
  VM. This gate does not wrap startup in a worker and claim a false bound.

  Availability rejections that contact nothing report no provider activity.
  Once a command-owned VM attempts OTP application startup, a startup failure
  reports activity even when the target application never reaches the running
  set.
  """

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionReplTarget
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ServingTemplate

  @spec admit(PreparedRun.t(), InstallationCatalog.t(), ProviderRuntimeServices.t()) ::
          :ok | {:error, CommandDiagnostic.t()}
  def admit(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %ProviderRuntimeServices{} = services
      ) do
    with true <- PreparedRun.active_valid?(prepared),
         true <- InstallationCatalog.valid?(catalog),
         true <- prepared.catalog_attestation == catalog.attestation,
         true <- ProviderRuntimeServices.bound_to?(services, catalog.runtime_binding) do
      requirements = requirements(prepared.provider_declarations, catalog)

      case admit_requirements(
             requirements,
             application_mode(services, requirements),
             catalog.installed_limits
           ) do
        :ok -> warm_requirements(requirements)
        {:error, name, activity} -> {:error, unavailable_diagnostic(name, activity)}
      end
    else
      _invalid -> {:error, internal_diagnostic()}
    end
  rescue
    _exception -> {:error, internal_diagnostic()}
  catch
    _kind, _reason -> {:error, internal_diagnostic()}
  end

  def admit(_prepared, _catalog, _services), do: {:error, internal_diagnostic()}

  @doc false
  @spec admit(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          MissionReplTarget.t()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def admit(prepared, catalog, services, %MissionReplTarget{} = target) do
    with true <- PreparedRun.active_valid?(prepared),
         true <- MissionReplTarget.valid_for?(target, prepared, catalog),
         true <- ProviderRuntimeServices.bound_to?(services, catalog.runtime_binding) do
      requirements = requirements(target.declarations, catalog)

      case admit_requirements(
             requirements,
             application_mode(services, requirements),
             catalog.installed_limits
           ) do
        :ok -> warm_requirements(requirements)
        {:error, name, activity} -> {:error, unavailable_diagnostic(name, activity)}
      end
    else
      _invalid -> {:error, internal_diagnostic()}
    end
  rescue
    _exception -> {:error, internal_diagnostic()}
  catch
    _kind, _reason -> {:error, internal_diagnostic()}
  end

  @doc false
  @spec startup_attempted_after_admission?(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t()
        ) :: boolean()
  def startup_attempted_after_admission?(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %ProviderRuntimeServices{provider_application_mode: :command_vm}
      ) do
    PreparedRun.active_valid?(prepared) and InstallationCatalog.valid?(catalog) and
      prepared.catalog_attestation == catalog.attestation and
      requirements(prepared.provider_declarations, catalog) != []
  end

  def startup_attempted_after_admission?(_prepared, _catalog, _services), do: false

  @doc false
  def startup_attempted_after_admission?(
        prepared,
        catalog,
        %ProviderRuntimeServices{provider_application_mode: :command_vm},
        %MissionReplTarget{} = target
      ) do
    PreparedRun.active_valid?(prepared) and
      MissionReplTarget.valid_for?(target, prepared, catalog) and
      requirements(target.declarations, catalog) != []
  end

  def startup_attempted_after_admission?(_prepared, _catalog, _services, _target), do: false

  @doc false
  @spec requirements(list(), InstallationCatalog.t()) :: [{binary(), atom()}]
  def requirements(declarations, catalog) do
    declarations
    |> Enum.reduce([], fn declaration, requirements ->
      implementation = Map.fetch!(catalog.implementations, declaration.name)

      case Map.get(implementation, :provider_application) do
        nil -> requirements
        application -> [{declaration.name, application} | requirements]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(&elem(&1, 1))
  end

  @doc "Admits the union of a command's templates once, retaining command-VM ownership."
  @spec admit_command_templates(
          [ServingTemplate.t()],
          InstallationCatalog.t(),
          ProviderRuntimeServices.t()
        ) ::
          {:ok, ProviderRuntimeServices.t()} | {:error, atom()}
  def admit_command_templates(
        templates,
        catalog,
        %ProviderRuntimeServices{provider_application_mode: :command_vm} = services
      ) do
    if InstallationCatalog.valid?(catalog) and
         ProviderRuntimeServices.bound_to?(services, catalog.runtime_binding) do
      selected =
        templates
        |> Enum.flat_map(fn template ->
          case ServingTemplate.provider_plan(template) do
            {:ok, plan} -> requirements(plan.metadata.provider_declarations, plan.catalog)
            {:error, _} -> []
          end
        end)
        |> Enum.uniq_by(&elem(&1, 1))

      with :ok <- admit_requirements(selected, :command_vm, catalog.installed_limits),
           :ok <- warm_requirements(selected) do
        ProviderRuntimeServices.with_command_applications(
          services,
          Enum.map(selected, &elem(&1, 1))
        )
      else
        _ -> {:error, :provider_application_unavailable}
      end
    else
      {:error, :invalid_provider_runtime_services}
    end
  rescue
    _ -> {:error, :internal_error}
  catch
    _, _ -> {:error, :internal_error}
  end

  defp application_mode(
         %ProviderRuntimeServices{
           provider_application_mode: :command_vm,
           command_applications: applications
         },
         requirements
       ) do
    if Enum.all?(requirements, fn {_, app} -> app in applications end),
      do: :host_owned,
      else: :command_vm
  end

  defp application_mode(services, _requirements), do: services.provider_application_mode

  defp admit_requirements([], _mode, _installed_limits), do: :ok

  defp admit_requirements(requirements, :host_owned, _installed_limits) do
    running = Application.started_applications() |> MapSet.new(&elem(&1, 0))

    case Enum.find(requirements, fn {_name, application} ->
           not MapSet.member?(running, application)
         end) do
      nil -> :ok
      {name, _application} -> {:error, name, false}
    end
  end

  defp admit_requirements(requirements, :command_vm, installed_limits) do
    running = Application.started_applications() |> MapSet.new(&elem(&1, 0))

    case Enum.find(requirements, fn {_name, application} ->
           MapSet.member?(running, application)
         end) do
      {name, _application} ->
        {:error, name, false}

      nil ->
        :ok = configure_command_vm_req_llm(installed_limits)
        start_requirements(requirements)
    end
  end

  @doc false
  @spec configure_command_vm_req_llm(Limits.t()) :: :ok
  def configure_command_vm_req_llm(%Limits{live_provider_tasks: pool_size} = installed_limits) do
    if Limits.valid?(installed_limits) do
      Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
      Application.put_env(:llm_db, :load_dotenv, false, persistent: true)

      if command_owned_default_http1_pool?() do
        Application.put_env(:req_llm, :stream_pool_count, 1, persistent: true)
        Application.put_env(:req_llm, :stream_pool_size, pool_size, persistent: true)
      end

      :ok
    else
      raise ArgumentError, "invalid installed limits for command-owned ReqLLM configuration"
    end
  end

  def configure_command_vm_req_llm(_installed_limits) do
    raise ArgumentError, "invalid installed limits for command-owned ReqLLM configuration"
  end

  defp command_owned_default_http1_pool? do
    protocols = Application.get_env(:req_llm, :stream_pool_protocols, [:http1])
    finch = Application.get_env(:req_llm, :finch, [])

    protocols == [:http1] and Keyword.keyword?(finch) and not Keyword.has_key?(finch, :pools)
  end

  defp start_requirements(requirements) do
    Enum.reduce_while(requirements, :ok, fn {name, application}, :ok ->
      case Application.ensure_all_started(application) do
        {:ok, started} ->
          if application in started, do: {:cont, :ok}, else: {:halt, {:error, name, true}}

        {:error, _reason} ->
          {:halt, {:error, name, true}}
      end
    end)
  end

  defp warm_requirements(requirements) do
    if Enum.any?(requirements, &match?({_name, :req_llm}, &1)) do
      adapter = PtcRunner.LLM.adapter!()
      if function_exported?(adapter, :ensure_ready, 0), do: adapter.ensure_ready()
    end

    :ok
  end

  defp unavailable_diagnostic(name, activity) do
    {:ok, subject} = CommandSubject.provider(name, :application)

    CommandDiagnostic.new!(:active_preflight, :provider_application_unavailable,
      subject: subject,
      provider_activity: activity
    )
  end

  defp internal_diagnostic,
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: true)
end
