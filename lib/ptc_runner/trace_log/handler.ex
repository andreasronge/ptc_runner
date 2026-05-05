defmodule PtcRunner.TraceLog.Handler do
  @moduledoc """
  Telemetry handler that captures SubAgent events for trace logging.

  This handler attaches to all SubAgent telemetry events, builds v2 flat
  event envelopes, and forwards them to the Collector for writing to a
  JSONL file. Events are filtered by process — only events from processes
  that have an active collector in their `TraceContext` collector stack
  are captured.

  On `run.start` events, the handler extracts the full agent config from
  telemetry metadata and includes it in the event data so the Collector
  can emit a deduplicated `agent.config` event.
  """

  require Logger

  alias PtcRunner.TraceContext
  alias PtcRunner.TraceLog.{Collector, Event}

  @events [
    # SubAgent events
    [:ptc_runner, :sub_agent, :run, :start],
    [:ptc_runner, :sub_agent, :run, :stop],
    [:ptc_runner, :sub_agent, :run, :exception],
    [:ptc_runner, :sub_agent, :turn, :start],
    [:ptc_runner, :sub_agent, :turn, :stop],
    [:ptc_runner, :sub_agent, :llm, :start],
    [:ptc_runner, :sub_agent, :llm, :stop],
    [:ptc_runner, :sub_agent, :tool, :start],
    [:ptc_runner, :sub_agent, :tool, :stop],
    [:ptc_runner, :sub_agent, :tool, :exception],
    [:ptc_runner, :sub_agent, :pmap, :start],
    [:ptc_runner, :sub_agent, :pmap, :stop],
    [:ptc_runner, :sub_agent, :pcalls, :start],
    [:ptc_runner, :sub_agent, :pcalls, :stop],
    [:ptc_runner, :sub_agent, :compiled, :execute, :start],
    [:ptc_runner, :sub_agent, :compiled, :execute, :stop],
    [:ptc_runner, :sub_agent, :compiled, :execute, :exception],
    [:ptc_runner, :sub_agent, :compaction, :triggered]
  ]

  @doc """
  Returns the list of telemetry events this handler subscribes to.
  """
  @spec events() :: [list(atom())]
  def events, do: @events

  @doc """
  Attaches the handler to telemetry events.

  ## Parameters

    * `handler_id` - Unique identifier for this handler attachment
    * `collector` - The Collector process to write events to
    * `trace_id` - The trace ID for this trace session
    * `meta` - Additional metadata to include with events (optional)

  ## Examples

      Handler.attach("my-trace", collector_pid, "trace-123")
  """
  @spec attach(String.t(), pid(), String.t(), map()) :: :ok | {:error, :already_exists}
  def attach(handler_id, collector, trace_id, meta \\ %{}) do
    config = %{
      collector: collector,
      trace_id: trace_id,
      meta: meta
    }

    :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, config)
  end

  @doc """
  Detaches the handler from telemetry events.

  ## Parameters

    * `handler_id` - The handler ID that was used during attachment

  ## Examples

      Handler.detach("my-trace")
  """
  @spec detach(String.t()) :: :ok | {:error, :not_found}
  def detach(handler_id) do
    :telemetry.detach(handler_id)
  end

  @doc """
  Handles a telemetry event.

  Events are only captured if the calling process has the config's collector
  in its active `TraceContext` collector stack.

  This function never raises — errors are logged at debug level to avoid
  crashing the caller's execution.
  """
  @spec handle_event(list(atom()), map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, config) do
    config_collector = config.collector

    if config_collector in TraceContext.collectors() do
      do_handle_event(event, measurements, metadata, config)
    else
      :ok
    end
  rescue
    error ->
      Logger.debug("TraceLog handler error: #{inspect(error)}")
      :ok
  end

  # Private helpers

  defp do_handle_event(event, measurements, metadata, config) do
    # Strip telemetry_span_context — it's an Erlang reference from :telemetry.span
    # that serializes as "#Reference<...>" noise in trace files
    metadata = Map.delete(metadata, :telemetry_span_context)

    # On run.start, extract full agent config for agent.config emission
    metadata = maybe_inject_agent_config(event, metadata)

    # Build v2 flat event via Event module
    event_map =
      Event.from_telemetry(event, measurements, metadata, config.trace_id)
      |> add_span_ids(metadata)

    Collector.write_event(config.collector, event_map)
  end

  # On run.start events, extract the full agent struct into agent_config
  # so the Collector can emit a deduplicated agent.config event
  defp maybe_inject_agent_config(
         [:ptc_runner, :sub_agent, :run, :start],
         %{agent: agent} = metadata
       )
       when is_map(agent) do
    # Build agent config from the full agent struct/map
    config = build_agent_config(agent)
    Map.put(metadata, :agent_config, config)
  end

  defp maybe_inject_agent_config(_event, metadata), do: metadata

  # Extract the interesting config fields from the agent struct
  defp build_agent_config(agent) when is_struct(agent) do
    agent |> Map.from_struct() |> build_agent_config()
  end

  defp build_agent_config(agent) when is_map(agent) do
    # Include fields relevant for understanding agent behavior
    config_keys = [
      :system_prompt,
      :signature,
      :prompt,
      :output,
      :max_turns,
      :turn_budget,
      :timeout,
      :completion_mode,
      :max_depth,
      :memory_strategy,
      :thinking,
      :journaling,
      :compaction,
      :llm,
      :float_precision,
      :format_options,
      :field_descriptions,
      :schema
    ]

    config = Map.take(agent, config_keys)

    # Add tool names (not full tool definitions)
    tools = Map.get(agent, :tools, %{})

    tool_names =
      if is_map(tools), do: tools |> Map.keys() |> Enum.sort(), else: []

    Map.put(config, :tool_names, tool_names)
  end

  defp add_span_ids(event_map, metadata) do
    event_map
    |> maybe_add(metadata, :span_id, "span_id")
    |> maybe_add(metadata, :parent_span_id, "parent_span_id")
  end

  defp maybe_add(event_map, metadata, key, json_key) do
    case Map.get(metadata, key) do
      nil -> event_map
      value -> Map.put(event_map, json_key, value)
    end
  end
end
