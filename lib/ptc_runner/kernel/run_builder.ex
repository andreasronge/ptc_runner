defmodule PtcRunner.Kernel.RunBuilder do
  @moduledoc """
  Shared path-free request construction and execution path.

  Filesystem and memory adapters first acquire a sealed
  `PtcRunner.Kernel.RunRequest`. The builder then resolves trusted provider
  names, compiles separate workflow and mission bundles, assembles their
  environments, starts the configured event sink, and produces the same
  `PtcRunner.Kernel.RunConfig` accepted by direct Elixir embedding. Relative
  artifact destinations are anchored once before preflight and the same
  absolute paths are retained through post-run persistence.

  Provider-free requests cross the same path-free
  `PtcRunner.Kernel.RunCoordinator` phases 4 and 5 as command frontends, and
  downstream assembly consumes the resulting sealed `PreparedRun` directly.
  Pure option validation completes before that one-way consumption. The Mix
  one-shot path performs this assembly inside the coordinator's
  execution-session owner so the prepared run and both sinks share one
  caller-death boundary.
  A provider-bearing prepared run is preflighted the same way, and its active
  session is passed here for runtime assembly. One-shot runs and `--check` both
  open that session inside the execution-session owner and call
  `build_active_owned/7` with the owner's sinks, then complete through
  `execute_built/1` or `check_built/1`. The REPL remains transitional: it calls
  `load_and_build/3` with an empty registry and opens no active session at
  all.
  `PtcRunner.Kernel.ProviderAcquisition` then runs the selected providers'
  shared preparation and dependency-ordered acquisition barrier. It plans that
  barrier from the preparation and the catalog it was validated against, which
  is why `build_active_owned/7` takes the catalog beside the prepared run, and
  it acquires against the credentials phase-8 step 5 already resolved. Active preparation, preflight, and acquisition are owner-linked and
  bounded by the session's run deadline; preflight releases share the
  provider-cleanup budget. Registry builders no longer open a second
  provider-session owner.

  A provider-bearing build remains owned by its build creator until execution
  binds it to a Runner or REPL lifecycle owner. The creator must remain alive
  until that bind or until `close/1`; returning an unstarted build from a
  short-lived task is not an ownership transfer.

  One-shot execution freezes its result, disclosure class, contract decision,
  terminal events, and optional inspection records in a sealed
  `PtcRunner.Kernel.ExecutionOutcome`. Both sinks stop before the separate
  publication step consumes that path-free evidence together with the sealed,
  preflighted `PtcRunner.Kernel.PublicationAuthority` retained by the build.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProviderAcquisition
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment

  @acquisition_options [
    :component_override_descriptor,
    :mission,
    :private_mission,
    :result_projection
  ]
  @build_options [
    :inspect,
    :installed_limits,
    :output,
    :private_output,
    :trace
  ]
  @load_options @acquisition_options ++ @build_options
  @artifact_options [:trace, :inspect, :output, :private_output]
  @opened_sink_keys [
    :attestation,
    :effective_event_policy,
    :event_identity,
    :event_sink,
    :inspection_identity,
    :inspection_path,
    :inspection_sink,
    :prepared_binding,
    :publication_binding
  ]

  @spec build(RunRequest.t(), ProviderRegistry.t(), keyword()) ::
          {:ok,
           %{
             entry_source: binary(),
             config: RunConfig.t(),
             publication_authority: PublicationAuthority.t(),
             result_projection: :native | :json
           }}
          | {:error, term()}
  @doc "Builds an entry expression and complete run configuration from a sealed request."
  def build(request, registry, opts \\ [])

  def build(%RunRequest{} = request, %ProviderRegistry{} = registry, opts) when is_list(opts) do
    package = request.package

    with :ok <- validate_registry(registry),
         :ok <- validate_build_options(opts),
         true <- RunRequest.valid?(request),
         :ok <- validate_installed_limits(package, registry, opts),
         :ok <- validate_inspection_selection(request, opts) do
      if provider_free?(package.providers),
        do: prepare_and_build(request, registry, opts),
        else: build_provider_bearing(request, registry, opts)
    else
      false -> {:error, :invalid_run_request}
      {:error, _reason} = error -> error
    end
  end

  def build(_request, _registry, _opts), do: {:error, :invalid_run_request}

  @spec build_prepared(PreparedRun.t(), ProviderRegistry.t(), keyword()) ::
          {:ok,
           %{
             entry_source: binary(),
             config: RunConfig.t(),
             publication_authority: PublicationAuthority.t(),
             result_projection: :native | :json
           }}
          | {:error, term()}
  @doc "Builds a provider-free run directly from the sealed phase-4/5 result."
  def build_prepared(prepared, registry, opts \\ [])

  def build_prepared(%PreparedRun{} = prepared, %ProviderRegistry{} = registry, opts)
      when is_list(opts) do
    build_prepared(prepared, registry, opts, :close_opened_sinks)
  end

  def build_prepared(_prepared, _registry, _opts), do: {:error, :invalid_prepared_run}

  @doc false
  @spec open_prepared_sinks(PreparedRun.t(), PublicationAuthority.t(), pid()) ::
          {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def open_prepared_sinks(%PreparedRun{} = prepared, authority, owner) when is_pid(owner) do
    with true <- PreparedRun.valid?(prepared),
         true <- PublicationAuthority.valid?(authority),
         :ok <- validate_sink_owner(owner),
         :ok <- PreparedRun.consume(prepared),
         opts = PublicationAuthority.options(authority),
         :ok <- preflight_owned_authority(prepared, opts) do
      do_open_prepared_sinks(prepared, authority, owner, opts)
    else
      false -> {:error, :invalid_prepared_run}
      {:error, _reason} = error -> error
    end
  end

  def open_prepared_sinks(_prepared, _authority, _owner),
    do: {:error, :invalid_prepared_run}

  @doc false
  @spec build_prepared_owned(
          PreparedRun.t(),
          ProviderRegistry.t(),
          PublicationAuthority.t(),
          map()
        ) :: {:ok, map()} | {:error, term()}
  def build_prepared_owned(
        %PreparedRun{} = prepared,
        %ProviderRegistry{} = registry,
        authority,
        opened_sinks
      ) do
    with :ok <- validate_registry(registry),
         true <- PreparedRun.consumed_valid?(prepared),
         true <- provider_free?(prepared.request.package.providers),
         true <- PublicationAuthority.valid?(authority),
         opts = PublicationAuthority.options(authority),
         :ok <- validate_build_options(opts),
         :ok <- validate_installed_limits(prepared.request.package, registry, opts),
         :ok <- validate_inspection_selection(prepared.request, opts),
         :ok <- validate_opened_sinks(opened_sinks, prepared, authority),
         :ok <- PreparedRun.begin_build(prepared) do
      build_prepared_with_opened_sinks(prepared, registry, opts, authority, opened_sinks)
    else
      false -> {:error, :invalid_prepared_run}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :invalid_prepared_run}
  end

  def build_prepared_owned(_prepared, _registry, _authority, _opened_sinks),
    do: {:error, :invalid_prepared_run}

  defp validate_sink_owner(owner),
    do: if(owner == self(), do: :ok, else: {:error, :invalid_execution_sinks})

  defp do_open_prepared_sinks(prepared, authority, owner, opts) do
    case event_sink(prepared.request, %{data_class: prepared.effective_data_class}, owner) do
      {:ok, event_sink} ->
        case inspection_sink(event_sink, opts, :return_opened_sinks, owner) do
          {:ok, inspection_sink, inspection_path} ->
            opened_sinks(prepared, authority, event_sink, inspection_sink, inspection_path)

          {:error, reason, opened_sinks} ->
            {:error, reason, opened_sinks}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp opened_sinks(prepared, authority, event_sink, inspection_sink, inspection_path) do
    with {:ok, event_identity} <- EventSink.identity(event_sink),
         {:ok, inspection_identity} <- opened_inspection_identity(inspection_sink) do
      descriptor = %{
        attestation: nil,
        event_sink: event_sink,
        inspection_sink: inspection_sink,
        inspection_path: inspection_path,
        event_identity: event_identity,
        inspection_identity: inspection_identity,
        effective_event_policy: prepared.effective_event_policy,
        prepared_binding: prepared.attestation,
        publication_binding: PublicationAuthority.binding(authority)
      }

      {:ok,
       %{
         descriptor
         | attestation: Attestation.attest(__MODULE__, opened_sinks_payload(descriptor))
       }}
    else
      {:error, reason} ->
        {:error, reason, %{event_sink: event_sink, inspection_sink: inspection_sink}}
    end
  end

  defp opened_inspection_identity(nil), do: {:ok, nil}
  defp opened_inspection_identity(inspection_sink), do: InspectionSink.identity(inspection_sink)

  defp opened_sinks_payload(opened_sinks), do: Map.delete(opened_sinks, :attestation)

  defp preflight_owned_authority(prepared, opts) do
    with :ok <- validate_build_options(opts),
         :ok <- validate_inspection_selection(prepared.request, opts),
         :ok <- preflight_inspection(opts),
         :ok <- preflight_artifact_destinations(opts),
         :ok <-
           preflight_trace(
             prepared.effective_event_policy,
             prepared.effective_data_class,
             opts
           ) do
      preflight_result(
        prepared.effective_event_policy,
        prepared.effective_data_class,
        opts
      )
    end
  end

  defp build_prepared(prepared, registry, opts, failure_mode) do
    request = prepared.request

    with :ok <- validate_registry(registry),
         true <- PreparedRun.valid?(prepared),
         true <- provider_free?(request.package.providers),
         :ok <- validate_build_options(opts),
         :ok <- validate_installed_limits(request.package, registry, opts),
         :ok <- validate_inspection_selection(request, opts),
         :ok <- PreparedRun.consume(prepared) do
      do_build_prepared(prepared, registry, opts, failure_mode)
    else
      false -> {:error, :invalid_prepared_run}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec preflight_prepared(PreparedRun.t(), keyword()) ::
          {:ok, keyword()} | {:error, term()}
  def preflight_prepared(%PreparedRun{} = prepared, opts) when is_list(opts) do
    with true <- PreparedRun.valid?(prepared),
         :ok <- validate_build_options(opts),
         :ok <- validate_inspection_selection(prepared.request, opts),
         {:ok, anchored_opts} <- anchor_artifact_options(opts),
         :ok <- preflight_inspection(anchored_opts),
         :ok <- preflight_artifact_destinations(anchored_opts),
         :ok <-
           preflight_trace(
             prepared.effective_event_policy,
             prepared.effective_data_class,
             anchored_opts
           ),
         :ok <-
           preflight_result(
             prepared.effective_event_policy,
             prepared.effective_data_class,
             anchored_opts
           ) do
      {:ok, anchored_opts}
    else
      false -> {:error, :invalid_prepared_run}
      {:error, _reason} = error -> error
    end
  end

  def preflight_prepared(_prepared, _opts), do: {:error, :invalid_prepared_run}

  @doc false
  @spec build_active_owned(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          PublicationAuthority.t(),
          map(),
          %{binary() => binary()}
        ) :: {:ok, map()} | {:error, term()}
  def build_active_owned(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %ProviderRegistry{} = registry,
        session,
        authority,
        opened_sinks,
        credentials
      ) do
    lifecycle_owner = ProviderSession.lifecycle_owner(session)

    with true <- PreparedRun.active_valid?(prepared),
         true <- is_pid(lifecycle_owner),
         :ok <-
           ProviderSession.claim_operation(
             session,
             prepared.request.package.limits,
             prepared.attestation
           ),
         :ok <- validate_registry(registry),
         true <- PublicationAuthority.valid?(authority),
         opts = PublicationAuthority.options(authority),
         :ok <- validate_build_options(opts),
         :ok <- validate_installed_limits(prepared.request.package, registry, opts),
         :ok <- validate_inspection_selection(prepared.request, opts),
         :ok <-
           validate_opened_sinks(
             opened_sinks,
             prepared,
             authority,
             lifecycle_owner
           ) do
      build_active_preflighted_owned(
        prepared,
        catalog,
        registry,
        session,
        authority,
        opened_sinks,
        credentials
      )
    else
      {:error, :operation_claimed} ->
        {:error, :invalid_active_run}

      {:error, :operation_mismatch} ->
        prefer_cleanup_error({:error, :invalid_active_run}, close_live_session(session))

      {:error, :provider_session_unavailable} ->
        {:error, :invalid_active_run}

      false ->
        prefer_cleanup_error({:error, :invalid_active_run}, close_live_session(session))

      {:error, _reason} = error ->
        prefer_cleanup_error(error, close_live_session(session))
    end
  end

  def build_active_owned(
        _prepared,
        _catalog,
        _registry,
        _session,
        _authority,
        _opened_sinks,
        _credentials
      ),
      do: {:error, :invalid_active_run}

  defp validate_registry(registry) do
    if ProviderRegistry.valid?(registry),
      do: :ok,
      else: {:error, :invalid_provider_registry}
  end

  defp validate_build_options(opts) when is_list(opts) do
    with :ok <- validate_option_shape(opts, @build_options),
         :ok <- validate_artifact_option_types(opts),
         true <- valid_optional_installed_limits?(opts),
         :ok <- validate_result_option_conflict(opts) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_build_options}
    end
  end

  defp validate_load_options(opts) when is_list(opts) do
    with :ok <- validate_option_shape(opts, @load_options),
         :ok <- validate_artifact_option_types(opts),
         true <- valid_optional_installed_limits?(opts),
         true <- valid_optional_binary?(opts, :component_override_descriptor),
         true <- valid_optional_binary?(opts, :mission),
         true <- valid_optional_binary?(opts, :private_mission),
         true <- valid_result_projection?(opts),
         :ok <- validate_mission_option_conflict(opts),
         :ok <- validate_result_option_conflict(opts) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_build_options}
    end
  end

  defp validate_load_options(_opts), do: {:error, :invalid_build_options}

  defp validate_option_shape(opts, allowed) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if keys -- allowed == [] and length(keys) == MapSet.size(MapSet.new(keys)),
        do: :ok,
        else: {:error, :invalid_build_options}
    else
      {:error, :invalid_build_options}
    end
  end

  defp validate_artifact_option_types(opts) do
    if Enum.all?(@artifact_options, &valid_optional_binary?(opts, &1)),
      do: :ok,
      else: invalid_artifact_destination()
  end

  defp valid_optional_installed_limits?(opts) do
    case Keyword.fetch(opts, :installed_limits) do
      {:ok, limits} -> Limits.valid?(limits)
      :error -> true
    end
  end

  defp valid_optional_binary?(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> is_nil(value) or is_binary(value)
      :error -> true
    end
  end

  defp valid_result_projection?(opts) do
    case Keyword.fetch(opts, :result_projection) do
      {:ok, projection} -> projection in [:native, :json]
      :error -> true
    end
  end

  defp validate_mission_option_conflict(opts) do
    if is_binary(Keyword.get(opts, :mission)) and
         is_binary(Keyword.get(opts, :private_mission)),
       do: {:error, :conflicting_mission_inputs},
       else: :ok
  end

  defp validate_result_option_conflict(opts) do
    if is_binary(Keyword.get(opts, :output)) and
         is_binary(Keyword.get(opts, :private_output)),
       do: {:error, {:result_preflight_failed, :conflicting_result_destinations}},
       else: :ok
  end

  defp validate_installed_limits(package, registry, opts) do
    expected = Keyword.get(opts, :installed_limits, registry.installed_limits)

    cond do
      not Limits.valid?(expected) -> {:error, :invalid_build_options}
      package.installed_limits == expected -> :ok
      true -> {:error, :installed_limits_mismatch}
    end
  end

  defp validate_inspection_selection(request, opts) do
    if request.policy.inspection_capture == is_binary(Keyword.get(opts, :inspect)),
      do: :ok,
      else: {:error, :invalid_execution_policy}
  end

  defp prepare_and_build(request, registry, opts) do
    installed_limits = Keyword.get(opts, :installed_limits, registry.installed_limits)

    with {:ok, catalog} <-
           InstallationCatalog.new(%{}, installed_limits: installed_limits) do
      case RunCoordinator.prepare(request, catalog) do
        {:ok, prepared} ->
          try do
            build_prepared(prepared, registry, opts)
          after
            PreparedRun.close(prepared)
          end

        {:error, _diagnostic} = error ->
          error
      end
    end
  end

  defp do_build_prepared(prepared, registry, opts, failure_mode) do
    bundles = {prepared.workflow_bundle, prepared.mission_bundle}

    assemble(
      prepared.request,
      bundles,
      prepared.entry_source,
      registry,
      opts,
      failure_mode
    )
  end

  defp build_prepared_with_opened_sinks(prepared, registry, opts, authority, opened_sinks) do
    with {:ok, providers} <-
           providers(
             prepared.request.package,
             registry,
             provider_input_class(prepared.request.input.authority),
             opts,
             nil
           ) do
      build_with_opened_sinks(
        prepared.request,
        {prepared.workflow_bundle, prepared.mission_bundle},
        prepared.entry_source,
        providers,
        authority,
        opened_sinks
      )
    end
  end

  defp build_active_preflighted_owned(
         prepared,
         catalog,
         registry,
         session,
         authority,
         opened_sinks,
         credentials
       ) do
    with {:ok, providers} <-
           providers(
             prepared.request.package,
             registry,
             provider_input_class(prepared.request.input.authority),
             PublicationAuthority.options(authority),
             {prepared, catalog, session, credentials}
           ) do
      build_with_opened_sinks(
        prepared.request,
        {prepared.workflow_bundle, prepared.mission_bundle},
        prepared.entry_source,
        providers,
        authority,
        opened_sinks
      )
    end
  end

  defp build_provider_bearing(request, registry, opts) do
    with {:ok, workflow_bundle} <- bundle(request.package.workflow_components),
         {:ok, mission_bundle} <- bundle(request.package.mission_components),
         :ok <- RunCoordinator.validate_entry(workflow_bundle, request.package.entry) do
      assemble(
        request,
        {workflow_bundle, mission_bundle},
        "(#{request.package.entry} data/input)",
        registry,
        opts,
        :close_opened_sinks
      )
    end
  end

  defp assemble(request, bundles, entry_source, registry, opts, failure_mode) do
    with {:ok, opts} <- anchor_artifact_options(opts),
         :ok <- preflight_inspection(opts),
         :ok <- preflight_artifact_destinations(opts),
         {:ok, providers} <-
           providers(
             request.package,
             registry,
             provider_input_class(request.input.authority),
             opts,
             nil
           ) do
      build_with_providers(request, bundles, entry_source, providers, opts, failure_mode)
    end
  end

  defp build_with_providers(
         request,
         {workflow_bundle, mission_bundle},
         entry_source,
         providers,
         opts,
         failure_mode
       ),
       do:
         build_with_providers(
           request,
           {workflow_bundle, mission_bundle},
           entry_source,
           providers,
           opts,
           failure_mode,
           :open_sinks
         )

  defp build_with_providers(
         request,
         {workflow_bundle, mission_bundle},
         entry_source,
         providers,
         opts,
         failure_mode,
         sink_source
       ) do
    package = request.package

    result =
      with {:ok, workflow} <-
             WorkflowEnvironment.new(
               bundle: workflow_bundle,
               capabilities: providers.workflow.capabilities
             ),
           {:ok, mission} <-
             MissionEnvironment.new(
               bundle: mission_bundle,
               capabilities: providers.mission.capabilities,
               data: package.mission_data
             ),
           {:ok, publication_authority, sink, inspection_sink, inspection_path} <-
             execution_sinks(request, providers, opts, failure_mode, sink_source),
           :ok <-
             capture_prelude_sources(
               inspection_sink,
               sink,
               {workflow, mission},
               package,
               failure_mode
             ) do
        build_config(
          {request, entry_source},
          providers,
          workflow,
          mission,
          {sink, inspection_sink, inspection_path},
          package.component_overrides,
          publication_authority,
          failure_mode
        )
      end

    case result do
      {:ok, _built} = success ->
        success

      {:error, _reason} = error ->
        prefer_cleanup_error(error, close_provider_session(providers.provider_session))

      {:error, _reason, _opened_sinks} = error ->
        error
    end
  end

  defp build_with_opened_sinks(
         request,
         {workflow_bundle, mission_bundle},
         entry_source,
         providers,
         authority,
         opened_sinks
       ) do
    build_with_providers(
      request,
      {workflow_bundle, mission_bundle},
      entry_source,
      providers,
      PublicationAuthority.options(authority),
      :return_opened_sinks,
      {:opened_sinks, authority, opened_sinks}
    )
    |> discard_opened_sinks()
  end

  defp execution_sinks(request, providers, opts, failure_mode, :open_sinks) do
    with {:ok, authority} <- PublicationAuthority.new(Keyword.take(opts, @artifact_options)),
         {:ok, event_sink} <- event_sink(request, providers),
         {:ok, inspection_sink, inspection_path} <-
           inspection_sink(event_sink, opts, failure_mode) do
      {:ok, authority, event_sink, inspection_sink, inspection_path}
    end
  end

  # Owner-opened sinks are fixed before any provider runs, from the sealed
  # declaration's effective data class. Descriptor-bound preparation and the
  # acquired-build comparison already refuse a provider whose data policy
  # contradicts its declaration, so this is defense in depth: it re-derives the
  # required policy from what was actually acquired and refuses drift rather
  # than emitting a stricter class through a sink opened for the weaker one.
  defp execution_sinks(
         request,
         providers,
         _opts,
         _failure_mode,
         {:opened_sinks, authority, opened_sinks}
       ) do
    case EventSink.policy(opened_sinks.event_sink) do
      # An unavailable sink is its own failure, not a contradicted declaration.
      {:error, :event_sink_error} ->
        {:error, :event_sink_error, opened_sinks}

      policy ->
        if required_event_policy(request, providers) == policy do
          {:ok, authority, opened_sinks.event_sink, opened_sinks.inspection_sink,
           opened_sinks.inspection_path}
        else
          {:error, :provider_data_class_drift, opened_sinks}
        end
    end
  end

  defp validate_opened_sinks(opened_sinks, prepared, authority),
    do: validate_opened_sinks(opened_sinks, prepared, authority, self())

  defp validate_opened_sinks(
         opened_sinks,
         %PreparedRun{} = prepared,
         authority,
         expected_owner
       )
       when is_map(opened_sinks) and map_size(opened_sinks) == 9 do
    with true <-
           Enum.sort(Map.keys(opened_sinks)) == @opened_sink_keys,
         true <-
           Attestation.valid?(
             __MODULE__,
             opened_sinks_payload(opened_sinks),
             opened_sinks.attestation
           ),
         %EventSink{} = event_sink <- opened_sinks.event_sink,
         {:ok, owner} <- EventSink.owner(event_sink),
         true <- owner == expected_owner,
         true <-
           PreparedRun.consumed_valid?(prepared) or PreparedRun.active_valid?(prepared),
         true <- prepared.attestation == opened_sinks.prepared_binding,
         true <- prepared.effective_event_policy == opened_sinks.effective_event_policy,
         true <- PublicationAuthority.matches?(authority, opened_sinks.publication_binding),
         true <- EventSink.policy(event_sink) == opened_sinks.effective_event_policy,
         {:ok, event_identity} <- EventSink.identity(event_sink),
         true <- event_identity == opened_sinks.event_identity,
         true <- valid_opened_inspection?(opened_sinks, expected_owner) do
      :ok
    else
      _invalid -> {:error, :invalid_execution_sinks}
    end
  end

  defp validate_opened_sinks(_opened_sinks, _prepared, _authority, _expected_owner),
    do: {:error, :invalid_execution_sinks}

  defp valid_opened_inspection?(
         %{
           inspection_sink: nil,
           inspection_path: nil,
           inspection_identity: nil
         },
         _expected_owner
       ),
       do: true

  defp valid_opened_inspection?(
         %{
           inspection_sink: %InspectionSink{} = inspection_sink,
           inspection_path: path,
           inspection_identity: identity,
           event_identity: identity
         },
         expected_owner
       )
       when is_binary(path) do
    InspectionSink.owner(inspection_sink) == {:ok, expected_owner} and
      InspectionSink.identity(inspection_sink) == {:ok, identity}
  end

  defp valid_opened_inspection?(_opened_sinks, _expected_owner), do: false

  defp discard_opened_sinks({:error, reason, _opened_sinks}), do: {:error, reason}
  defp discard_opened_sinks(result), do: result

  defp build_config(
         {request, entry_source},
         providers,
         workflow,
         mission,
         {sink, inspection_sink, inspection_path},
         component_overrides,
         publication_authority,
         failure_mode
       ) do
    package = request.package

    case RunConfig.new(
           workflow_environment: workflow,
           mission_environment: mission,
           input: %{"input" => request.input.value},
           limits: package.limits,
           event_sink: sink,
           result_contract: package.contracts.result,
           result_projection: request.policy.result_projection,
           inspection_sink: inspection_sink,
           inspection_path: inspection_path,
           provider_session: providers.provider_session,
           connector_snapshots: providers.snapshots,
           component_overrides: component_overrides,
           labels: package.labels
         ) do
      {:ok, config} ->
        {:ok,
         %{
           entry_source: entry_source,
           config: config,
           publication_authority: publication_authority,
           result_projection: request.policy.result_projection
         }}

      {:error, _reason} = error ->
        failed_build(error, sink, inspection_sink, failure_mode)
    end
  end

  # When capture is enabled, the exact effective prelude source of every
  # frozen component is retained as one private `prelude-source` record per
  # component, in frozen order, before execution. Frozen bundles retain only
  # source hashes, so source text comes from the manifest's validated
  # components, joined by the bundle's frozen order. Capture is required and
  # fail-closed: a rejected record prevents the run from starting.
  defp capture_prelude_sources(nil, _sink, _environments, _manifest, _failure_mode), do: :ok

  defp capture_prelude_sources(
         inspection_sink,
         sink,
         {workflow, mission},
         manifest,
         failure_mode
       ) do
    result =
      with :ok <-
             capture_bundle_sources(
               inspection_sink,
               "workflow",
               workflow.bundle,
               manifest.workflow_components
             ) do
        capture_bundle_sources(
          inspection_sink,
          "mission",
          mission.bundle,
          manifest.mission_components
        )
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        failed_build(error, sink, inspection_sink, failure_mode)
    end
  end

  defp capture_bundle_sources(_inspection_sink, _environment, nil, _components), do: :ok

  defp capture_bundle_sources(inspection_sink, environment, bundle, components) do
    sources = Map.new(components, &{&1.id, &1.source})

    Enum.reduce_while(bundle.component_ids, :ok, fn id, :ok ->
      with {:ok, source} when is_binary(source) <- Map.fetch(sources, id),
           :ok <-
             InspectionSink.emit(
               inspection_sink,
               "prelude-source",
               %{component_id: id},
               %{
                 environment: environment,
                 source: source,
                 source_hash: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
                 source_bytes: byte_size(source)
               }
             ) do
        {:cont, :ok}
      else
        _failure -> {:halt, {:error, :inspection_sink_error}}
      end
    end)
  end

  # `acquisition` is `nil` for a direct embedding build, which opens its own
  # unbounded session and lets the registry resolve credentials synchronously.
  # An active command supplies the sealed pair acquisition plans from, the
  # session it claimed, and the credentials phase-8 step 5 resolved.
  defp providers(manifest, registry, input_class, opts, acquisition)
       when input_class in [:normal, :private_inspection] do
    if provider_free?(manifest.providers) do
      with :ok <- preflight_trace(manifest.events.policy, input_class, opts),
           :ok <- preflight_result(manifest.events.policy, input_class, opts) do
        {:ok, empty_providers(input_class)}
      end
    else
      acquire_providers(manifest, registry, input_class, opts, acquisition)
    end
  end

  defp acquire_providers(manifest, registry, input_class, opts, nil) do
    with {:ok, session} <- ProviderSession.start(manifest.limits) do
      manifest
      |> ProviderAcquisition.acquire_embedded(
        registry,
        session,
        input_class,
        fn effective_class ->
          preflight_provider_artifacts(manifest, effective_class, opts)
        end
      )
      |> close_failed_acquisition(session)
    end
  end

  # An active command preflighted its artifact destinations when its publication
  # authority opened the sinks, before any provider work began, so acquisition
  # has nothing left to authorize here. A run and a check acquire the whole
  # selection; only connectivity narrows the targets.
  defp acquire_providers(
         _manifest,
         registry,
         _input_class,
         _opts,
         {prepared, catalog, session, credentials}
       ) do
    prepared
    |> ProviderAcquisition.acquire(catalog, registry, session, :all, credentials)
    |> close_failed_acquisition(session)
  end

  defp close_failed_acquisition({:ok, _providers} = success, _session), do: success

  defp close_failed_acquisition({:unregistered_provider_close, reason, close}, session) do
    prefer_cleanup_error(
      {:error, reason},
      ProviderSession.close_with_unregistered(session, close)
    )
  end

  defp close_failed_acquisition({:error, _reason} = error, session),
    do: prefer_cleanup_error(error, ProviderSession.close(session))

  defp preflight_provider_artifacts(manifest, effective_class, opts) do
    with :ok <- preflight_trace(manifest.events.policy, effective_class, opts),
         do: preflight_result(manifest.events.policy, effective_class, opts)
  end

  @spec close(%{config: RunConfig.t()} | RunConfig.t()) ::
          :ok | {:error, :provider_cleanup_failed}
  @doc "Closes a built but unexecuted configuration and its event sink."
  def close(%{config: %RunConfig{} = config}), do: close(config)

  def close(%RunConfig{} = config) do
    result = RunConfig.close_provider_session(config)
    if config.inspection_sink, do: InspectionSink.stop(config.inspection_sink)

    if Process.alive?(config.event_sink.pid), do: EventSink.stop(config.event_sink)
    result
  end

  defp close_provider_session(nil), do: :ok
  defp close_provider_session(session), do: ProviderSession.close(session)

  defp close_live_session(session) do
    if ProviderSession.alive?(session), do: ProviderSession.close(session), else: :ok
  end

  defp empty_providers(data_class) do
    %{
      workflow: %{capabilities: []},
      mission: %{capabilities: []},
      provider_session: nil,
      snapshots: [],
      data_class: data_class
    }
  end

  defp prefer_cleanup_error(_original, {:error, :provider_cleanup_failed} = cleanup), do: cleanup
  defp prefer_cleanup_error(original, :ok), do: original

  defp execute_and_publish(built) do
    with {:ok, outcome} <- execute_built(built) do
      publish_execution(outcome, built.publication_authority)
    end
  end

  @doc false
  @spec execute_built(map()) :: {:ok, ExecutionOutcome.t()} | {:error, term()}
  def execute_built(%{
        entry_source: entry_source,
        config: %RunConfig{} = config,
        publication_authority: authority
      })
      when is_binary(entry_source) do
    if PublicationAuthority.valid?(authority) do
      try do
        {result, terminal_batch} = Kernel.run_and_events(entry_source, config)

        ExecutionOutcome.capture(
          result,
          terminal_batch,
          config.event_sink,
          config.inspection_sink,
          config.result_contract,
          authority
        )
      after
        stop_execution_sinks(config)
      end
    else
      reject_execution(config)
    end
  end

  def execute_built(%{config: %RunConfig{} = config}), do: reject_execution(config)
  def execute_built(_built), do: {:error, :invalid_execution_outcome}

  # Completes an assembled build as a check rather than an execution: it reports
  # the safe connector snapshots the acquisition produced, closes the provider
  # session, and stops the sinks. It never evaluates the entry, finalizes a
  # terminal event batch, or publishes an artifact, so nothing belonging only to
  # execution can reach a destination through this path.
  #
  # Closing the session here is what keeps a check on the run's cleanup
  # ordering: a run closes its session inside `PtcRunner.Kernel` while the
  # registry and the OAuth runtime that produced its resources are still alive,
  # so a check closes its own session in the same place rather than returning an
  # open one to the execution owner.
  @doc false
  @spec check_built(map()) :: {:ok, [map()]} | {:error, term()}
  def check_built(%{config: %RunConfig{} = config, publication_authority: authority}) do
    if PublicationAuthority.valid?(authority) do
      snapshots = config.connector_snapshots
      cleanup = RunConfig.close_provider_session(config)
      stop_execution_sinks(config)

      case cleanup do
        :ok -> {:ok, snapshots}
        {:error, :provider_cleanup_failed} = error -> error
      end
    else
      reject_execution(config)
    end
  end

  def check_built(_built), do: {:error, :invalid_execution_outcome}

  @doc false
  @spec publish_execution(ExecutionOutcome.t(), PublicationAuthority.t()) ::
          {:ok, term(), :normal | :private} | {:error, term()}
  def publish_execution(outcome, authority) do
    with {:ok, evidence} <- ExecutionOutcome.open(outcome, authority) do
      do_publish_execution(evidence, PublicationAuthority.options(authority))
    end
  end

  defp do_publish_execution(
         %{
           result: result,
           result_class: result_class,
           result_contract: result_contract,
           terminal_batch: terminal_batch,
           inspection: inspection
         },
         opts
       ) do
    case terminal_batch do
      {:ok, events} ->
        with :ok <- persist_trace(Keyword.get(opts, :trace), result_class, events),
             :ok <- persist_inspection(inspection, opts, events),
             :ok <- result_contract,
             :ok <- persist_result(result, result_class, opts) do
          execution_result(result, result_class)
        else
          {:error, {:result_contract_failed, _details}} = error ->
            error

          {:error, {stage, reason}} ->
            {:error,
             {persistence_failure(stage), reason,
              disclosable(
                result,
                result_class,
                result_contract
              )}}
        end

      {:error, _reason} ->
        case result_contract do
          :ok -> execution_result(result, result_class)
          {:error, {:result_contract_failed, _details}} = error -> error
        end
    end
  end

  defp reject_execution(config),
    do: prefer_cleanup_error({:error, :invalid_execution_outcome}, close(config))

  defp execution_result({:ok, result}, class),
    do: {:ok, result, class}

  defp execution_result({:error, _reason} = error, _class), do: error

  defp stop_execution_sinks(%RunConfig{} = config) do
    if config.inspection_sink, do: InspectionSink.stop(config.inspection_sink)
    if Process.alive?(config.event_sink.pid), do: EventSink.stop(config.event_sink)
  end

  @spec load_and_build(binary(), ProviderRegistry.t()) ::
          {:ok,
           %{
             entry_source: binary(),
             config: RunConfig.t(),
             publication_authority: PublicationAuthority.t(),
             result_projection: :native | :json
           }}
          | {:error, term()}
  @doc """
  Loads a manifest and builds its run.

  The optional `:mission` or `:private_mission` path replaces the manifest
  input using the same manifest-relative confinement rules. They are mutually
  exclusive. A private mission marks the complete run value private before
  provider preflight or acquisition. The option names refer to CLI input
  authority; they change top-level workflow input, not mission-environment
  data. Manifest limits narrow the installed ceilings frozen in the registry.
  Trusted embedding may pass `:installed_limits` explicitly to replace that
  default for one construction.
  """
  def load_and_build(path, registry, opts \\ []) do
    case load_and_build_with_options(path, registry, opts) do
      {:ok, built, _anchored_opts} -> {:ok, built}
      {:error, _reason} = error -> error
    end
  end

  defp load_and_build_with_options(path, registry, opts) do
    with :ok <- validate_load_options(opts),
         :ok <- validate_registry(registry),
         installed_limits <- Keyword.get(opts, :installed_limits, registry.installed_limits),
         true <- Limits.valid?(installed_limits),
         {:ok, request_opts} <- request_options(opts, installed_limits),
         {:ok, request} <- ApplicationPackage.request_directory(path, request_opts),
         {:ok, opts} <- anchor_artifact_options(opts),
         build_opts = Keyword.drop(opts, @acquisition_options),
         {:ok, built} <- build(request, registry, build_opts) do
      {:ok, built, build_opts}
    else
      false -> {:error, :invalid_build_options}
      {:error, _reason} = error -> error
    end
  end

  defp request_options(opts, installed_limits) do
    with {:ok, input_opts} <- input_options(opts) do
      {:ok,
       input_opts ++
         [
           installed_limits: installed_limits,
           component_override_descriptor: Keyword.get(opts, :component_override_descriptor),
           inspection_capture: is_binary(Keyword.get(opts, :inspect)),
           result_projection: Keyword.get(opts, :result_projection, :native)
         ]}
    end
  end

  defp input_options(opts) do
    case {Keyword.get(opts, :mission), Keyword.get(opts, :private_mission)} do
      {nil, nil} ->
        {:ok, [input_authority: :normal]}

      {path, nil} when is_binary(path) ->
        {:ok, [input: path, input_authority: :normal]}

      {nil, path} when is_binary(path) ->
        {:ok, [input: path, input_authority: :private]}

      {path, private} when is_binary(path) and is_binary(private) ->
        {:error, :conflicting_mission_inputs}

      _invalid ->
        {:error, :invalid_input}
    end
  end

  defp anchor_artifact_options(opts) do
    case artifact_anchor_cwd(opts) do
      {:ok, cwd} ->
        anchor_artifact_options(@artifact_options, opts, cwd)

      {:error, _reason} ->
        invalid_artifact_destination()
    end
  end

  defp anchor_artifact_options([], opts, _cwd), do: {:ok, opts}

  defp anchor_artifact_options([key | rest], opts, cwd) do
    case anchor_artifact_option(opts, key, cwd) do
      {:ok, opts} -> anchor_artifact_options(rest, opts, cwd)
      {:error, _reason} -> invalid_artifact_destination()
    end
  end

  defp anchor_artifact_option(opts, key, cwd) do
    case Keyword.fetch(opts, key) do
      {:ok, path} when is_binary(path) ->
        with {:ok, path} <- PrivateDirectory.anchor(path, cwd),
             do: {:ok, Keyword.put(opts, key, path)}

      _missing_or_invalid ->
        {:ok, opts}
    end
  end

  defp artifact_anchor_cwd(opts) do
    relative? =
      Enum.any?(@artifact_options, fn key ->
        case Keyword.fetch(opts, key) do
          {:ok, path} when is_binary(path) -> Path.type(path) == :relative
          _missing_or_invalid -> false
        end
      end)

    if relative?, do: File.cwd(), else: {:ok, nil}
  end

  defp invalid_artifact_destination,
    do: {:error, {:artifact_preflight_failed, :invalid_destination}}

  # A deterministic destination conflict is reported after manifest and input
  # validation (so a bad output path never masks a more useful error) but
  # before provider preflight, credential resolution, acquisition, MCP
  # discovery, or model calls run.
  # The atomic no-clobber creation in `InspectionArtifact.persist/3` remains
  # authoritative for destinations that appear after this check.
  defp preflight_inspection(opts) do
    case Keyword.get(opts, :inspect) do
      nil ->
        :ok

      path ->
        case InspectionArtifact.preflight_destination(path) do
          :ok -> :ok
          {:error, reason} -> {:error, {:inspection_preflight_failed, reason}}
        end
    end
  end

  defp preflight_artifact_destinations(opts) do
    destinations =
      @artifact_options
      |> Enum.flat_map(fn key ->
        case Keyword.fetch(opts, key) do
          {:ok, path} when is_binary(path) -> [path]
          _missing_or_invalid -> []
        end
      end)

    with {:ok, identities} <- artifact_destination_identities(destinations) do
      if length(identities) == MapSet.size(MapSet.new(identities)),
        do: :ok,
        else: {:error, {:artifact_preflight_failed, :conflicting_destinations}}
    end
  end

  defp artifact_destination_identities(destinations) do
    Enum.reduce_while(destinations, {:ok, []}, fn path, {:ok, identities} ->
      case artifact_destination_identity(path) do
        {:ok, identity} -> {:cont, {:ok, [identity | identities]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp artifact_destination_identity(path) do
    if String.valid?(path) and not String.contains?(path, <<0>>) do
      parent = Path.dirname(path)
      basename = path |> Path.basename() |> PrivateDirectory.casefold_name()

      case File.stat(parent, time: :posix) do
        {:ok,
         %File.Stat{
           type: :directory,
           major_device: major,
           minor_device: minor,
           inode: inode
         }}
        when is_integer(major) and is_integer(minor) and is_integer(inode) ->
          {:ok, {:filesystem, major, minor, inode, basename}}

        _unavailable_or_unsupported ->
          {:ok, {:lexical, PrivateDirectory.casefold_name(path)}}
      end
    else
      {:error, {:artifact_preflight_failed, :invalid_destination}}
    end
  rescue
    _exception -> {:error, {:artifact_preflight_failed, :invalid_destination}}
  end

  defp preflight_trace(event_policy, provider_class, opts) do
    case Keyword.get(opts, :trace) do
      nil ->
        :ok

      path ->
        private? = event_policy == :private or provider_class == :private_inspection

        case TraceLog.preflight_destination(path, private?) do
          :ok -> :ok
          {:error, reason} -> {:error, {:trace_preflight_failed, reason}}
        end
    end
  end

  defp preflight_result(event_policy, provider_class, opts) do
    class =
      if event_policy == :private or provider_class == :private_inspection,
        do: :private,
        else: :normal

    case result_destination(opts) do
      {:ok, nil} ->
        :ok

      {:ok, {path, destination}} ->
        case ResultArtifact.preflight_destination(path, class, destination) do
          :ok -> :ok
          {:error, reason} -> {:error, {:result_preflight_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:result_preflight_failed, reason}}
    end
  end

  @spec run(binary(), ProviderRegistry.t()) :: {:ok, term()} | {:error, term()}
  @doc """
  Loads, builds, and executes a manifest-backed run.

  In addition to `:mission`, the optional `:trace` path persists retained
  canonical events as JSONL after execution. The event sink is always stopped.
  A trace persistence error is returned together with the completed Kernel
  result so callers do not mistake persistence failure for workflow failure.
  """
  def run(path, registry, opts \\ []) do
    case run_with_class(path, registry, opts) do
      {:ok, result, _class} -> {:ok, result}
      other -> other
    end
  end

  @spec run_with_class(binary(), ProviderRegistry.t(), keyword()) ::
          {:ok, term(), :normal | :private} | {:error, term()}
  @doc """
  Runs a manifest and also returns the effective class of its result.

  A caller that decides whether a value may be printed must not re-derive the
  class from the manifest file: that is a second read of a path the run no
  longer controls, and any failure of it would have to guess. The class comes
  from the same event sink the run itself used.
  """
  def run_with_class(path, registry, opts \\ []) do
    with {:ok, built, _anchored_opts} <- load_and_build_with_options(path, registry, opts) do
      execute_and_publish(built)
    end
  end

  defp provider_input_class(:normal), do: :normal
  defp provider_input_class(:private), do: :private_inspection

  defp persistence_failure(:trace), do: :trace_persistence_failed
  defp persistence_failure(:inspection), do: :inspection_persistence_failed
  defp persistence_failure(:result), do: :result_persistence_failed

  # A persistence failure is reported by a caller that renders the error, so a
  # private value must not travel inside it. Refusing to write a private value
  # and then printing it in the refusal would defeat the check entirely.
  defp disclosable(_result, _class, {:error, {:result_contract_failed, _details}} = error),
    do: error

  defp disclosable({:ok, %Result{} = result}, class, :ok) do
    case class do
      :private -> {:ok, %Result{result | value: :redacted}}
      :normal -> {:ok, result}
    end
  end

  defp disclosable(result, _class, :ok), do: result

  defp persist_result({:ok, %Result{} = result}, class, opts) do
    case result_destination(opts) do
      {:ok, nil} ->
        :ok

      {:ok, {path, destination}} ->
        case ResultArtifact.persist(path, result.value, class, destination) do
          :ok -> :ok
          {:error, reason} -> {:error, {:result, reason}}
        end

      {:error, reason} ->
        {:error, {:result, reason}}
    end
  end

  defp persist_result(_result, _class, _opts), do: :ok

  defp result_destination(opts) do
    case {Keyword.get(opts, :output), Keyword.get(opts, :private_output)} do
      {nil, nil} ->
        {:ok, nil}

      {path, nil} when is_binary(path) ->
        {:ok, {path, :normal}}

      {nil, path} when is_binary(path) ->
        {:ok, {path, :private}}

      {path, private} when is_binary(path) and is_binary(private) ->
        {:error, :conflicting_result_destinations}

      _invalid ->
        {:error, :invalid_result_destination}
    end
  end

  defp persist_trace(nil, _class, _events), do: :ok

  defp persist_trace(path, class, events) when is_binary(path) do
    case TraceLog.append_jsonl(path, events, private: class == :private) do
      :ok -> :ok
      {:error, reason} -> {:error, {:trace, reason}}
    end
  end

  defp persist_trace(_path, _class, _events), do: {:error, {:trace, :invalid_trace_log}}

  defp persist_inspection(:disabled, _opts, _events), do: :ok

  defp persist_inspection({:ok, records}, opts, events) do
    with path when is_binary(path) <- Keyword.get(opts, :inspect),
         :ok <- InspectionArtifact.persist(path, records, events) do
      :ok
    else
      nil -> {:error, {:inspection, :invalid_inspection_path}}
      {:error, reason} -> {:error, {:inspection, reason}}
    end
  end

  defp persist_inspection({:error, reason}, _opts, _events),
    do: {:error, {:inspection, reason}}

  defp provider_free?(%{workflow: [], mission: []}), do: true
  defp provider_free?(_providers), do: false

  defp bundle([]), do: {:ok, nil}
  defp bundle(components), do: Kernel.compile_bundle(components)

  defp event_sink(request, providers), do: event_sink(request, providers, self())

  defp event_sink(request, providers, owner) do
    policy = request.policy
    package = request.package

    opts =
      []
      |> maybe_put(:run_id, policy.run_id)
      |> maybe_put(:trace_id, policy.trace_id)
      |> Keyword.put(:owner, owner)

    EventSink.start(required_event_policy(request, providers), package.limits, opts)
  end

  # The sole rule for a run's event policy. Both the sink-opening path and the
  # owned path that inherits already-opened sinks must decide it the same way.
  defp required_event_policy(request, %{data_class: data_class}) do
    if request.policy.event_policy == :private or data_class == :private_inspection,
      do: :private,
      else: :normal
  end

  defp inspection_sink(event_sink, opts, failure_mode),
    do: inspection_sink(event_sink, opts, failure_mode, self())

  defp inspection_sink(event_sink, opts, failure_mode, owner) do
    case Keyword.get(opts, :inspect) do
      nil ->
        {:ok, nil, nil}

      path when is_binary(path) ->
        result =
          with {:ok, path} <- anchor_inspection_path(path),
               {:ok, identity} <- EventSink.identity(event_sink),
               {:ok, inspection_sink} <-
                 InspectionSink.start(
                   run_id: identity.run_id,
                   trace_id: identity.trace_id,
                   schema_version: 2,
                   owner: owner
                 ) do
            {:ok, inspection_sink, path}
          end

        case result do
          {:ok, _inspection_sink, _path} = success -> success
          {:error, _reason} = error -> failed_build(error, event_sink, nil, failure_mode)
        end

      _path ->
        failed_build({:error, :invalid_inspection_path}, event_sink, nil, failure_mode)
    end
  end

  defp failed_build({:error, reason}, event_sink, inspection_sink, :return_opened_sinks),
    do: {:error, reason, %{event_sink: event_sink, inspection_sink: inspection_sink}}

  defp failed_build(error, event_sink, inspection_sink, :close_opened_sinks) do
    if inspection_sink, do: InspectionSink.stop(inspection_sink)
    EventSink.stop(event_sink)
    error
  end

  defp anchor_inspection_path(path) do
    case PrivateDirectory.anchor(path) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, :invalid_inspection_path}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
