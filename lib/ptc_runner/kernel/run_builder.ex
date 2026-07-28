defmodule PtcRunner.Kernel.RunBuilder do
  @moduledoc """
  Shared manifest-backed construction and execution path.

  The builder resolves trusted provider names, compiles separate workflow and
  mission bundles, assembles their environments, starts the configured event
  sink, and produces the same `PtcRunner.Kernel.RunConfig` accepted by direct
  Elixir embedding. Frontends should delegate here instead of creating a
  second manifest, authority, or event path. Relative artifact destinations are
  anchored once before preflight and the same absolute paths are retained
  through post-run persistence.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderResources
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.WorkflowEnvironment

  @spec build(Manifest.t(), ProviderRegistry.t(), keyword()) ::
          {:ok,
           %{
             entry_source: binary(),
             config: RunConfig.t(),
             result_contract: ValueContract.t() | nil
           }}
          | {:error, term()}
  @doc "Builds an entry expression and complete run configuration from a loaded manifest."
  def build(manifest, registry, opts \\ [])

  def build(%Manifest{} = manifest, %ProviderRegistry{} = registry, opts) when is_list(opts) do
    with {:ok, opts} <- anchor_artifact_options(opts),
         :ok <- preflight_inspection(opts),
         :ok <- preflight_artifact_destinations(opts) do
      input_class = Keyword.get(opts, :input_class, :normal)

      case providers(manifest, registry, input_class, opts) do
        {:ok, providers} -> build_with_providers(manifest, providers, opts)
        {:error, _reason} = error -> error
      end
    end
  end

  defp build_with_providers(manifest, providers, opts) do
    result =
      with {:ok, workflow_bundle} <- bundle(manifest.workflow_components),
           {:ok, mission_bundle} <- bundle(manifest.mission_components),
           {:ok, workflow} <-
             WorkflowEnvironment.new(
               bundle: workflow_bundle,
               capabilities: providers.workflow.capabilities
             ),
           {:ok, mission} <-
             MissionEnvironment.new(
               bundle: mission_bundle,
               capabilities: providers.mission.capabilities,
               data: manifest.mission_data
             ),
           {:ok, sink} <- event_sink(manifest, providers),
           {:ok, inspection_sink, inspection_path} <- inspection_sink(sink, opts),
           :ok <- capture_prelude_sources(inspection_sink, sink, {workflow, mission}, manifest) do
        build_config(
          manifest,
          providers,
          workflow,
          mission,
          sink,
          inspection_sink,
          inspection_path,
          Keyword.get(opts, :component_overrides, [])
        )
      end

    case result do
      {:ok, _built} = success ->
        success

      {:error, _reason} = error ->
        prefer_cleanup_error(error, close_resources(providers.resources))
    end
  end

  defp build_config(
         manifest,
         providers,
         workflow,
         mission,
         sink,
         inspection_sink,
         inspection_path,
         component_overrides
       ) do
    case RunConfig.new(
           workflow_environment: workflow,
           mission_environment: mission,
           input: %{"input" => manifest.input},
           limits: manifest.limits,
           event_sink: sink,
           inspection_sink: inspection_sink,
           inspection_path: inspection_path,
           provider_resources: providers.resources,
           connector_snapshots: providers.snapshots,
           component_overrides: component_overrides,
           labels: manifest.labels
         ) do
      {:ok, config} ->
        {:ok,
         %{
           entry_source: "(#{manifest.entry} data/input)",
           config: config,
           result_contract: manifest.contracts.result
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

  defp providers(manifest, registry, input_class, opts)
       when input_class in [:normal, :private_inspection] do
    with {:ok, prepared} <- prepare_providers(manifest, registry),
         :ok <- validate_provider_dependencies(prepared),
         :ok <- validate_single_workflow_llm(prepared),
         effective_class <- effective_data_class(input_class, prepared),
         :ok <- providers_accept(prepared, effective_class),
         :ok <- preflight_trace(manifest.events.policy, effective_class, opts),
         :ok <- preflight_result(manifest.events.policy, effective_class, opts),
         {:ok, preflighted} <- preflight_providers(prepared),
         {:ok, credentials} <-
           ProviderRegistry.resolve_credentials(registry, credential_names(prepared)),
         {:ok, acquired} <- acquire_providers(preflighted, credentials, effective_class) do
      {:ok,
       %{
         acquired
         | workflow: finalize_capabilities(acquired.workflow),
           mission: finalize_capabilities(acquired.mission),
           snapshots: sort_snapshots(acquired.snapshots)
       }
       |> Map.delete(:exports)}
    end
  end

  defp providers(_manifest, _registry, _input_class, _opts), do: {:error, :invalid_input_class}

  defp sort_snapshots(snapshots), do: Enum.sort_by(snapshots, &Map.get(&1, "provider", ""))

  defp prepare_providers(manifest, registry) do
    manifest
    |> provider_specs()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{destination, spec}, index}, {:ok, prepared} ->
      context = %{
        directory: manifest.directory,
        destination: destination,
        owner: self(),
        limits: manifest.limits,
        installed_limits: manifest.installed_limits
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
            prepared: provider
          }

          {:cont, {:ok, [entry | prepared]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> reverse_success()
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
          {:halt, error}
      end
    end)
    |> reverse_success()
  end

  defp acquire_providers(preflighted, credentials, effective_class) do
    initial = %{
      workflow: %{capabilities: []},
      mission: %{capabilities: []},
      resources: [],
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
        prefer_cleanup_error(
          {:error, :provider_dependency_unavailable},
          close_resources(accumulated.resources)
        )

      {ready, blocked} ->
        case acquire_provider_batch(ready, credentials, accumulated) do
          {:ok, next} -> acquire_ready_providers(blocked, credentials, next)
          {:error, _reason} = error -> error
        end
    end
  end

  defp acquire_provider_batch(providers, credentials, accumulated) do
    Enum.reduce_while(providers, {:ok, accumulated}, fn provider, {:ok, current} ->
      provider_credentials = Map.take(credentials, provider.credential_names)
      services = selected_services(current.exports, provider.requires)

      case ProviderRegistry.acquire(provider.preflighted, provider_credentials, services) do
        {:ok, built}
        when built.data_class == provider.data_class and
               built.accepts_data == provider.accepts_data ->
          environment = Map.fetch!(current, provider.destination)

          next =
            current
            |> Map.put(provider.destination, %{
              capabilities: [{provider.index, built.capabilities} | environment.capabilities]
            })
            |> Map.update!(:snapshots, &maybe_append(&1, built.snapshot))
            |> Map.update!(:resources, &maybe_prepend(&1, built.close))
            |> Map.update!(
              :exports,
              &merge_provider_exports(&1, provider.provider, built.exports)
            )

          {:cont, {:ok, next}}

        {:ok, built} ->
          result =
            prefer_cleanup_error(
              {:error, :provider_data_policy_changed},
              close_resources(maybe_prepend(current.resources, built.close))
            )

          {:halt, result}

        {:error, _reason} = error ->
          result = prefer_cleanup_error(error, close_resources(current.resources))
          {:halt, result}
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
    result = RunConfig.close_provider_resources(config)
    if config.inspection_sink, do: InspectionSink.stop(config.inspection_sink)

    if Process.alive?(config.event_sink.pid), do: EventSink.stop(config.event_sink)
    result
  end

  defp close_resources(resources), do: ProviderResources.close(resources)

  defp prefer_cleanup_error(_original, {:error, :provider_cleanup_failed} = cleanup), do: cleanup
  defp prefer_cleanup_error(original, :ok), do: original

  # Provider resources are already closed by `Kernel.run_and_events/2`; the
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
             result_contract: ValueContract.t() | nil
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
    installed_limits = Keyword.get(opts, :installed_limits, registry.installed_limits)

    with {:ok, manifest} <- Manifest.load(path, installed_limits),
         {:ok, manifest, input_class} <- maybe_override_input(manifest, opts),
         {:ok, manifest, override} <- maybe_override_component(manifest, opts),
         {:ok, opts} <- anchor_artifact_options(opts),
         {:ok, built} <-
           build(
             manifest,
             registry,
             opts
             |> Keyword.put(:input_class, input_class)
             |> Keyword.put(:component_overrides, List.wrap(override))
           ) do
      {:ok, built, opts}
    end
  end

  defp anchor_artifact_options(opts) do
    case artifact_anchor_cwd(opts) do
      {:ok, cwd} ->
        anchor_artifact_options([:trace, :inspect, :output, :private_output], opts, cwd)

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
      Enum.any?([:trace, :inspect, :output, :private_output], fn key ->
        case Keyword.fetch(opts, key) do
          {:ok, path} when is_binary(path) -> Path.type(path) == :relative
          _missing_or_invalid -> false
        end
      end)

    if relative?, do: File.cwd(), else: {:ok, nil}
  end

  defp invalid_artifact_destination,
    do: {:error, {:artifact_preflight_failed, :invalid_destination}}

  # Applied after the manifest is loaded and before any bundle is compiled, so
  # the candidate goes through the same dependency, export, signature, and
  # capability validation as the source it replaces. An override changes which
  # source compiles, never what compilation permits.
  #
  # The candidate reaches the run only here. It is never manifest input and
  # never mission data, so a generated program cannot introduce or observe one.
  defp maybe_override_component(%Manifest{} = manifest, opts) do
    case Keyword.get(opts, :component_override_descriptor) do
      nil ->
        {:ok, manifest, nil}

      path ->
        with {:ok, override} <- ComponentOverride.load(path),
             {:ok, workflow, workflow_applied?} <-
               ComponentOverride.apply(manifest.workflow_components, override),
             {:ok, mission, mission_applied?} <-
               ComponentOverride.apply(manifest.mission_components, override),
             :ok <- exactly_one_target(workflow_applied?, mission_applied?) do
          {:ok, %Manifest{manifest | workflow_components: workflow, mission_components: mission},
           ComponentOverride.identity(override)}
        end
    end
  end

  # The descriptor names one component, so it must resolve to one. The same ID
  # can legitimately be selected into both environments, and replacing both
  # from a single descriptor would evaluate a candidate in a place the operator
  # never named.
  defp exactly_one_target(true, true), do: {:error, :ambiguous_override_target}
  defp exactly_one_target(false, false), do: {:error, :override_component_not_selected}
  defp exactly_one_target(_workflow, _mission), do: :ok

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
      [:trace, :inspect, :output, :private_output]
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

  defp maybe_override_input(manifest, opts) do
    case {Keyword.get(opts, :mission), Keyword.get(opts, :private_mission)} do
      {nil, nil} ->
        {:ok, manifest, :normal}

      {path, nil} when is_binary(path) ->
        with {:ok, manifest} <- Manifest.override_input(manifest, path),
             do: {:ok, manifest, :normal}

      {nil, path} when is_binary(path) ->
        with {:ok, manifest} <- Manifest.override_input(manifest, path),
             do: {:ok, manifest, :private_inspection}

      {path, private} when is_binary(path) and is_binary(private) ->
        {:error, :conflicting_mission_inputs}

      _invalid ->
        {:error, :invalid_input}
    end
  end

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
    public = public_value(value)

    if ValueContract.valid?(contract, public),
      do: :ok,
      else: {:error, {:result_contract_failed, ValueContract.classify(contract, public)}}
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
        case ResultArtifact.persist(path, public_value(result.value), class, destination) do
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

  defp public_value(value) when is_struct(value),
    do: value |> Map.from_struct() |> public_value()

  defp public_value(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, public_value(nested)} end)

  defp public_value(value) when is_list(value), do: Enum.map(value, &public_value/1)
  defp public_value(value), do: value

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
  defp maybe_prepend(values, nil), do: values
  defp maybe_prepend(values, value), do: [value | values]

  defp bundle([]), do: {:ok, nil}
  defp bundle(components), do: Kernel.compile_bundle(components)

  defp event_sink(manifest, providers) do
    opts =
      []
      |> maybe_put(:run_id, manifest.events.run_id)
      |> maybe_put(:trace_id, manifest.events.trace_id)

    policy =
      if manifest.events.policy == :private or providers.data_class == :private_inspection,
        do: :private,
        else: :normal

    EventSink.start(policy, manifest.limits, opts)
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
