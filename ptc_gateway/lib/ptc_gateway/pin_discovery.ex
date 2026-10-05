defmodule PtcGateway.PinDiscovery do
  @moduledoc """
  One-shot gateway pin discovery without listener or artifact initialization.

  All templates pass serving validation before the exact environment file is
  loaded once. Only selected provider credentials are resolved. Acquisitions
  run in command-VM mode, in tool-name order, and close before returning any
  output. The caller publishes the complete map only after success.
  """
  alias PtcRunner.Kernel.{
    CapturedCredentials,
    GatewayConfig,
    HostInstallation,
    InstallationCatalog,
    ProviderRuntime,
    ProviderRuntimeServices,
    ServingTemplate
  }

  @spec discover(binary(), keyword()) :: {:ok, map()} | {:error, atom()}
  def discover(path, opts \\ []) do
    env_file = if opts[:env_file], do: Path.expand(opts[:env_file])

    with {:ok, config} <- GatewayConfig.load(path, :discover),
         {:ok, host} <- PtcGateway.ToolTemplates.load_host(config["host"]["path"]),
         {:ok, catalog} <- HostInstallation.catalog(host) do
      try do
        entries =
          Enum.map(config["tools"], &Map.delete(&1, "expected_application_content_digest"))

        with {:ok, tools, metadata} <-
               PtcGateway.ToolTemplates.build(entries, host, catalog, config["artifacts"]),
             :ok <- PtcGateway.ToolTemplates.validate_catalog(metadata),
             {:ok, services} <-
               HostInstallation.runtime_services(host, provider_application_mode: :command_vm) do
          PtcRunner.Dotenv.with_loaded_file(env_file, fn -> capture(tools, services) end)
        end
      after
        InstallationCatalog.close(catalog)
      end
    end
    |> normalize()
  rescue
    _ -> {:error, :internal_error}
  catch
    _, _ -> {:error, :internal_error}
  end

  defp capture(tools, services) do
    names =
      tools
      |> Enum.flat_map(fn {_, tool} -> ServingTemplate.credential_names(tool.template) end)
      |> Enum.uniq()
      |> Enum.sort()

    with {:ok, credentials} <- CapturedCredentials.start(services.credential_resolver, names) do
      try do
        with {:ok, captured} <-
               ProviderRuntimeServices.with_captured_credentials(services, credentials, nil) do
          acquire(tools, captured)
        end
      after
        GenServer.stop(credentials)
      end
    end
  end

  defp acquire(tools, services) do
    tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {name, %{template: template}}, {:ok, result} ->
      case pins(template, services) do
        {:ok, pins} ->
          pins = %{
            "expected_application_content_digest" =>
              ServingTemplate.application_content_digest(template),
            "installation_config_pins" => pins.installation_config_pins,
            "provider_snapshot_pins" => pins.provider_snapshot_pins
          }

          {:cont, {:ok, Map.put(result, name, pins)}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp pins(template, services) do
    if ServingTemplate.runtime_context(template).required? do
      ProviderRuntime.discover(template, services)
    else
      {:ok, %{installation_config_pins: %{}, provider_snapshot_pins: %{}}}
    end
  end

  defp normalize({:ok, _} = result), do: result

  defp normalize({:error, code}) do
    code =
      if code in [
           :environment_file_not_found,
           :environment_file_not_regular,
           :environment_file_unreadable,
           :environment_file_too_large,
           :environment_file_invalid_utf8,
           :environment_file_invalid
         ], do: :credential_unavailable, else: code

    {:error, PtcGateway.StartupError.normalize(code)}
  end
end
