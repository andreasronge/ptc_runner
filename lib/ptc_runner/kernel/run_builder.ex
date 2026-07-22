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
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment

  @spec build(Manifest.t(), ProviderRegistry.t(), keyword()) ::
          {:ok, %{entry_source: binary(), config: RunConfig.t()}} | {:error, term()}
  @doc "Builds an entry expression and complete run configuration from a loaded manifest."
  def build(manifest, registry, opts \\ [])

  def build(%Manifest{} = manifest, %ProviderRegistry{} = registry, opts) when is_list(opts) do
    case providers(manifest, registry) do
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
           {:ok, sink} <- event_sink(manifest),
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
        close_resources(providers.resources)
        error
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

  defp providers(manifest, registry) do
    case capabilities(manifest, registry, :workflow) do
      {:ok, workflow} ->
        case capabilities(manifest, registry, :mission) do
          {:ok, mission} ->
            {:ok,
             %{
               workflow: workflow,
               mission: mission,
               resources: mission.resources ++ workflow.resources,
               snapshots: sort_snapshots(workflow.snapshots ++ mission.snapshots)
             }}

          {:error, _reason} = error ->
            close_resources(workflow.resources)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp sort_snapshots(snapshots), do: Enum.sort_by(snapshots, &Map.get(&1, "provider", ""))

  @spec close(%{config: RunConfig.t()} | RunConfig.t()) :: :ok
  @doc "Closes a built but unexecuted configuration and its event sink."
  def close(%{config: %RunConfig{} = config}), do: close(config)

  def close(%RunConfig{} = config) do
    RunConfig.close_provider_resources(config)
    if config.inspection_sink, do: InspectionSink.stop(config.inspection_sink)

    if Process.alive?(config.event_sink.pid), do: EventSink.stop(config.event_sink)
    :ok
  end

  defp close_resources(resources) do
    Enum.each(resources, fn close ->
      try do
        _ = close.()
      rescue
        _exception -> :ok
      catch
        _kind, _reason -> :ok
      end
    end)

    :ok
  end

  # Provider resources are already closed by `Kernel.run_and_events/2`; the
  # returned terminal batch is the sole input to both persistence paths.
  defp execute_built(built, opts) do
    {result, terminal_batch} = Kernel.run_and_events(built.entry_source, built.config)

    case terminal_batch do
      {:ok, events} ->
        with :ok <- persist_trace(Keyword.get(opts, :trace), built.config.event_sink, events),
             :ok <- persist_inspection(built.config, events) do
          result
        else
          {:error, {:trace, reason}} ->
            {:error, {:trace_persistence_failed, reason, result}}

          {:error, {:inspection, reason}} ->
            {:error, {:inspection_persistence_failed, reason, result}}
        end

      {:error, _reason} ->
        result
    end
  end

  @spec load_and_build(binary(), ProviderRegistry.t()) ::
          {:ok, %{entry_source: binary(), config: RunConfig.t()}} | {:error, term()}
  @doc """
  Loads a manifest and builds its run.

  The optional `:mission` path replaces the manifest input using the same
  manifest-relative confinement rules. The name is retained from the CLI
  option; it changes top-level workflow input, not mission-environment data.
  """
  def load_and_build(path, registry, opts \\ []) do
    installed_limits = Keyword.get(opts, :installed_limits, Limits.installed_defaults())

    with {:ok, manifest} <- Manifest.load(path, installed_limits),
         {:ok, manifest} <- maybe_override_input(manifest, opts),
         :ok <- preflight_inspection(opts),
         do: build(manifest, registry, opts)
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
    with {:ok, built} <- load_and_build(path, registry, opts) do
      try do
        execute_built(built, opts)
      after
        if built.config.inspection_sink, do: InspectionSink.stop(built.config.inspection_sink)

        if Process.alive?(built.config.event_sink.pid),
          do: EventSink.stop(built.config.event_sink)
      end
    end
  end

  defp maybe_override_input(manifest, opts) do
    case Keyword.get(opts, :mission) do
      nil -> {:ok, manifest}
      path -> Manifest.override_input(manifest, path)
    end
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

  defp capabilities(manifest, registry, destination) do
    manifest.providers
    |> Map.fetch!(destination)
    |> Enum.reduce_while(
      {:ok, %{capabilities: [], snapshots: [], resources: []}},
      fn spec, {:ok, accumulated} ->
        context = %{
          directory: manifest.directory,
          destination: destination,
          owner: self(),
          limits: manifest.limits,
          installed_limits: manifest.installed_limits
        }

        case ProviderRegistry.build(
               registry,
               spec["name"],
               Map.get(spec, "config", %{}),
               context
             ) do
          {:ok, built} ->
            next = %{
              capabilities: accumulated.capabilities ++ built.capabilities,
              snapshots: maybe_append(accumulated.snapshots, built.snapshot),
              resources: maybe_prepend(accumulated.resources, built.close)
            }

            {:cont, {:ok, next}}

          {:error, _reason} = error ->
            close_resources(accumulated.resources)
            {:halt, error}
        end
      end
    )
  end

  defp maybe_append(values, nil), do: values
  defp maybe_append(values, value), do: values ++ [value]
  defp maybe_prepend(values, nil), do: values
  defp maybe_prepend(values, value), do: [value | values]

  defp bundle([]), do: {:ok, nil}
  defp bundle(components), do: Kernel.compile_bundle(components)

  defp event_sink(manifest) do
    opts =
      []
      |> maybe_put(:run_id, manifest.events.run_id)
      |> maybe_put(:trace_id, manifest.events.trace_id)

    EventSink.start(manifest.events.policy, manifest.limits, opts)
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
                   trace_id: identity.trace_id
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
