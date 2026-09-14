defmodule Mix.Tasks.Ptc.ProviderPins do
  @shortdoc "Print the two safe warm-provider pin maps for a manifest"
  @moduledoc """
  Acquires one serving manifest and prints the exact startup pin maps.

      mix ptc.provider_pins ptc.json --host ptc-host.json --env-file credentials.env

  `--host` is required. `--env-file` is optional and resolves from the invocation
  directory. The one-shot command never executes the workflow. It prints only
  `installation_config_pins` and `provider_snapshot_pins`, using installation
  identities and destination/name acquisition identities. It never prints
  credentials or provider-volatile content. Selected provider applications run
  only in this command VM. The exact temporary file scope is restored on every
  path; acquisition resources are closed before the command returns.
  """
  use Mix.Task

  alias PtcRunner.Kernel.{
    DeterministicJSON,
    HostConfig,
    HostInstallation,
    InstallationCatalog,
    ProviderRuntime,
    ServingTemplate
  }

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [host: :string, env_file: :string])

    if invalid != [] or length(opts) != MapSet.size(MapSet.new(Keyword.keys(opts))) or
         length(positional) != 1 or not Keyword.has_key?(opts, :host),
       do: Mix.raise("Invalid provider pin discovery arguments")

    result =
      PtcRunner.Dotenv.with_loaded_file(opts[:env_file], fn ->
        discover(hd(positional), opts[:host])
      end)

    if result != :ok, do: Mix.raise("Provider pin discovery failed")
  end

  defp discover(manifest, host_path) do
    with {:ok, host} <- HostConfig.load(host_path),
         {:ok, catalog} <- HostInstallation.catalog(host) do
      try do
        with {:ok, services} <-
               HostInstallation.runtime_services(host, provider_application_mode: :command_vm),
             {:ok, template} <-
               ServingTemplate.from_directory(manifest, host.limits, providers: catalog) do
          print_pins(template, services)
        end
      after
        InstallationCatalog.close(catalog)
      end
    end
  rescue
    _ -> {:error, :provider_pin_unavailable}
  catch
    _, _ -> {:error, :provider_pin_unavailable}
  end

  defp print_pins(template, services) do
    if ServingTemplate.runtime_context(template).required? do
      discover_pins(template, services)
    else
      print_empty_pins()
    end
  end

  defp print_empty_pins do
    {:ok, json} =
      DeterministicJSON.encode(%{
        installation_config_pins: %{},
        provider_snapshot_pins: %{}
      })

    IO.puts(json)
    :ok
  end

  defp discover_pins(template, services) do
    case ProviderRuntime.start_link(template: template, services: services, pins: :discover) do
      {:ok, runtime} -> GenServer.stop(runtime)
      _ -> {:error, :provider_pin_unavailable}
    end
  end
end
