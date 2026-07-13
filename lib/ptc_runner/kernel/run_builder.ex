defmodule PtcRunner.Kernel.RunBuilder do
  @moduledoc "Builds and runs the one shared Kernel configuration from a V1 manifest."

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
  def build(%Manifest{} = manifest, %ProviderRegistry{} = registry) do
    with {:ok, workflow_capabilities} <- capabilities(manifest, registry, :workflow),
         {:ok, mission_capabilities} <- capabilities(manifest, registry, :mission),
         {:ok, workflow_bundle} <- bundle(manifest.workflow_components),
         {:ok, mission_bundle} <- bundle(manifest.mission_components),
         {:ok, workflow} <-
           WorkflowEnvironment.new(
             bundle: workflow_bundle,
             capabilities: workflow_capabilities
           ),
         {:ok, mission} <-
           MissionEnvironment.new(
             bundle: mission_bundle,
             capabilities: mission_capabilities,
             data: manifest.mission_data
           ),
         {:ok, sink} <- event_sink(manifest),
         {:ok, config} <-
           RunConfig.new(
             workflow_environment: workflow,
             mission_environment: mission,
             input: %{"input" => manifest.input},
             limits: manifest.limits,
             event_sink: sink,
             labels: manifest.labels
           ) do
      {:ok, %{entry_source: "(#{manifest.entry} data/input)", config: config}}
    end
  end

  @spec load_and_build(binary(), ProviderRegistry.t()) ::
          {:ok, %{entry_source: binary(), config: RunConfig.t()}} | {:error, term()}
  def load_and_build(path, registry, opts \\ []) do
    with {:ok, manifest} <- Manifest.load(path),
         {:ok, manifest} <- maybe_override_input(manifest, opts),
         do: build(manifest, registry)
  end

  @spec run(binary(), ProviderRegistry.t()) :: {:ok, term()} | {:error, term()}
  def run(path, registry, opts \\ []) do
    with {:ok, built} <- load_and_build(path, registry, opts) do
      try do
        result = Kernel.run(built.entry_source, built.config)

        case persist_trace(Keyword.get(opts, :trace), built.config.event_sink) do
          :ok -> result
          {:error, reason} -> {:error, {:trace_persistence_failed, reason, result}}
        end
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
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, capabilities} ->
      context = %{directory: manifest.directory, destination: destination}

      case ProviderRegistry.build(registry, spec["name"], Map.get(spec, "config", %{}), context) do
        {:ok, capability} -> {:cont, {:ok, [capability | capabilities]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, capabilities} -> {:ok, Enum.reverse(capabilities)}
      error -> error
    end
  end

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
