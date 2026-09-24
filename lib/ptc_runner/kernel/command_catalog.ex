defmodule PtcRunner.Kernel.CommandCatalog do
  @moduledoc false

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRegistry

  @digest String.duplicate("0", 64)

  def dispatch(%CommandArguments{application: provider, options: options}, run_ref) do
    case CommandAcquisition.catalog(options.host_config) do
      {:ok, host, catalog} ->
        try do
          build(host, catalog, provider, run_ref)
        after
          InstallationCatalog.close(catalog)
        end

      {:error, diagnostic} ->
        {:error, CommandOutcome.error(:catalog, run_ref, diagnostic)}
    end
  end

  defp build(host, catalog, provider, run_ref) do
    with {:ok, services} <- HostInstallation.runtime_services(host),
         {:ok, execution} <- ProviderExecution.new(catalog, services, []) do
      ProviderExecution.with_selected_registry(
        execution,
        provider,
        Deadline.new(5_000),
        fn registry ->
          context = %{
            application_content_digest: @digest,
            destination: :workflow,
            owner: self(),
            limits: host.limits,
            installed_limits: host.limits
          }

          with {:ok, built} <-
                 ProviderRegistry.build(registry, provider, %{"catalog" => true}, context),
               result <- catalog_result(built, provider, run_ref) do
            result
          else
            _reason -> error(run_ref, provider, :provider_unavailable)
          end
        end
      )
    else
      _error -> error(run_ref, provider, :provider_unavailable)
    end
  end

  defp catalog_result(built, provider, run_ref) do
    result =
      with [capability] <- built.capabilities,
           {:ok, catalog} <- capability.callback.(%{}, nil),
           do: {:ok, CommandOutcome.success(:catalog, run_ref, catalog)}

    finish_catalog(result, close(built), provider, run_ref)
  rescue
    _exception ->
      close(built)
      error(run_ref, provider, :provider_unavailable)
  catch
    _kind, _reason ->
      close(built)
      error(run_ref, provider, :provider_unavailable)
  end

  defp finish_catalog(_result, close_result, provider, run_ref) when close_result != :ok,
    do: error(run_ref, provider, :result_cleanup, :provider_cleanup_failed)

  defp finish_catalog({:ok, _outcome} = result, :ok, _provider, _run_ref), do: result

  defp finish_catalog(_result, :ok, provider, run_ref),
    do: error(run_ref, provider, :provider_unavailable)

  defp close(%{close: close}) when is_function(close, 0) do
    close.()
  rescue
    _exception -> {:error, :provider_cleanup_error}
  catch
    _kind, _reason -> {:error, :provider_cleanup_error}
  end

  defp close(_built), do: :ok

  defp error(run_ref, provider, code) do
    error(run_ref, provider, :provider_acquisition, code)
  end

  defp error(run_ref, provider, :provider_acquisition = phase, code) do
    {:ok, subject} =
      CommandSubject.provider(provider, :acquisition, %{destination: :workflow, index: 0})

    diagnostic =
      CommandDiagnostic.new!(phase, code, subject: subject, provider_activity: true)

    {:error, CommandOutcome.error(:catalog, run_ref, diagnostic)}
  end

  defp error(run_ref, provider, :result_cleanup = phase, code) do
    {:ok, subject} = CommandSubject.provider(provider, :cleanup)

    diagnostic =
      CommandDiagnostic.new!(phase, code, subject: subject, provider_activity: true)

    {:error, CommandOutcome.error(:catalog, run_ref, diagnostic)}
  end
end
