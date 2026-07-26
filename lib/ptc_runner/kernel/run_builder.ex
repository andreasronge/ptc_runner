defmodule PtcRunner.Kernel.RunBuilder do
  @moduledoc """
  Shared manifest-backed construction and execution path.

  The builder resolves trusted provider names, compiles separate workflow and
  mission bundles, assembles their environments, starts the configured event
  sink, and produces the same `PtcRunner.Kernel.RunConfig` accepted by direct
  Elixir embedding. Frontends should delegate here instead of creating a
  second manifest, authority, or event path.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderResources
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment

  @spec build(Manifest.t(), ProviderRegistry.t(), keyword()) ::
          {:ok, %{entry_source: binary(), config: RunConfig.t()}} | {:error, term()}
  @doc "Builds an entry expression and complete run configuration from a loaded manifest."
  def build(manifest, registry, opts \\ [])

  def build(%Manifest{} = manifest, %ProviderRegistry{} = registry, opts) when is_list(opts) do
    input_class = Keyword.get(opts, :input_class, :normal)

    case providers(manifest, registry, input_class) do
      {:ok, providers} -> build_with_providers(manifest, providers, opts)
      {:error, _reason} = error -> error
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
          inspection_path
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
         inspection_path
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
           labels: manifest.labels
         ) do
      {:ok, config} ->
        {:ok, %{entry_source: "(#{manifest.entry} data/input)", config: config}}

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

  defp providers(manifest, registry, input_class)
       when input_class in [:normal, :private_inspection] do
    with {:ok, prepared} <- prepare_providers(manifest, registry),
         effective_class <- effective_data_class(input_class, prepared),
         :ok <- providers_accept(prepared, effective_class),
         {:ok, preflighted} <- preflight_providers(prepared),
         {:ok, credentials} <-
           ProviderRegistry.resolve_credentials(registry, credential_names(prepared)),
         {:ok, acquired} <- acquire_providers(preflighted, credentials, effective_class) do
      {:ok, %{acquired | snapshots: sort_snapshots(acquired.snapshots)}}
    end
  end

  defp providers(_manifest, _registry, _input_class), do: {:error, :invalid_input_class}

  defp sort_snapshots(snapshots), do: Enum.sort_by(snapshots, &Map.get(&1, "provider", ""))

  defp prepare_providers(manifest, registry) do
    manifest
    |> provider_specs()
    |> Enum.reduce_while({:ok, []}, fn {destination, spec}, {:ok, prepared} ->
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
            destination: destination,
            credential_names: provider.credential_names,
            data_class: provider.data_class,
            accepts_data: provider.accepts_data,
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
      data_class: effective_class
    }

    Enum.reduce_while(preflighted, {:ok, initial}, fn provider, {:ok, accumulated} ->
      provider_credentials = Map.take(credentials, provider.credential_names)

      case ProviderRegistry.acquire(provider.preflighted, provider_credentials) do
        {:ok, built}
        when built.data_class == provider.data_class and
               built.accepts_data == provider.accepts_data ->
          environment = Map.fetch!(accumulated, provider.destination)

          next =
            accumulated
            |> Map.put(provider.destination, %{
              capabilities: environment.capabilities ++ built.capabilities
            })
            |> Map.update!(:snapshots, &maybe_append(&1, built.snapshot))
            |> Map.update!(:resources, &maybe_prepend(&1, built.close))

          {:cont, {:ok, next}}

        {:ok, built} ->
          result =
            prefer_cleanup_error(
              {:error, :provider_data_policy_changed},
              close_resources(maybe_prepend(accumulated.resources, built.close))
            )

          {:halt, result}

        {:error, _reason} = error ->
          result = prefer_cleanup_error(error, close_resources(accumulated.resources))
          {:halt, result}
      end
    end)
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

    case terminal_batch do
      {:ok, events} ->
        with :ok <- persist_trace(Keyword.get(opts, :trace), built.config.event_sink, events),
             :ok <- persist_inspection(built.config, events),
             :ok <- persist_result(result, built.config.event_sink, opts) do
          result
        else
          {:error, {stage, reason}} ->
            {:error,
             {persistence_failure(stage), reason, disclosable(result, built.config.event_sink)}}
        end

      {:error, _reason} ->
        result
    end
  end

  @spec load_and_build(binary(), ProviderRegistry.t()) ::
          {:ok, %{entry_source: binary(), config: RunConfig.t()}} | {:error, term()}
  @doc """
  Loads a manifest and builds its run.

  The optional `:mission` or `:private_mission` path replaces the manifest
  input using the same manifest-relative confinement rules. They are mutually
  exclusive. A private mission marks the complete run value private before
  provider preflight or acquisition. The option names refer to CLI input
  authority; they change top-level workflow input, not mission-environment
  data.
  """
  def load_and_build(path, registry, opts \\ []) do
    installed_limits = Keyword.get(opts, :installed_limits, Limits.installed_defaults())

    with {:ok, manifest} <- Manifest.load(path, installed_limits),
         {:ok, manifest, input_class} <- maybe_override_input(manifest, opts),
         :ok <- preflight_inspection(opts),
         do: build(manifest, registry, Keyword.put(opts, :input_class, input_class))
  end

  # A deterministic destination conflict is reported after manifest and input
  # validation (so a bad output path never masks a more useful error) but
  # before provider builders — including MCP discovery — or model calls run.
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
    with {:ok, built} <- load_and_build(path, registry, opts) do
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
  defp disclosable({:ok, %Result{} = result}, sink) do
    case result_class(sink) do
      :private -> {:ok, %Result{result | value: :redacted}}
      :normal -> {:ok, result}
    end
  end

  defp disclosable(result, _sink), do: result

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
          with {:ok, identity} <- EventSink.identity(event_sink),
               {:ok, inspection_sink} <-
                 InspectionSink.start(
                   run_id: identity.run_id,
                   trace_id: identity.trace_id,
                   schema_version: 2
                 ) do
            {:ok, inspection_sink, Path.expand(path)}
          end

        if match?({:error, _reason}, result), do: EventSink.stop(event_sink)
        result

      _path ->
        EventSink.stop(event_sink)
        {:error, :invalid_inspection_path}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
