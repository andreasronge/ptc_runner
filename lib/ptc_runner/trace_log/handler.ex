defmodule PtcRunner.TraceLog.Handler do
  @moduledoc """
  Telemetry handler that captures SubAgent events for trace logging.

  This handler attaches to all SubAgent telemetry events and forwards them
  to the Collector for writing to a JSONL file. Events are filtered by
  process - only events from processes that have an active collector in
  their collector stack (`:ptc_trace_collectors`) are captured.

  Nested traces are supported - events are captured by all active collectors
  in the stack.
  """

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
    # PlanExecutor events
    [:ptc_runner, :plan_executor, :plan, :generated],
    [:ptc_runner, :plan_executor, :execution, :start],
    [:ptc_runner, :plan_executor, :execution, :stop],
    [:ptc_runner, :plan_executor, :task, :start],
    [:ptc_runner, :plan_executor, :task, :stop],
    [:ptc_runner, :plan_executor, :replan, :start],
    [:ptc_runner, :plan_executor, :replan, :stop]
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
  in its active collector stack (`:ptc_trace_collectors`).

  This function never raises - errors are silently ignored to avoid
  crashing the caller's execution.
  """
  @spec handle_event(list(atom()), map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, config) do
    collectors = Process.get(:ptc_trace_collectors, [])
    config_collector = config.collector

    if config_collector in collectors do
      do_handle_event(event, measurements, metadata, config)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  # Private helpers

  defp do_handle_event(event, measurements, metadata, config) do
    event_map =
      Event.from_telemetry(event, measurements, metadata, config.trace_id)
      |> add_duration_ms(measurements)
      |> add_span_ids(metadata)

    Collector.write_event(config.collector, event_map)
  end

  defp add_duration_ms(event_map, %{duration: duration}) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    Map.put(event_map, "duration_ms", duration_ms)
  end

  defp add_duration_ms(event_map, _measurements), do: event_map

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
