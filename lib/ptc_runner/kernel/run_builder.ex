defmodule PtcRunner.Kernel.RunBuilder do
  @moduledoc """
  Shared path-free request construction and execution path.

  Filesystem and memory adapters first acquire a sealed
  `PtcRunner.Kernel.RunRequest`. The builder then resolves trusted provider
  names, compiles separate workflow and mission bundles, assembles their
  environments, starts the configured event sink, and produces the same
  `PtcRunner.Kernel.RunConfig` accepted by direct Elixir embedding. Relative
  artifact destinations are anchored once before preflight; the sealed
  publication authority retains them while the run configuration and outcome
  remain path-free.

  Provider-free requests cross the same path-free
  `PtcRunner.Kernel.RunCoordinator` phases 4 and 5 as command frontends, and
  downstream assembly consumes the resulting sealed `PreparedRun` directly.
  Pure option validation completes before that one-way consumption. The Mix
  one-shot path performs this assembly inside the coordinator's
  execution-session owner so the prepared run and both sinks share one
  caller-death boundary.
  A provider-bearing prepared run is preflighted the same way, and its active
  session is passed here for runtime assembly. One-shot runs open that session
  inside the execution-session owner and call `build_active_owned/7` with the
  owner's sinks, then complete through `execute_built/1`. Manifest REPLs use
  the same prepared active build, retain its one provider session behind an
  opening owner, and transfer that handle with the run state to the REPL owner.
  Provider-free REPLs keep the same owner boundary while omitting only the
  provider session.
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
  alias PtcRunner.Kernel.ArtifactPublisher
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.CommandRunRef
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
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment

  @build_options [
    :inspect,
    :installed_limits,
    :output,
    :private_output,
    :trace_path
  ]
  @artifact_options [:trace_path, :inspect, :output, :private_output]
  @opened_sink_keys [
    :attestation,
    :effective_event_policy,
    :event_identity,
    :event_sink,
    :inspection_identity,
    :inspection_sink,
    :prepared_binding,
    :publication_binding
  ]

  @type built :: %{
          required(:entry_source) => binary(),
          required(:config) => RunConfig.t(),
          required(:publication_authority) => PublicationAuthority.t(),
          required(:result_projection) => :native | :json,
          required(:build_binding) => binary()
        }

  @spec build(RunRequest.t(), ProviderRegistry.t(), keyword()) ::
          {:ok, built()}
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
          {:ok, built()}
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
         true <- PublicationAuthority.authorized?(authority),
         true <- PublicationAuthority.matches_prepared?(authority, prepared),
         :ok <- validate_sink_owner(owner),
         :ok <- PreparedRun.consume(prepared) do
      do_open_prepared_sinks(prepared, authority, owner)
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
         true <- PublicationAuthority.authorized?(authority),
         true <- PublicationAuthority.matches_prepared?(authority, prepared),
         opts = authority |> PublicationAuthority.destination_options() |> build_options(),
         :ok <- validate_build_options(opts),
         :ok <- validate_installed_limits(prepared.request.package, registry, opts),
         :ok <- validate_inspection_selection(prepared.request, opts),
         :ok <- validate_authority_inspection_selection(prepared.request, authority),
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

  defp do_open_prepared_sinks(prepared, authority, owner) do
    case event_sink(prepared.request, %{data_class: prepared.effective_data_class}, owner) do
      {:ok, event_sink} ->
        case inspection_sink_for_authority(
               event_sink,
               authority,
               :return_opened_sinks,
               owner
             ) do
          {:ok, inspection_sink} ->
            opened_sinks(prepared, authority, event_sink, inspection_sink)

          {:error, reason, opened_sinks} ->
            {:error, reason, opened_sinks}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp opened_sinks(prepared, authority, event_sink, inspection_sink) do
    with {:ok, event_identity} <- EventSink.identity(event_sink),
         {:ok, inspection_identity} <- opened_inspection_identity(inspection_sink) do
      descriptor = %{
        attestation: nil,
        event_sink: event_sink,
        inspection_sink: inspection_sink,
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
         true <- PublicationAuthority.authorized?(authority),
         true <- PublicationAuthority.matches_prepared?(authority, prepared),
         :ok <- validate_installed_limits(prepared.request.package, registry, []),
         :ok <- validate_authority_inspection_selection(prepared.request, authority),
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

  defp validate_authority_inspection_selection(request, authority) do
    if request.policy.inspection_capture ==
         PublicationAuthority.inspection_requested?(authority),
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
    bundles = {prepared.workflow_bundle, prepared.mission_bundles}

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
        {prepared.workflow_bundle, prepared.mission_bundles},
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
        {prepared.workflow_bundle, prepared.mission_bundles},
        prepared.entry_source,
        providers,
        authority,
        opened_sinks
      )
    end
  end

  defp build_provider_bearing(request, registry, opts) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    with {:ok, workflow_bundle} <-
           BundleCompiler.compile(request.package.workflow_components, deadline),
         {:ok, mission_bundles} <-
           mission_bundles(
             request.package.missions,
             deadline,
             :erlang.external_size(workflow_bundle)
           ),
         :ok <- RunCoordinator.validate_entry(workflow_bundle, request.package.entry) do
      assemble(
        request,
        {workflow_bundle, mission_bundles},
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
         :ok <-
           preflight_trace(
             request.package.events.policy,
             provider_input_class(request.input.authority),
             opts
           ),
         :ok <-
           preflight_result(
             request.package.events.policy,
             provider_input_class(request.input.authority),
             opts
           ),
         {:ok, authority} <-
           authorize_artifacts(
             request,
             opts,
             provider_input_class(request.input.authority)
           ) do
      case providers(
             request.package,
             registry,
             provider_input_class(request.input.authority),
             opts,
             nil
           ) do
        {:ok, providers} ->
          build_with_providers(
            request,
            bundles,
            entry_source,
            providers,
            [],
            failure_mode,
            {:preauthorized, authority}
          )

        {:error, _reason} = error ->
          _ = PublicationAuthority.abort(authority)
          error
      end
    end
  end

  # One environment per declared mission, each assembled from its already
  # prepared bundle and granted only the mission providers that mission named. A grant a mission did
  # not name is simply absent from its environment, so authority is enforced by
  # assembly rather than by anything the model is asked to respect.
  defp mission_environments(package, mission_bundles, providers) do
    by_occurrence = Map.get(providers.mission, :by_occurrence, %{})

    Enum.reduce_while(Map.get(package, :missions) || %{}, {:ok, %{}}, fn {name, spec},
                                                                         {:ok, acc} ->
      capabilities =
        spec.provider_occurrences
        |> Enum.flat_map(&Map.get(by_occurrence, &1, []))

      with {:ok, bundle} <- Map.fetch(mission_bundles, name),
           {:ok, environment} <-
             MissionEnvironment.new(
               bundle: bundle,
               capabilities: capabilities,
               data: spec.data
             ) do
        {:cont, {:ok, Map.put(acc, name, environment)}}
      else
        _error -> {:halt, {:error, :invalid_mission_environment}}
      end
    end)
  end

  defp mission_bundles(missions, deadline, initial_bytes) do
    case BundleCompiler.compile_named(missions, deadline, initial_bytes, 4_000_000) do
      {:ok, bundles} -> {:ok, bundles}
      {:error, {_failure, _components}} -> {:error, :invalid_mission_bundle}
    end
  end

  defp build_with_providers(
         request,
         {workflow_bundle, mission_bundles},
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
           {:ok, missions} <- mission_environments(package, mission_bundles, providers),
           {:ok, publication_authority, sink, inspection_sink} <-
             execution_sinks(request, providers, opts, failure_mode, sink_source),
           :ok <-
             capture_prelude_sources(
               inspection_sink,
               sink,
               {workflow, missions},
               package,
               failure_mode
             ) do
        build_config(
          {request, entry_source},
          providers,
          workflow,
          missions,
          {sink, inspection_sink},
          package.component_overrides,
          publication_authority,
          failure_mode
        )
      end

    case result do
      {:ok, _built} = success ->
        success

      {:error, _reason} = error ->
        cleanup = close_provider_session(providers.provider_session)

        case sink_source do
          {:preauthorized, authority} ->
            _ = PublicationAuthority.abort(authority)

          _other ->
            :ok
        end

        prefer_cleanup_error(error, cleanup)

      {:error, _reason, _opened_sinks} = error ->
        error
    end
  end

  defp build_with_opened_sinks(
         request,
         {workflow_bundle, mission_bundles},
         entry_source,
         providers,
         authority,
         opened_sinks
       ) do
    build_with_providers(
      request,
      {workflow_bundle, mission_bundles},
      entry_source,
      providers,
      [],
      :return_opened_sinks,
      {:opened_sinks, authority, opened_sinks}
    )
    |> discard_opened_sinks()
  end

  defp execution_sinks(
         request,
         providers,
         _opts,
         failure_mode,
         {:preauthorized, authority}
       ) do
    with true <- PublicationAuthority.authorized?(authority),
         {:ok, event_sink} <- event_sink(request, providers),
         {:ok, inspection_sink} <-
           inspection_sink_for_authority(event_sink, authority, failure_mode, self()) do
      {:ok, authority, event_sink, inspection_sink}
    else
      false -> {:error, :invalid_publication_authority}
      {:error, _reason} = error -> error
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
          {:ok, authority, opened_sinks.event_sink, opened_sinks.inspection_sink}
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
       when is_map(opened_sinks) and map_size(opened_sinks) == 8 do
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
           inspection_identity: nil
         },
         _expected_owner
       ),
       do: true

  defp valid_opened_inspection?(
         %{
           inspection_sink: %InspectionSink{} = inspection_sink,
           inspection_identity: identity,
           event_identity: identity
         },
         expected_owner
       ) do
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
         missions,
         {sink, inspection_sink},
         component_overrides,
         publication_authority,
         failure_mode
       ) do
    package = request.package

    case RunConfig.new(
           workflow_environment: workflow,
           missions: missions,
           input: %{"input" => request.input.value},
           limits: package.limits,
           event_sink: sink,
           result_contract: package.contracts.result,
           result_projection: request.policy.result_projection,
           inspection_sink: inspection_sink,
           provider_session: providers.provider_session,
           connector_snapshots: providers.snapshots,
           component_overrides: component_overrides,
           labels: package.labels
         ) do
      {:ok, config} ->
        case build_binding(
               config,
               publication_authority,
               entry_source,
               request.policy.result_projection
             ) do
          {:ok, build_binding} ->
            {:ok,
             %{
               entry_source: entry_source,
               config: config,
               publication_authority: publication_authority,
               result_projection: request.policy.result_projection,
               build_binding: build_binding
             }}

          {:error, _reason} = error ->
            failed_build(error, sink, inspection_sink, failure_mode)
        end

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
         {workflow, missions},
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
        Enum.reduce_while(missions, :ok, fn {name, mission}, :ok ->
          components = manifest.missions |> Map.fetch!(name) |> Map.fetch!(:components)

          case capture_bundle_sources(
                 inspection_sink,
                 "mission",
                 mission.bundle,
                 components,
                 name
               ) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        failed_build(error, sink, inspection_sink, failure_mode)
    end
  end

  defp capture_bundle_sources(inspection_sink, environment, bundle, components),
    do: capture_bundle_sources(inspection_sink, environment, bundle, components, nil)

  defp capture_bundle_sources(_inspection_sink, _environment, nil, _components, _mission_name),
    do: :ok

  defp capture_bundle_sources(inspection_sink, environment, bundle, components, mission_name) do
    sources = Map.new(components, &{&1.id, &1.source})

    Enum.reduce_while(bundle.component_ids, :ok, fn id, :ok ->
      with {:ok, source} when is_binary(source) <- Map.fetch(sources, id),
           :ok <-
             InspectionSink.emit(
               inspection_sink,
               "prelude-source",
               %{component_id: id},
               prelude_source_payload(environment, source, mission_name)
             ) do
        {:cont, :ok}
      else
        _failure -> {:halt, {:error, :inspection_sink_error}}
      end
    end)
  end

  defp prelude_source_payload(environment, source, mission_name) do
    payload = %{
      environment: environment,
      source: source,
      source_hash: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
      source_bytes: byte_size(source)
    }

    if is_binary(mission_name),
      do: Map.put(payload, :mission_name, mission_name),
      else: payload
  end

  # `acquisition` is `nil` for a direct embedding build, which opens its own
  # unbounded session and lets the registry resolve credentials synchronously.
  # An active command supplies the sealed pair acquisition plans from, the
  # session it claimed, and the credentials phase-8 step 5 resolved.
  defp providers(manifest, registry, input_class, opts, acquisition)
       when input_class in [:normal, :private_inspection] do
    if provider_free?(manifest.providers) do
      {:ok, empty_providers(input_class)}
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
  # has nothing left to authorize here. A run acquires the whole selection;
  # connectivity narrows the targets.
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

  @spec close(
          %{config: RunConfig.t(), publication_authority: PublicationAuthority.t()}
          | RunConfig.t()
        ) ::
          :ok | {:error, :provider_cleanup_failed | :publication_cleanup_failed}
  @doc "Closes a built but unexecuted configuration and its event sink."
  def close(%{config: %RunConfig{} = config, publication_authority: authority}) do
    result = close(config)
    prefer_cleanup_error(result, PublicationAuthority.abort(authority))
  end

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

  defp prefer_cleanup_error(_original, {:error, _reason} = cleanup), do: cleanup
  defp prefer_cleanup_error(original, :ok), do: original

  @doc false
  @spec execute_built(map()) :: {:ok, ExecutionOutcome.t()} | {:error, term()}
  def execute_built(
        %{
          config: %RunConfig{},
          publication_authority: authority
        } = built
      ) do
    if valid_built_binding?(built) and PublicationAuthority.valid?(authority) do
      case PublicationAuthority.claim(authority) do
        {:ok, lease} -> execute_built_claimed(built, lease)
        {:error, _reason} -> {:error, :invalid_execution_outcome}
      end
    else
      {:error, :invalid_execution_outcome}
    end
  end

  def execute_built(%{config: %RunConfig{}}), do: {:error, :invalid_execution_outcome}
  def execute_built(_built), do: {:error, :invalid_execution_outcome}

  @doc false
  @spec execute_built_claimed(map(), PublicationAuthority.lease()) ::
          {:ok, ExecutionOutcome.t()} | {:error, term()}
  def execute_built_claimed(
        %{
          entry_source: entry_source,
          config: %RunConfig{} = config,
          publication_authority: authority
        } = built,
        lease
      )
      when is_binary(entry_source) do
    if valid_built_binding?(built) and PublicationAuthority.lease_valid?(authority, lease) do
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
      {:error, :invalid_execution_outcome}
    end
  end

  def execute_built_claimed(_built, _lease), do: {:error, :invalid_execution_outcome}

  @doc false
  @spec publish_execution_report(ExecutionOutcome.t(), PublicationAuthority.t(), map()) ::
          {:ok, ArtifactPublisher.report()} | {:error, ArtifactPublisher.report()}
  def publish_execution_report(outcome, authority, fault_hooks \\ %{}) do
    with {:ok, evidence} <- ExecutionOutcome.open(outcome, authority) do
      ArtifactPublisher.publish(evidence, authority, fault_hooks)
    end
  end

  defp build_binding(config, authority, entry_source, result_projection) do
    with {:ok, event_identity} <- EventSink.identity(config.event_sink),
         {:ok, inspection_identity} <- inspection_identity(config.inspection_sink) do
      payload =
        built_binding_payload(
          config,
          authority,
          entry_source,
          result_projection,
          event_identity,
          inspection_identity
        )

      {:ok, Attestation.attest(__MODULE__, payload)}
    end
  end

  defp valid_built_binding?(%{
         entry_source: entry_source,
         config: %RunConfig{} = config,
         publication_authority: authority,
         result_projection: result_projection,
         build_binding: build_binding
       })
       when is_binary(entry_source) and is_binary(build_binding) do
    with true <- result_projection == config.result_projection,
         {:ok, event_identity} <- EventSink.identity(config.event_sink),
         {:ok, inspection_identity} <- inspection_identity(config.inspection_sink) do
      Attestation.valid?(
        __MODULE__,
        built_binding_payload(
          config,
          authority,
          entry_source,
          result_projection,
          event_identity,
          inspection_identity
        ),
        build_binding
      )
    else
      _other -> false
    end
  rescue
    _exception -> false
  end

  defp valid_built_binding?(_built), do: false

  defp built_binding_payload(
         config,
         authority,
         entry_source,
         result_projection,
         event_identity,
         inspection_identity
       ) do
    {
      PublicationAuthority.binding(authority),
      config,
      event_identity,
      inspection_identity,
      :crypto.hash(:sha256, entry_source),
      result_projection
    }
  end

  defp inspection_identity(nil), do: {:ok, nil}
  defp inspection_identity(inspection_sink), do: InspectionSink.identity(inspection_sink)

  defp stop_execution_sinks(%RunConfig{} = config) do
    if config.inspection_sink, do: InspectionSink.stop(config.inspection_sink)
    if Process.alive?(config.event_sink.pid), do: EventSink.stop(config.event_sink)
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
    case opts |> publication_options() |> PublicationAuthority.validate_distinct_destinations() do
      :ok ->
        :ok

      {:error, {:conflicting_destinations, _keys}} ->
        {:error, {:artifact_preflight_failed, :conflicting_destinations}}
    end
  end

  defp preflight_trace(event_policy, provider_class, opts) do
    case Keyword.get(opts, :trace_path) do
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

  defp provider_input_class(:normal), do: :normal
  defp provider_input_class(:private), do: :private_inspection

  defp authorize_artifacts(request, opts, provider_class) do
    artifact_opts = opts |> Keyword.take(@artifact_options) |> publication_options()

    if artifact_opts == [] do
      PublicationAuthority.new([])
    else
      with {:ok, run_ref} <- authorization_run_ref(request) do
        PublicationAuthority.authorize(
          run_ref,
          artifact_opts,
          request.policy.event_policy,
          provider_class
        )
      end
    end
  end

  defp authorization_run_ref(_request), do: CommandRunRef.generate()

  defp publication_options(opts) do
    case Keyword.pop(opts, :trace_path) do
      {nil, opts} -> opts
      {path, opts} -> Keyword.put(opts, :trace, path)
    end
  end

  defp build_options(opts) do
    case Keyword.pop(opts, :trace) do
      {nil, opts} -> opts
      {path, opts} -> Keyword.put(opts, :trace_path, path)
    end
  end

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

  defp provider_free?(%{workflow: [], mission: []}), do: true
  defp provider_free?(_providers), do: false

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

  defp inspection_sink_for_authority(event_sink, authority, failure_mode, owner) do
    if PublicationAuthority.inspection_requested?(authority) do
      result =
        with {:ok, identity} <- EventSink.identity(event_sink) do
          InspectionSink.start(
            run_id: identity.run_id,
            trace_id: identity.trace_id,
            schema_version: 4,
            owner: owner
          )
        end

      case result do
        {:ok, _inspection_sink} = success -> success
        {:error, _reason} = error -> failed_build(error, event_sink, nil, failure_mode)
      end
    else
      {:ok, nil}
    end
  end

  defp failed_build({:error, reason}, event_sink, inspection_sink, :return_opened_sinks),
    do: {:error, reason, %{event_sink: event_sink, inspection_sink: inspection_sink}}

  defp failed_build(error, event_sink, inspection_sink, :close_opened_sinks) do
    if inspection_sink, do: InspectionSink.stop(inspection_sink)
    EventSink.stop(event_sink)
    error
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
