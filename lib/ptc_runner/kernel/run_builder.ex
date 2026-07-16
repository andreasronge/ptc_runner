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
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment

  @spec build(Manifest.t(), ProviderRegistry.t()) ::
          {:ok, %{entry_source: binary(), config: RunConfig.t()}} | {:error, term()}
  @doc "Builds an entry expression and complete run configuration from a loaded manifest."
  def build(%Manifest{} = manifest, %ProviderRegistry{} = registry) do
    case providers(manifest, registry) do
      {:ok, providers} -> build_with_providers(manifest, providers)
      {:error, _reason} = error -> error
    end
  end

  defp build_with_providers(manifest, providers) do
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
           {:ok, sink} <- event_sink(manifest) do
        build_config(manifest, providers, workflow, mission, sink)
      end

    case result do
      {:ok, _built} = success ->
        success

      {:error, _reason} = error ->
        close_resources(providers.resources)
        error
    end
  end

  defp build_config(manifest, providers, workflow, mission, sink) do
    case RunConfig.new(
           workflow_environment: workflow,
           mission_environment: mission,
           input: %{"input" => manifest.input},
           limits: manifest.limits,
           event_sink: sink,
           provider_resources: providers.resources,
           connector_snapshots: providers.snapshots,
           labels: manifest.labels
         ) do
      {:ok, config} ->
        {:ok, %{entry_source: "(#{manifest.entry} data/input)", config: config}}

      {:error, _reason} = error ->
        EventSink.stop(sink)
        error
    end
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

  # Provider resources are already closed by `Kernel.run/2`; the event sink
  # remains live long enough for optional post-run canonical trace persistence.
  defp execute_built(built, opts) do
    result = Kernel.run(built.entry_source, built.config)

    case persist_trace(Keyword.get(opts, :trace), built.config.event_sink) do
      :ok -> result
      {:error, reason} -> {:error, {:trace_persistence_failed, reason, result}}
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
    with {:ok, manifest} <- Manifest.load(path),
         {:ok, manifest} <- maybe_override_input(manifest, opts),
         do: build(manifest, registry)
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

  defp persist_trace(nil, _sink), do: :ok

  defp persist_trace(path, sink) when is_binary(path) do
    private? = EventSink.policy(sink) == :private
    TraceLog.append_jsonl(path, EventSink.events(sink), private: private?)
  end

  defp persist_trace(_path, _sink), do: {:error, :invalid_trace_log}

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
          limits: manifest.limits
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
