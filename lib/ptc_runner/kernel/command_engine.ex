defmodule PtcRunner.Kernel.CommandEngine do
  @moduledoc """
  Shared command preparation engine.

  The engine owns closed phase classification and privacy-safe outcomes. It
  does not write streams, halt the VM, exit a process, or inspect arbitrary
  failures. Filesystem paths are consumed before the path-free
  `RunCoordinator.prepare/2` boundary.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.DoctorEnvironment
  alias PtcRunner.Kernel.DoctorPlan
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunRequest

  @artifact_destination_keys [:trace_dir, :inspect, :output, :private_output]

  @type prepared :: CommandPreparation.t() | CommandOutcome.t()

  @spec prepare([binary()]) ::
          {:ok, prepared()} | {:error, CommandOutcome.t() | :entropy_unavailable}
  def prepare(argv) do
    with {:ok, run_ref} <- CommandRunRef.generate() do
      prepare_with_ref(argv, run_ref)
    end
  end

  @doc false
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

  @doc false
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

      {:error, {:host_schema_invalid, segments}} ->
        {:error, host_path_diagnostic(:host_schema_invalid, segments)}

      {:error, {:installed_limit_invalid, segments}} ->
        {:error, host_path_diagnostic(:installed_limit_invalid, segments)}
    end
  end

  def catalog(_source), do: {:error, diagnostic(:host, :host_unavailable)}

  defp prepare_with_ref(argv, run_ref) do
    case CommandParser.parse(argv) do
      {:ok, %CommandArguments{} = arguments} ->
        prepare_arguments_safely(
          arguments,
          run_ref,
          capture_artifact_destinations(arguments.options)
        )

      {:error, command, code} ->
        {:error, outcome(command, run_ref, :arguments, code)}
    end
  rescue
    _exception -> {:error, outcome(:unknown, run_ref, :internal, :internal_error)}
  catch
    _kind, _reason -> {:error, outcome(:unknown, run_ref, :internal, :internal_error)}
  end

  defp prepare_arguments_safely(%CommandArguments{} = arguments, run_ref, destinations) do
    prepare_arguments(arguments, run_ref, destinations)
  rescue
    _exception -> {:error, arguments_outcome(arguments, run_ref, :internal, :internal_error)}
  catch
    _kind, _reason ->
      {:error, arguments_outcome(arguments, run_ref, :internal, :internal_error)}
  end

  defp prepare_arguments(%CommandArguments{command: command} = arguments, run_ref, destinations)
       when command in [:validate, :run] do
    case catalog(Map.get(arguments.options, :host_config)) do
      {:ok, _host, catalog} ->
        try do
          result =
            with {:ok, request} <- request_arguments(arguments, catalog, run_ref),
                 {:ok, prepared} <- RunCoordinator.prepare(request, catalog) do
              command_preparation(arguments, run_ref, prepared, catalog, destinations)
            else
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

      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}
    end
  end

  defp prepare_arguments(
         %CommandArguments{command: :help, options: %{topic: topic}},
         run_ref,
         _destinations
       ) do
    {:ok, CommandOutcome.success(:help, run_ref, CommandContract.help_result(topic))}
  end

  defp prepare_arguments(%CommandArguments{command: :version}, run_ref, _destinations),
    do: {:ok, CommandOutcome.success(:version, run_ref, CommandContract.version_result())}

  # Default doctor reaches the shared phase-7 boundary and renders what it
  # returns. It selects the flow, assembles the sealed inputs, and projects the
  # result: no callback is invoked here, no deadline computed, and no occurrence
  # traversed. `doctor --connect` is a later slice.
  defp prepare_arguments(
         %CommandArguments{command: :doctor, options: options} = arguments,
         run_ref,
         _destinations
       )
       when not is_map_key(options, :connect) do
    case catalog(Map.get(options, :host_config)) do
      {:ok, host, catalog} ->
        try do
          result = doctor_outcome(arguments, run_ref, host, catalog)
          InstallationCatalog.close(catalog)
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

      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}
    end
  end

  defp prepare_arguments(%CommandArguments{command: command} = arguments, run_ref, _destinations)
       when command in [:init, :doctor, :models],
       do: {:error, arguments_outcome(arguments, run_ref, :internal, :internal_error)}

  defp doctor_outcome(arguments, run_ref, host, catalog) do
    case doctor_preparation(arguments, catalog, run_ref) do
      {:ok, prepared} ->
        result = doctor_checks(host, catalog, prepared)
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

  # An application is optional. Without one there is no selection to check, and
  # every provider row reports that an application is required.
  defp doctor_preparation(%CommandArguments{application: nil}, _catalog, _run_ref), do: {:ok, nil}

  defp doctor_preparation(arguments, catalog, run_ref) do
    with {:ok, request} <- request_arguments(arguments, catalog, run_ref) do
      RunCoordinator.prepare(request, catalog)
    end
  end

  # The plan is derived before the checks run and settled only after they all
  # succeed, because a failing audited-local check fails the whole command: the
  # closed contract has no failing provider row in any mode.
  defp doctor_checks(host, catalog, prepared) do
    with {:ok, rows} <- doctor_plan(catalog, prepared),
         {:ok, services} <- doctor_services(host),
         :ok <- RunCoordinator.local_checks(prepared, catalog, services),
         {:ok, settled} <- DoctorPlan.settle_pending(rows),
         {:ok, checks} <- DoctorPlan.checks(settled) do
      {:ok, checks}
    else
      {:error, %CommandDiagnostic{} = diagnostic} -> {:error, diagnostic}
      {:error, _reason} -> {:error, diagnostic(:internal, :internal_error)}
    end
  end

  defp doctor_plan(catalog, prepared),
    do: DoctorPlan.new(catalog, prepared, DoctorEnvironment.facts(), :default)

  defp doctor_services(nil), do: ProviderRuntimeServices.new([])
  defp doctor_services(host), do: HostInstallation.runtime_services(host)

  defp command_preparation(
         arguments,
         run_ref,
         prepared,
         catalog,
         {destinations, destination_failures}
       ) do
    case arguments.command do
      :validate ->
        result = validation_outcome(arguments, run_ref, prepared)
        InstallationCatalog.close(catalog)
        result

      :run ->
        case CommandPreparation.new(
               :run,
               run_ref,
               prepared,
               catalog,
               destinations,
               destination_failures
             ) do
          {:ok, preparation} ->
            {:ok, preparation}

          {:error, _reason} ->
            InstallationCatalog.close(catalog)
            invalid_command_preparation(arguments, run_ref, prepared)
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
           CommandDiagnostic.new!(
             :provider_declaration,
             :selection_unverifiable,
             subject: subject
           )
         )}

      {:error, :invalid_prepared_run} ->
        invalid_command_preparation(arguments, run_ref, prepared)
    end
  end

  defp capture_artifact_destinations(options) do
    destinations = Map.take(options, @artifact_destination_keys)

    case first_relative_destination(destinations) do
      nil ->
        {destinations, []}

      _relative_key ->
        case File.cwd() do
          {:ok, cwd} -> anchor_artifact_destinations(destinations, cwd)
          {:error, _reason} -> split_unanchored_destinations(destinations)
        end
    end
  end

  defp first_relative_destination(destinations) do
    Enum.find(@artifact_destination_keys, fn key ->
      case Map.fetch(destinations, key) do
        {:ok, path} -> Path.type(path) == :relative
        :error -> false
      end
    end)
  end

  defp anchor_artifact_destinations(destinations, cwd) do
    Enum.reduce(@artifact_destination_keys, {%{}, []}, fn key, {anchored, failures} ->
      with {:ok, path} <- Map.fetch(destinations, key),
           {:ok, path} <- PrivateDirectory.anchor(path, cwd) do
        {Map.put(anchored, key, path), failures}
      else
        :error -> {anchored, failures}
        {:error, _reason} -> {anchored, failures ++ [key]}
      end
    end)
  end

  defp split_unanchored_destinations(destinations) do
    Enum.reduce(@artifact_destination_keys, {%{}, []}, fn key, {anchored, failures} ->
      case Map.fetch(destinations, key) do
        {:ok, path} ->
          if Path.type(path) == :absolute,
            do: {Map.put(anchored, key, path), failures},
            else: {anchored, failures ++ [key]}

        :error ->
          {anchored, failures}
      end
    end)
  end

  defp invalid_command_preparation(arguments, run_ref, prepared) do
    PreparedRun.close(prepared)

    {:error,
     arguments_outcome(
       arguments,
       run_ref,
       diagnostic(:internal, :internal_error)
     )}
  end

  defp host_path_diagnostic(code, segments) do
    {:ok, path} = CommandPath.host(segments)

    CommandDiagnostic.new!(:host, code,
      source: CommandSource.fixed(:host),
      path: path
    )
  end

  defp request_arguments(arguments, catalog, run_ref) do
    options =
      [
        inspection_capture: Map.has_key?(arguments.options, :inspect)
      ]
      |> maybe_trace_identity(arguments, run_ref)
      |> maybe_input(arguments.options)
      |> maybe_override(arguments.options)

    case request(arguments.application, catalog, options) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error, application_diagnostic(arguments.command, reason)}
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

  defp application_diagnostic(command, reason) do
    {source_role, source_name, reason} = application_source_role(reason)
    {code, path_value} = application_projection(source_role, reason)

    source =
      if command in [:validate, :run],
        do: command_source(source_role, source_name),
        else: nil

    source = bind_contract_source(source, reason)
    path = command_path(source_role, path_value)

    CommandDiagnostic.new!(:application, code,
      source: source,
      path: path
    )
  end

  defp application_source_role({:source_role, role, reason})
       when role in [:external_input, :component_override],
       do: {role, nil, reason}

  defp application_source_role({:source_role, role, name, reason})
       when role in [:component, :input_contract, :result_contract] and is_binary(name),
       do: {role, name, reason}

  defp application_source_role(reason), do: {:application, nil, reason}

  defp command_source(role, nil)
       when role in [:application, :external_input, :component_override],
       do: CommandSource.fixed(role)

  defp command_source(role, name) when role in [:component, :input_contract, :result_contract] do
    {:ok, source} = CommandSource.new(role, name)
    source
  end

  defp application_projection(:component_override, reason)
       when reason in [
              :document_limit_exceeded,
              :json_depth_exceeded,
              :json_node_limit_exceeded
            ],
       do: {:document_limit_exceeded, nil}

  defp application_projection(
         :component_override,
         {:component_override_path, path, :invalid_override_descriptor}
       ),
       do: {:override_invalid, path}

  defp application_projection(:component_override, _reason), do: {:override_invalid, nil}

  defp application_projection(role, {:manifest_path, path, reason}) do
    case application_projection(role, reason) do
      {code, suffix} when suffix in [nil, []] -> {code, path}
      {code, suffix} -> {code, path ++ suffix}
    end
  end

  defp application_projection(_role, :invalid_json), do: {:invalid_json, nil}
  defp application_projection(_role, :duplicate_json_key), do: {:duplicate_property, nil}

  defp application_projection(_role, :required_properties_missing),
    do: {:required_property_missing, []}

  defp application_projection(_role, {:required_property_missing, name}),
    do: {:required_property_missing, [{:property, name}]}

  defp application_projection(_role, :unknown_properties), do: {:schema_violation, []}
  defp application_projection(_role, :reference_missing), do: {:reference_missing, nil}
  defp application_projection(_role, :invalid_logical_name), do: {:reference_missing, nil}

  defp application_projection(_role, reason)
       when reason in [
              :document_limit_exceeded,
              :json_depth_exceeded,
              :json_node_limit_exceeded
            ],
       do: {:document_limit_exceeded, nil}

  defp application_projection(role, :invalid_input)
       when role in [:application, :external_input],
       do: {:input_invalid, nil}

  defp application_projection(role, {:input_contract_failed, classification})
       when role in [:application, :external_input],
       do: {:input_contract_failed, first_violation_path(classification)}

  defp application_projection(_role, :invalid_contracts), do: {:contract_invalid, nil}

  defp application_projection(role, _reason)
       when role in [:input_contract, :result_contract],
       do: {:contract_invalid, nil}

  defp application_projection(_role, :input_contract_failed), do: {:input_contract_failed, nil}

  defp application_projection(_role, :event_identity_conflict),
    do: {:event_identity_conflict, [{:property, "events"}]}

  defp application_projection(_role, reason)
       when reason in [
              :invalid_override_descriptor,
              :ambiguous_override_target,
              :override_component_not_selected
            ],
       do: {:override_invalid, nil}

  defp application_projection(_role, reason)
       when reason in [
              :invalid_application_source,
              :application_source_unavailable,
              :outside_application_source,
              :not_found,
              :not_regular,
              :symlink_escape
            ],
       do: {:application_unavailable, nil}

  defp application_projection(_role, _reason), do: {:schema_violation, nil}

  defp first_violation_path(%{violations: violations}) when is_list(violations) do
    Enum.find_value(violations, fn
      %{path: %CommandPath{} = path} -> path
      _invalid -> nil
    end)
  end

  defp first_violation_path(_classification), do: nil

  defp command_path(_role, nil), do: nil
  defp command_path(_role, %CommandPath{} = path), do: path

  defp command_path(:component_override, segments) when is_list(segments) do
    {:ok, path} = CommandPath.component_override(segments)
    path
  end

  defp command_path(_role, segments) when is_list(segments) do
    {:ok, path} = CommandPath.manifest(segments)
    path
  end

  defp bind_contract_source(
         source,
         {:input_contract_failed, %{contract_authority: authority}}
       )
       when not is_nil(source) do
    {:ok, source} = CommandSource.with_contract(source, authority)
    source
  end

  defp bind_contract_source(source, _reason), do: source

  defp outcome(command, run_ref, phase, code) do
    diagnostic = diagnostic(phase, code)
    CommandOutcome.error(command, run_ref, diagnostic)
  end

  defp arguments_outcome(arguments, run_ref, phase, code),
    do: arguments_outcome(arguments, run_ref, diagnostic(phase, code))

  defp arguments_outcome(
         %CommandArguments{command: :run, options: options},
         run_ref,
         diagnostic
       ) do
    CommandOutcome.run_error(run_ref, diagnostic, requested_artifact_state(options))
  end

  defp arguments_outcome(%CommandArguments{} = arguments, run_ref, diagnostic),
    do: CommandOutcome.error(command_mode(arguments), run_ref, diagnostic)

  defp command_mode(%CommandArguments{command: :doctor, options: %{connect: true}}),
    do: {:doctor, :connect}

  defp command_mode(%CommandArguments{command: command}), do: command

  defp requested_artifact_state(options) do
    %{
      "trace" => requested_state(options, [:trace_dir]),
      "inspection" => requested_state(options, [:inspect]),
      "result" => requested_state(options, [:output, :private_output])
    }
  end

  defp requested_state(options, names) do
    if Enum.any?(names, &Map.has_key?(options, &1)),
      do: "not_written",
      else: "not_requested"
  end

  defp diagnostic(phase, code) do
    source = if phase == :host, do: CommandSource.fixed(:host), else: nil
    CommandDiagnostic.new!(phase, code, source: source)
  end
end
