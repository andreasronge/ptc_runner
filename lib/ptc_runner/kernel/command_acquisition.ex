defmodule PtcRunner.Kernel.CommandAcquisition do
  @moduledoc false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandApplicationDiagnostic
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDestination
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.ManifestReplPreparation
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProjectContext
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunRequest

  @doc false
  @spec prepare_repl(binary(), binary() | nil, CommandRuntime.t()) ::
          {:ok, ManifestReplPreparation.t()}
          | {:error, CommandDiagnostic.t() | :host_config_required | :invalid_manifest_repl}
  def prepare_repl(application, host_config, %CommandRuntime{} = runtime)
      when is_binary(application) and (is_binary(host_config) or is_nil(host_config)) do
    case catalog(host_config) do
      {:ok, host, catalog} ->
        prepare_repl_with_catalog(application, runtime, host, catalog)

      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, diagnostic}
    end
  end

  def prepare_repl(_application, _host_config, _runtime),
    do: {:error, :invalid_manifest_repl}

  @spec prepare(CommandArguments.t(), binary(), {map(), [atom()]}, CommandRuntime.t()) ::
          {:ok, CommandPreparation.t() | CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def prepare(%CommandArguments{command: command} = arguments, run_ref, destinations, runtime)
      when command in [:validate, :run] do
    case catalog(Map.get(arguments.options, :host_config)) do
      {:ok, host, catalog} ->
        prepare_with_catalog(arguments, run_ref, destinations, runtime, host, catalog)

      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}
    end
  end

  @spec request(binary(), InstallationCatalog.t(), keyword()) ::
          {:ok, RunRequest.t()} | {:error, term()}
  def request(application, %InstallationCatalog{} = catalog, options)
      when is_binary(application) and is_list(options) do
    if Keyword.keyword?(options) do
      options =
        Keyword.merge(options,
          installed_limits: catalog.installed_limits,
          result_projection: :json
        )

      ApplicationPackage.request_directory(application, options)
    else
      {:error, :invalid_application_options}
    end
  end

  def request(_application, _catalog, _options), do: {:error, :invalid_application_source}

  @spec catalog(binary() | nil) ::
          {:ok, HostConfig.t() | nil, InstallationCatalog.t()}
          | {:error, CommandDiagnostic.t()}
  def catalog(nil) do
    case InstallationCatalog.new() do
      {:ok, catalog} -> {:ok, nil, catalog}
      {:error, _reason} -> {:error, diagnostic(:internal, :internal_error)}
    end
  end

  def catalog(path) when is_binary(path) do
    case HostConfig.load_command(path) do
      {:ok, host} ->
        case HostInstallation.catalog(host) do
          {:ok, catalog} -> {:ok, host, catalog}
          {:error, _reason} -> {:error, diagnostic(:host, :host_invalid)}
        end

      {:error, :host_unavailable} ->
        {:error, diagnostic(:host, :host_unavailable)}

      {:error, :host_invalid} ->
        {:error, diagnostic(:host, :host_invalid)}

      {:error, {:installation_revision_missing, name}} ->
        {:ok, subject} = CommandSubject.provider(name, :declaration)
        {:error, CommandDiagnostic.new!(:host, :installation_revision_missing, subject: subject)}

      {:error, {:installation_endpoint_invalid, name, reason}} ->
        {:ok, subject} = CommandSubject.provider(name, :declaration)

        {:error,
         CommandDiagnostic.new!(:host, endpoint_diagnostic_code(reason), subject: subject)}

      {:error, {:host_schema_invalid, segments}} ->
        {:error, host_path_diagnostic(:host_schema_invalid, segments)}

      {:error, {:installed_limit_invalid, segments}} ->
        {:error, host_path_diagnostic(:installed_limit_invalid, segments)}
    end
  end

  def catalog(_source), do: {:error, diagnostic(:host, :host_unavailable)}

  defp endpoint_diagnostic_code(:insecure_loopback_required),
    do: :installation_endpoint_insecure_loopback_required

  defp endpoint_diagnostic_code(:literal_loopback_required),
    do: :installation_endpoint_literal_loopback_required

  defp endpoint_diagnostic_code(:insecure_loopback_forbidden),
    do: :installation_endpoint_insecure_loopback_forbidden

  defp endpoint_diagnostic_code(:credentials_require_https),
    do: :installation_endpoint_credentials_require_https

  defp endpoint_diagnostic_code(_reason), do: :installation_endpoint_invalid

  @spec with_catalog(binary() | nil, (HostConfig.t() | nil, InstallationCatalog.t() -> term())) ::
          term()
  def with_catalog(host_config, callback) when is_function(callback, 2) do
    case catalog(host_config) do
      {:ok, host, catalog} ->
        try do
          callback.(host, catalog)
        after
          InstallationCatalog.close(catalog)
        end

      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, diagnostic}
    end
  end

  @spec prepare_request(CommandArguments.t(), InstallationCatalog.t(), binary()) ::
          {:ok, PreparedRun.t()} | {:error, CommandDiagnostic.t()}
  def prepare_request(arguments, catalog, run_ref) do
    with {:ok, request} <- request_arguments(arguments, catalog, run_ref) do
      RunCoordinator.prepare(request, catalog)
    end
  end

  defp prepare_with_catalog(arguments, run_ref, destinations, runtime, host, catalog) do
    result =
      case prepare_request(arguments, catalog, run_ref) do
        {:ok, prepared} ->
          case command_runtime_services(host, runtime) do
            {:ok, runtime_services} ->
              command_preparation(
                arguments,
                run_ref,
                prepared,
                catalog,
                runtime_services,
                environment_setup_required?(host, prepared),
                destinations
              )

            {:error, _reason} ->
              invalid_preparation(arguments, run_ref, prepared)
          end

        {:error, %CommandDiagnostic{} = diagnostic} ->
          {:error, arguments_outcome(arguments, run_ref, diagnostic)}
      end

    if match?({:error, _outcome}, result), do: InstallationCatalog.close(catalog)
    result
  rescue
    exception ->
      InstallationCatalog.close(catalog)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      InstallationCatalog.close(catalog)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp command_preparation(
         arguments,
         run_ref,
         prepared,
         catalog,
         runtime_services,
         environment_setup_required,
         destinations
       ) do
    case arguments.command do
      :validate ->
        result = validation_outcome(arguments, run_ref, prepared)
        InstallationCatalog.close(catalog)
        result

      :run ->
        destinations = project_result_destinations(arguments, prepared, destinations)

        case CommandPreparation.new(
               :run,
               run_ref,
               prepared,
               catalog,
               runtime_services,
               environment_setup_required,
               project_artifact_root(arguments),
               destinations
             ) do
          {:ok, preparation} -> {:ok, preparation}
          {:error, _reason} -> invalid_preparation(arguments, run_ref, prepared)
        end
    end
  rescue
    exception ->
      PreparedRun.close(prepared)
      InstallationCatalog.close(catalog)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      PreparedRun.close(prepared)
      InstallationCatalog.close(catalog)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp project_result_destinations(
         %CommandArguments{project: %ProjectContext{derived_options: derived}},
         %{effective_event_policy: :private},
         {destinations, failures}
       ) do
    if MapSet.member?(derived, :result) do
      destinations =
        case Map.pop(destinations, :output) do
          {nil, remaining} -> remaining
          {path, remaining} -> Map.put(remaining, :private_output, private_result_path(path))
        end

      failures =
        Enum.map(failures, fn
          :output -> :private_output
          key -> key
        end)

      {destinations, failures}
    else
      {destinations, failures}
    end
  end

  defp project_result_destinations(_arguments, _prepared, destinations), do: destinations

  defp project_artifact_root(%CommandArguments{
         project: %ProjectContext{
           config: %{artifact_root: root},
           derived_options: derived
         }
       })
       when is_binary(root) do
    if MapSet.disjoint?(derived, MapSet.new([:trace_dir, :inspect, :result, :envelope])),
      do: nil,
      else: root
  end

  defp project_artifact_root(_arguments), do: nil

  defp private_result_path(path) do
    if String.ends_with?(path, ".json"),
      do: String.replace_suffix(path, ".json", ".private.json"),
      else: path <> ".private.json"
  end

  defp command_runtime_services(nil, runtime),
    do: ProviderRuntimeServices.new(provider_application_mode: runtime.provider_application_mode)

  defp command_runtime_services(%HostConfig{} = host, runtime),
    do:
      HostInstallation.runtime_services(host,
        provider_application_mode: runtime.provider_application_mode
      )

  defp prepare_repl_with_catalog(application, runtime, host, catalog) do
    result =
      with {:ok, request} <-
             ApplicationPackage.request_directory(application,
               installed_limits: catalog.installed_limits,
               result_projection: :native,
               input_authority: :normal,
               inspection_capture: false
             ),
           :ok <- require_repl_host(request, host),
           {:ok, prepared} <- RunCoordinator.prepare(request, catalog) do
        prepare_repl_runtime(prepared, catalog, host, runtime)
      else
        {:error, %CommandDiagnostic{} = diagnostic} -> {:error, diagnostic}
        {:error, :host_config_required} = error -> error
        {:error, reason} -> {:error, CommandApplicationDiagnostic.project(:run, reason)}
      end

    if match?({:error, _reason}, result), do: InstallationCatalog.close(catalog)
    result
  rescue
    _exception ->
      InstallationCatalog.close(catalog)
      {:error, :invalid_manifest_repl}
  catch
    _kind, _reason ->
      InstallationCatalog.close(catalog)
      {:error, :invalid_manifest_repl}
  end

  defp prepare_repl_runtime(prepared, catalog, host, runtime) do
    result =
      with {:ok, runtime_services} <- command_runtime_services(host, runtime),
           {:ok, preparation} <-
             ManifestReplPreparation.new(
               prepared,
               catalog,
               runtime_services,
               environment_setup_aliases(host, prepared)
             ) do
        {:ok, preparation}
      else
        {:error, _reason} -> {:error, :invalid_manifest_repl}
      end

    if match?({:error, _reason}, result), do: PreparedRun.close(prepared)
    result
  rescue
    _exception ->
      PreparedRun.close(prepared)
      {:error, :invalid_manifest_repl}
  catch
    _kind, _reason ->
      PreparedRun.close(prepared)
      {:error, :invalid_manifest_repl}
  end

  defp require_repl_host(%RunRequest{} = request, nil) do
    if request.package.providers == %{workflow: [], mission: []},
      do: :ok,
      else: {:error, :host_config_required}
  end

  defp require_repl_host(%RunRequest{}, %HostConfig{}), do: :ok

  @doc false
  @spec environment_setup_required?(HostConfig.t() | nil, PreparedRun.t()) :: boolean()
  def environment_setup_required?(nil, %PreparedRun{}), do: false

  def environment_setup_required?(%HostConfig{} = host, %PreparedRun{} = prepared) do
    environment_setup_aliases(host, prepared) != []
  end

  defp environment_setup_aliases(nil, %PreparedRun{}), do: []

  defp environment_setup_aliases(%HostConfig{} = host, %PreparedRun{} = prepared) do
    selected = MapSet.new(prepared.provider_declarations, & &1.name)

    selected
    |> Enum.filter(fn name ->
      with %{source: :llm, credential: credential} <- Map.get(host.install, name),
           %{source: :env} <- Map.get(host.credentials, credential) do
        true
      else
        _other -> false
      end
    end)
    |> Enum.sort()
  end

  defp validation_outcome(arguments, run_ref, prepared) do
    case RunCoordinator.validation_result(prepared) do
      {:ok, result} ->
        PreparedRun.close(prepared)
        {:ok, CommandOutcome.success(:validate, run_ref, result)}

      {:error, {:selection_unverifiable, name, occurrence}} ->
        PreparedRun.close(prepared)
        {:ok, subject} = CommandSubject.provider(name, :selection, occurrence)

        {:error,
         arguments_outcome(
           arguments,
           run_ref,
           CommandDiagnostic.new!(:provider_declaration, :selection_unverifiable,
             subject: subject
           )
         )}

      {:error, :invalid_prepared_run} ->
        invalid_preparation(arguments, run_ref, prepared)
    end
  end

  defp invalid_preparation(arguments, run_ref, prepared) do
    PreparedRun.close(prepared)
    {:error, arguments_outcome(arguments, run_ref, diagnostic(:internal, :internal_error))}
  end

  defp request_arguments(arguments, catalog, run_ref) do
    options =
      [inspection_capture: Map.has_key?(arguments.options, :inspect)]
      |> maybe_trace_identity(arguments, run_ref)
      |> maybe_input(arguments.options)
      |> maybe_override(arguments.options)

    case request(arguments.application, catalog, options) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error, CommandApplicationDiagnostic.project(arguments.command, reason)}
    end
  end

  defp maybe_trace_identity(
         options,
         %CommandArguments{command: :run, options: arguments},
         run_ref
       ) do
    if Map.has_key?(arguments, :trace_dir),
      do: Keyword.put(options, :event_identity, run_ref),
      else: options
  end

  defp maybe_trace_identity(options, _arguments, _run_ref), do: options

  defp maybe_input(options, arguments) do
    cond do
      path = Map.get(arguments, :input) ->
        Keyword.merge(options, input: path, input_authority: :normal)

      path = Map.get(arguments, :private_input) ->
        Keyword.merge(options, input: path, input_authority: :private)

      true ->
        options
    end
  end

  defp maybe_override(options, arguments) do
    case Map.get(arguments, :component_override_descriptor) do
      nil -> options
      path -> Keyword.put(options, :component_override_descriptor, path)
    end
  end

  defp arguments_outcome(%CommandArguments{command: :run, options: options}, run_ref, diagnostic) do
    CommandOutcome.run_error(
      run_ref,
      diagnostic,
      CommandDestination.requested_artifact_state(options)
    )
  end

  defp arguments_outcome(%CommandArguments{} = arguments, run_ref, diagnostic),
    do: CommandOutcome.error(arguments.command, run_ref, diagnostic)

  defp host_path_diagnostic(code, segments) do
    {:ok, path} = CommandPath.host(segments)
    CommandDiagnostic.new!(:host, code, source: CommandSource.fixed(:host), path: path)
  end

  defp diagnostic(phase, code) do
    source = if phase == :host, do: CommandSource.fixed(:host), else: nil
    CommandDiagnostic.new!(phase, code, source: source)
  end
end
