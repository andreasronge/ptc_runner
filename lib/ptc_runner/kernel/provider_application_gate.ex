defmodule PtcRunner.Kernel.ProviderApplicationGate do
  @moduledoc """
  Admits selected optional provider applications after provider activity begins.

  A host-owned application must already be running. A command-owned VM rejects
  an inherited target, disables dotenv loading for both `:req_llm` and
  `:llm_db`, and starts the selected target without stopping it at session
  close. The command VM owns the resulting application processes until VM
  shutdown. Once selected applications are admitted, adapter-owned VM-global
  metadata is warmed before the run clock begins, so its one-time load does not
  consume a bounded provider worker's heap.

  OTP application startup is deliberately synchronous here:
  `Application.ensure_all_started/1` is not cancellable and offers no timeout.
  A stuck application callback can therefore require terminating the command
  VM. This gate does not wrap startup in a worker and claim a false bound.
  """

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderRuntimeServices

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
      requirements = requirements(prepared, catalog)

      case admit_requirements(requirements, services.provider_application_mode) do
        :ok -> warm_requirements(requirements)
        {:error, name} -> {:error, unavailable_diagnostic(name)}
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

  defp requirements(prepared, catalog) do
    prepared.provider_declarations
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

  defp admit_requirements([], _mode), do: :ok

  defp admit_requirements(requirements, :host_owned) do
    running = Application.started_applications() |> MapSet.new(&elem(&1, 0))

    case Enum.find(requirements, fn {_name, application} ->
           not MapSet.member?(running, application)
         end) do
      nil -> :ok
      {name, _application} -> {:error, name}
    end
  end

  defp admit_requirements(requirements, :command_vm) do
    running = Application.started_applications() |> MapSet.new(&elem(&1, 0))

    case Enum.find(requirements, fn {_name, application} ->
           MapSet.member?(running, application)
         end) do
      {name, _application} ->
        {:error, name}

      nil ->
        Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
        Application.put_env(:llm_db, :load_dotenv, false, persistent: true)
        start_requirements(requirements)
    end
  end

  defp start_requirements(requirements) do
    Enum.reduce_while(requirements, :ok, fn {name, application}, :ok ->
      case Application.ensure_all_started(application) do
        {:ok, started} ->
          if application in started, do: {:cont, :ok}, else: {:halt, {:error, name}}

        {:error, _reason} ->
          {:halt, {:error, name}}
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

  defp unavailable_diagnostic(name) do
    {:ok, subject} = CommandSubject.provider(name, :application)

    CommandDiagnostic.new!(:active_preflight, :provider_application_unavailable,
      subject: subject,
      provider_activity: true
    )
  end

  defp internal_diagnostic,
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: true)
end
