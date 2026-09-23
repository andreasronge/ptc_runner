defmodule PtcRunner.Kernel.CommandCatalog do
  @moduledoc false

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
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
    case HostInstallation.runtime_registry(host, catalog) do
      {:ok, registry} ->
        try do
          context = %{
            application_content_digest: @digest,
            destination: :workflow,
            owner: self(),
            limits: host.limits,
            installed_limits: host.limits
          }

          with {:ok, built} <-
                 ProviderRegistry.build(registry, provider, %{"catalog" => true}, context),
               result <- catalog_result(built, run_ref) do
            result
          else
            _reason -> error(run_ref, :provider_unavailable)
          end
        after
          ProviderRegistry.close(registry)
        end

      _error ->
        error(run_ref, :provider_unavailable)
    end
  end

  defp catalog_result(built, run_ref) do
    result =
      with [capability] <- built.capabilities,
           {:ok, catalog} <- capability.callback.(%{}, nil),
           do: {:ok, CommandOutcome.success(:catalog, run_ref, catalog)}

    close_result = if built.close, do: built.close.(), else: :ok

    cond do
      close_result != :ok -> error(run_ref, :result_cleanup, :provider_cleanup_error)
      match?({:ok, _outcome}, result) -> result
      true -> error(run_ref, :provider_unavailable)
    end
  end

  defp error(run_ref, code) do
    error(run_ref, :provider_acquisition, code)
  end

  defp error(run_ref, phase, code) do
    diagnostic = CommandDiagnostic.new!(phase, code)
    {:error, CommandOutcome.error(:catalog, run_ref, diagnostic)}
  end
end
