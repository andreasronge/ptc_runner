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
  Pure option validation completes before that one-way consumption.
  The Mix command also preflights a provider-bearing prepared run, opens its
  active session, and passes that same session here for runtime assembly. The
  transitional registry builders remain until acquisition is cut over, but
  they no longer open a second provider-session owner.

  A provider-bearing build remains owned by its build creator until execution
  binds it to a Runner or REPL lifecycle owner. The creator must remain alive
  until that bind or until `close/1`; returning an unstarted build from a
  short-lived task is not an ownership transfer.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.ValueContract
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

  @spec build(RunRequest.t(), ProviderRegistry.t(), keyword()) ::
          {:ok,
           %{
             entry_source: binary(),
             config: RunConfig.t(),
             result_contract: ValueContract.t() | nil,
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
             result_contract: ValueContract.t() | nil,
             result_projection: :native | :json
           }}
          | {:error, term()}
  @doc "Builds a provider-free run directly from the sealed phase-4/5 result."
  def build_prepared(prepared, registry, opts \\ [])

  def build_prepared(%PreparedRun{} = prepared, %ProviderRegistry{} = registry, opts)
      when is_list(opts) do
    request = prepared.request

    with :ok <- validate_registry(registry),
         true <- PreparedRun.valid?(prepared),
         true <- provider_free?(request.package.providers),
         :ok <- validate_build_options(opts),
         :ok <- validate_installed_limits(request.package, registry, opts),
         :ok <- validate_inspection_selection(request, opts),
         :ok <- PreparedRun.consume(prepared) do
      do_build_prepared(prepared, registry, opts)
    else
      false -> {:error, :invalid_prepared_run}
      {:error, _reason} = error -> error
    end
  end

  def build_prepared(_prepared, _registry, _opts), do: {:error, :invalid_prepared_run}

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
  @spec build_active(
          PreparedRun.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def build_active(
        %PreparedRun{} = prepared,
        %ProviderRegistry{} = registry,
        %ProviderSession{} = session,
        opts
      )
      when is_list(opts) do
    result =
      with true <- PreparedRun.active_valid?(prepared),
           :ok <- validate_registry(registry),
           true <- ProviderSession.compatible_limits?(session, prepared.request.package.limits),
           :ok <- validate_build_options(opts),
           :ok <- validate_installed_limits(prepared.request.package, registry, opts),
           :ok <- validate_inspection_selection(prepared.request, opts) do
        build_active_preflighted(prepared, registry, session, opts)
      else
        false -> {:error, :invalid_active_run}
        {:error, _reason} = error -> error
      end

    case result do
      {:ok, _built} = success -> success
      {:error, _reason} = error -> prefer_cleanup_error(error, close_live_session(session))
    end
  end

  def build_active(_prepared, _registry, _session, _opts),
    do: {:error, :invalid_active_run}

  @doc false
  @spec run_active_with_class(
          PreparedRun.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          keyword()
        ) :: {:ok, term(), :normal | :private} | {:error, term()}
  def run_active_with_class(prepared, registry, session, opts) do
    case build_active(prepared, registry, session, opts) do
      {:ok, built} ->
        try do
          case execute_built(built, opts) do
            {:ok, result} -> {:ok, result, result_class(built.config.event_sink)}
            other -> other
          end
        after
          if built.config.inspection_sink, do: InspectionSink.stop(built.config.inspection_sink)

          if Process.alive?(built.config.event_sink.pid),
            do: EventSink.stop(built.config.event_sink)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec run_prepared_with_class(PreparedRun.t(), ProviderRegistry.t(), keyword()) ::
          {:ok, term(), :normal | :private} | {:error, term()}
  def run_prepared_with_class(prepared, registry, opts) do
    case build_prepared(prepared, registry, opts) do
      {:ok, built} ->
        try do
          case execute_built(built, opts) do
            {:ok, result} -> {:ok, result, result_class(built.config.event_sink)}
            other -> other
          end
        after
          if built.config.inspection_sink, do: InspectionSink.stop(built.config.inspection_sink)

          if Process.alive?(built.config.event_sink.pid),
            do: EventSink.stop(built.config.event_sink)
        end

      {:error, _reason} = error ->
        error
    end
  end

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

  defp do_build_prepared(prepared, registry, opts) do
    bundles = {prepared.workflow_bundle, prepared.mission_bundle}

    assemble(
      prepared.request,
      bundles,
      prepared.entry_source,
      registry,
      opts
    )
  end

  defp build_active_preflighted(prepared, registry, session, opts) do
    with {:ok, providers} <-
           providers(
             prepared.request.package,
             registry,
             provider_input_class(prepared.request.input.authority),
             opts,
             session
           ) do
      build_with_providers(
        prepared.request,
        {prepared.workflow_bundle, prepared.mission_bundle},
        prepared.entry_source,
        providers,
        opts
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
        opts
      )
    end
  end

  defp assemble(request, bundles, entry_source, registry, opts) do
    with {:ok, opts} <- anchor_artifact_options(opts),
         :ok <- preflight_inspection(opts),
         :ok <- preflight_artifact_destinations(opts),
         {:ok, providers} <-
           providers(
             request.package,
             registry,
             provider_input_class(request.input.authority),
             opts
           ) do
      build_with_providers(request, bundles, entry_source, providers, opts)
    end
  end

  defp build_with_providers(
         request,
         {workflow_bundle, mission_bundle},
         entry_source,
         providers,
         opts
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
           {:ok, sink} <- event_sink(request, providers),
           {:ok, inspection_sink, inspection_path} <- inspection_sink(sink, opts),
           :ok <- capture_prelude_sources(inspection_sink, sink, {workflow, mission}, package) do
        build_config(
          {request, entry_source},
          providers,
          workflow,
          mission,
          sink,
          inspection_sink,
          inspection_path,
          package.component_overrides
        )
      end

    case result do
      {:ok, _built} = success ->
        success

      {:error, _reason} = error ->
        prefer_cleanup_error(error, close_provider_session(providers.provider_session))
    end
  end

  defp build_config(
         {request, entry_source},
         providers,
         workflow,
         mission,
         sink,
         inspection_sink,
         inspection_path,
         component_overrides
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
           result_contract: package.contracts.result,
           result_projection: request.policy.result_projection
         }}

      {:error, _reason} = error ->
        if inspection_sink, do: InspectionSink.stop(inspection_sink)
        EventSink.stop(sink)
        error
    end
  end

  # When capture is enabled, the exact effective prelude source of every
  # frozen component is retained as one private `prelude-source` record per
  # component, in frozen order, before execution. Frozen bundles retain only
  # source hashes, so source text comes from the manifest's validated
  # components, joined by the bundle's frozen order. Capture is required and
  # fail-closed: a rejected record prevents the run from starting.
  defp capture_prelude_sources(nil, _sink, _environments, _manifest), do: :ok

  defp capture_prelude_sources(inspection_sink, sink, {workflow, mission}, manifest) do
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
        InspectionSink.stop(inspection_sink)
        EventSink.stop(sink)
        error
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

  defp providers(manifest, registry, input_class, opts, session \\ nil)
       when input_class in [:normal, :private_inspection] do
    if provider_specs(manifest) == [] do
      with :ok <- preflight_trace(manifest.events.policy, input_class, opts),
           :ok <- preflight_result(manifest.events.policy, input_class, opts) do
        {:ok, empty_providers(input_class)}
      end
    else
      open_provider_session(manifest, registry, input_class, opts, session)
    end
  end

  defp open_provider_session(manifest, registry, input_class, opts, nil) do
    with {:ok, session} <- ProviderSession.start(manifest.limits) do
      finish_provider_session(manifest, registry, session, input_class, opts, true)
    end
  end

  defp open_provider_session(
         manifest,
         registry,
         input_class,
         opts,
         %ProviderSession{} = session
       ) do
    finish_provider_session(manifest, registry, session, input_class, opts, false)
  end

  defp finish_provider_session(manifest, registry, session, input_class, opts, preflight?) do
    result =
      with {:ok, prepared} <- prepare_providers(manifest, registry, session),
           :ok <- validate_provider_dependencies(prepared),
           :ok <- validate_single_workflow_llm(prepared),
           effective_class <- effective_data_class(input_class, prepared),
           :ok <- providers_accept(prepared, effective_class),
           :ok <- preflight_provider_artifacts(preflight?, manifest, effective_class, opts),
           {:ok, preflighted} <- preflight_providers(prepared) do
        try do
          with {:ok, credentials} <-
                 ProviderRegistry.resolve_credentials(registry, credential_names(prepared)),
               {:ok, acquired} <- acquire_providers(preflighted, credentials, effective_class) do
            {:ok,
             acquired
             |> Map.put(:workflow, finalize_capabilities(acquired.workflow))
             |> Map.put(:mission, finalize_capabilities(acquired.mission))
             |> Map.put(:snapshots, sort_snapshots(acquired.snapshots))
             |> Map.put(:provider_session, session)
             |> Map.delete(:exports)}
          end
        after
          release_preflights(preflighted)
        end
      end

    case result do
      {:ok, _providers} = success ->
        success

      {:unregistered_provider_close, reason, close} ->
        prefer_cleanup_error(
          {:error, reason},
          ProviderSession.close_with_unregistered(session, close)
        )

      {:error, _reason} = error ->
        prefer_cleanup_error(error, ProviderSession.close(session))
    end
  end

  defp preflight_provider_artifacts(true, manifest, effective_class, opts) do
    with :ok <- preflight_trace(manifest.events.policy, effective_class, opts),
         do: preflight_result(manifest.events.policy, effective_class, opts)
  end

  defp preflight_provider_artifacts(false, _manifest, _effective_class, _opts), do: :ok

  defp sort_snapshots(snapshots), do: Enum.sort_by(snapshots, &Map.get(&1, "provider", ""))

  defp prepare_providers(package, registry, session) do
    package
    |> provider_specs()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{destination, spec}, index}, {:ok, prepared} ->
      case ProviderSession.open_registrar(session) do
        {:ok, registrar} ->
          prepare_provider(package, registry, registrar, destination, spec, index, prepared)

        {:error, _reason} ->
          {:halt, {:error, :provider_session_unavailable}}
      end
    end)
    |> reverse_success()
  end

  defp prepare_provider(package, registry, registrar, destination, spec, index, prepared) do
    context = %{
      application_content_digest: package.application_content_digest,
      destination: destination,
      owner: ResourceRegistrar.owner(registrar),
      resource_registrar: registrar,
      limits: package.limits,
      installed_limits: package.installed_limits
    }

    case ProviderRegistry.prepare(
           registry,
           spec["name"],
           Map.get(spec, "config", %{}),
           context
         ) do
      {:ok, provider} ->
        entry = %{
          index: index,
          provider: spec["name"],
          destination: destination,
          credential_names: provider.credential_names,
          data_class: provider.data_class,
          accepts_data: provider.accepts_data,
          requires: provider.requires,
          provides: provider.provides,
          workflow_llm?: provider.workflow_llm?,
          registrar: registrar,
          prepared: provider
        }

        {:cont, {:ok, [entry | prepared]}}

      {:error, _reason} = error ->
        _ = ResourceRegistrar.abort(registrar)
        {:halt, error}
    end
  end

  defp preflight_providers(prepared) do
    prepared
    |> Enum.reduce_while({:ok, []}, fn provider, {:ok, preflighted} ->
      case ProviderRegistry.preflight(provider.prepared) do
        {:ok, phase} ->
          entry =
            provider
            |> Map.delete(:prepared)
            |> Map.put(:preflighted, phase)

          {:cont, {:ok, [entry | preflighted]}}

        {:error, _reason} = error ->
          release_preflights(preflighted)
          {:halt, error}
      end
    end)
    |> reverse_success()
  end

  defp acquire_providers(preflighted, credentials, effective_class) do
    initial = %{
      workflow: %{capabilities: []},
      mission: %{capabilities: []},
      snapshots: [],
      exports: %{},
      data_class: effective_class
    }

    acquire_ready_providers(preflighted, credentials, initial)
  end

  defp acquire_ready_providers([], _credentials, accumulated), do: {:ok, accumulated}

  defp acquire_ready_providers(pending, credentials, accumulated) do
    case Enum.split_with(pending, &services_available?(&1, accumulated.exports)) do
      {[], _blocked} ->
        {:error, :provider_dependency_unavailable}

      {ready, blocked} ->
        case acquire_provider_batch(ready, credentials, accumulated) do
          {:ok, next} -> acquire_ready_providers(blocked, credentials, next)
          {:unregistered_provider_close, _reason, _close} = cleanup -> cleanup
          {:error, _reason} = error -> error
        end
    end
  end

  defp acquire_provider_batch(providers, credentials, accumulated) do
    Enum.reduce_while(providers, {:ok, accumulated}, fn provider, {:ok, current} ->
      provider_credentials = Map.take(credentials, provider.credential_names)
      services = selected_services(current.exports, provider.requires)

      result =
        with :ok <- ResourceRegistrar.activate(provider.registrar) do
          ProviderRegistry.acquire(provider.preflighted, provider_credentials, services)
        end

      case result do
        {:ok, built}
        when built.data_class == provider.data_class and
               built.accepts_data == provider.accepts_data ->
          case ResourceRegistrar.commit(provider.registrar, built.close) do
            :ok ->
              environment = Map.fetch!(current, provider.destination)

              next =
                current
                |> Map.put(provider.destination, %{
                  capabilities: [{provider.index, built.capabilities} | environment.capabilities]
                })
                |> Map.update!(:snapshots, &maybe_append(&1, built.snapshot))
                |> Map.update!(
                  :exports,
                  &merge_provider_exports(&1, provider.provider, built.exports)
                )

              {:cont, {:ok, next}}

            {:error, _reason} ->
              {:halt, {:unregistered_provider_close, :provider_session_unavailable, built.close}}
          end

        {:ok, built} ->
          case ResourceRegistrar.commit(provider.registrar, built.close) do
            :ok ->
              {:halt, {:error, :provider_data_policy_changed}}

            {:error, _reason} ->
              {:halt, {:unregistered_provider_close, :provider_data_policy_changed, built.close}}
          end

        {:error, _reason} = error ->
          _ = ResourceRegistrar.abort(provider.registrar)
          {:halt, error}
      end
    end)
  end

  defp services_available?(provider, exports),
    do: Enum.all?(provider.requires, &match?([{_provider, _value}], Map.get(exports, &1)))

  defp merge_provider_exports(exports, provider, built_exports) do
    Enum.reduce(built_exports, exports, fn {service, value}, accumulated ->
      Map.update(accumulated, service, [{provider, value}], &[{provider, value} | &1])
    end)
  end

  defp selected_services(exports, requires) do
    Map.new(requires, fn service ->
      [{_provider, value}] = Map.fetch!(exports, service)
      {service, value}
    end)
  end

  defp finalize_capabilities(%{capabilities: capabilities}) do
    %{
      capabilities:
        capabilities
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(&elem(&1, 1))
    }
  end

  defp validate_provider_dependencies(prepared) do
    provided = Enum.flat_map(prepared, & &1.provides)
    required = Enum.flat_map(prepared, & &1.requires) |> Enum.uniq()
    counts = Enum.frequencies(provided)

    cond do
      Enum.any?(required, &(Map.get(counts, &1, 0) == 0)) ->
        {:error, :provider_dependency_unavailable}

      Enum.any?(required, &(Map.fetch!(counts, &1) > 1)) ->
        {:error, :ambiguous_provider_dependency}

      true ->
        :ok
    end
  end

  # A run has one frozen workflow environment, so it has one language model.
  # Selecting a live alias and a replay alias together would otherwise be
  # decided by whichever capability won the duplicate-name check during
  # environment construction — after fixtures were opened and credentials
  # resolved. An evaluation trial has to be attributable to its configured
  # provider, so this fails while every provider is still inert.
  defp validate_single_workflow_llm(prepared) do
    workflow_llms =
      Enum.count(prepared, fn entry ->
        entry.destination == :workflow and entry.workflow_llm?
      end)

    if workflow_llms > 1, do: {:error, :ambiguous_workflow_llm}, else: :ok
  end

  defp provider_specs(manifest) do
    for destination <- [:workflow, :mission],
        spec <- Map.fetch!(manifest.providers, destination),
        do: {destination, spec}
  end

  defp credential_names(prepared) do
    prepared
    |> Enum.flat_map(& &1.credential_names)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp reverse_success({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_success({:error, _reason} = error), do: error

  defp release_preflights(preflighted) do
    Enum.each(preflighted, fn
      %{preflighted: provider} -> ProviderRegistry.release_preflight(provider)
      provider -> ProviderRegistry.release_preflight(provider)
    end)
  end

  defp strictest_data_class(:private_inspection, _next), do: :private_inspection
  defp strictest_data_class(_current, :private_inspection), do: :private_inspection
  defp strictest_data_class(:normal, :normal), do: :normal

  defp effective_data_class(input_class, prepared) do
    Enum.reduce(prepared, input_class, fn provider, current ->
      strictest_data_class(current, provider.data_class)
    end)
  end

  defp providers_accept(prepared, effective_class) do
    if Enum.all?(prepared, &(effective_class in &1.accepts_data)),
      do: :ok,
      else: {:error, :provider_data_class_denied}
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

  defp close_live_session(%ProviderSession{pid: pid} = session) do
    if Process.alive?(pid), do: ProviderSession.close(session), else: :ok
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

  # The provider session is already closed by `Kernel.run_and_events/2`; the
  # returned terminal batch is the sole input to both persistence paths.
  defp execute_built(built, opts) do
    {result, terminal_batch} = Kernel.run_and_events(built.entry_source, built.config)
    result_contract = validate_result(result, built.result_contract)

    case terminal_batch do
      {:ok, events} ->
        with :ok <- persist_trace(Keyword.get(opts, :trace), built.config.event_sink, events),
             :ok <- persist_inspection(built.config, events),
             :ok <- result_contract,
             :ok <- persist_result(result, built.config.event_sink, opts) do
          result
        else
          {:error, {:result_contract_failed, _details}} = error ->
            error

          {:error, {stage, reason}} ->
            {:error,
             {persistence_failure(stage), reason,
              disclosable(result, built.config.event_sink, result_contract)}}
        end

      {:error, _reason} ->
        case result_contract do
          :ok -> result
          {:error, {:result_contract_failed, _details}} = error -> error
        end
    end
  end

  @spec load_and_build(binary(), ProviderRegistry.t()) ::
          {:ok,
           %{
             entry_source: binary(),
             config: RunConfig.t(),
             result_contract: ValueContract.t() | nil,
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
    with {:ok, built, opts} <- load_and_build_with_options(path, registry, opts) do
      try do
        case execute_built(built, opts) do
          {:ok, result} -> {:ok, result, result_class(built.config.event_sink)}
          other -> other
        end
      after
        if built.config.inspection_sink, do: InspectionSink.stop(built.config.inspection_sink)

        if Process.alive?(built.config.event_sink.pid),
          do: EventSink.stop(built.config.event_sink)
      end
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
  defp disclosable(_result, _sink, {:error, {:result_contract_failed, _details}} = error),
    do: error

  defp disclosable({:ok, %Result{} = result}, sink, :ok) do
    case result_class(sink) do
      :private -> {:ok, %Result{result | value: :redacted}}
      :normal -> {:ok, result}
    end
  end

  defp disclosable(result, _sink, :ok), do: result

  defp validate_result(_result, nil), do: :ok

  defp validate_result({:ok, %Result{value: value}}, %ValueContract{} = contract) do
    case json_contract_value(value) do
      {:ok, public} ->
        if ValueContract.valid?(contract, public),
          do: :ok,
          else: {:error, {:result_contract_failed, ValueContract.classify(contract, public)}}

      {:error, _reason} ->
        {:error, {:result_contract_failed, %{value_kind: :invalid_json}}}
    end
  end

  defp validate_result(_result, %ValueContract{}), do: :ok

  @doc """
  Returns the effective class of a run's result.

  The effective event policy includes both the manifest policy and the
  strictest selected provider data class. A private-event run or a provider
  that emits private inspection data therefore produces a private value.

  Fails closed. Only an explicit `:normal` policy yields a normal class, so a
  sink that has exited — `EventSink.policy/1` then returns an error tuple —
  classifies its value private rather than publishable.
  """
  @spec result_class(EventSink.t()) :: :normal | :private
  def result_class(sink) do
    case EventSink.policy(sink) do
      :normal -> :normal
      _other -> :private
    end
  end

  defp persist_result({:ok, %Result{} = result}, sink, opts) do
    class = result_class(sink)

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

  defp persist_result(_result, _sink, _opts), do: :ok

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

  # Result values have already crossed the strict Kernel JSON boundary. Decode
  # the same deterministic bytes used by artifacts and result hashes so result
  # contracts see ordinary JSON values without a second, potentially lossy
  # map-key conversion.
  defp json_contract_value(value) do
    ValueContract.json_value(value)
  end

  defp persist_trace(nil, _sink, _events), do: :ok

  defp persist_trace(path, sink, events) when is_binary(path) do
    private? = EventSink.policy(sink) == :private

    case TraceLog.append_jsonl(path, events, private: private?) do
      :ok -> :ok
      {:error, reason} -> {:error, {:trace, reason}}
    end
  end

  defp persist_trace(_path, _sink, _events), do: {:error, {:trace, :invalid_trace_log}}

  defp persist_inspection(%RunConfig{inspection_sink: nil}, _events), do: :ok

  defp persist_inspection(%RunConfig{} = config, events) do
    with {:ok, records} <- InspectionSink.records(config.inspection_sink),
         :ok <-
           InspectionArtifact.persist(
             config.inspection_path,
             records,
             events
           ) do
      :ok
    else
      {:error, reason} -> {:error, {:inspection, reason}}
    end
  end

  defp maybe_append(values, nil), do: values
  defp maybe_append(values, value), do: values ++ [value]

  defp provider_free?(%{workflow: [], mission: []}), do: true
  defp provider_free?(_providers), do: false

  defp bundle([]), do: {:ok, nil}
  defp bundle(components), do: Kernel.compile_bundle(components)

  defp event_sink(request, providers) do
    policy = request.policy
    package = request.package

    opts =
      []
      |> maybe_put(:run_id, policy.run_id)
      |> maybe_put(:trace_id, policy.trace_id)

    effective_policy =
      if policy.event_policy == :private or providers.data_class == :private_inspection,
        do: :private,
        else: :normal

    EventSink.start(effective_policy, package.limits, opts)
  end

  defp inspection_sink(event_sink, opts) do
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
                   schema_version: 2
                 ) do
            {:ok, inspection_sink, path}
          end

        if match?({:error, _reason}, result), do: EventSink.stop(event_sink)
        result

      _path ->
        EventSink.stop(event_sink)
        {:error, :invalid_inspection_path}
    end
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
