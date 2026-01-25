defmodule PtcRunner.SubAgent.Telemetry do
  @moduledoc """
  Telemetry event emission for SubAgent execution.

  This module provides helpers for emitting telemetry events during SubAgent
  execution, enabling integration with observability tools like Prometheus,
  OpenTelemetry, and custom handlers.

  ## Events

  All events are prefixed with `[:ptc_runner, :sub_agent]`.

  | Event | Measurements | Metadata |
  |-------|--------------|----------|
  | `[:run, :start]` | `%{}` | agent, context, span_id, parent_span_id |
  | `[:run, :stop]` | `%{duration: native_time}` | agent, step, status, span_id, parent_span_id |
  | `[:run, :exception]` | `%{duration: native_time}` | agent, kind, reason, stacktrace, span_id, parent_span_id |
  | `[:turn, :start]` | `%{}` | agent, turn, span_id, parent_span_id |
  | `[:turn, :stop]` | `%{duration: native_time, tokens: n}` | agent, turn, program, result_preview, type, span_id, parent_span_id |
  | `[:llm, :start]` | `%{}` | agent, turn, messages, span_id, parent_span_id |
  | `[:llm, :stop]` | `%{duration: native_time, tokens: n}` | agent, turn, response, span_id, parent_span_id |
  | `[:tool, :start]` | `%{}` | agent, tool_name, args, span_id, parent_span_id |
  | `[:tool, :stop]` | `%{duration: native_time}` | agent, tool_name, result, span_id, parent_span_id |
  | `[:tool, :exception]` | `%{duration: native_time}` | agent, tool_name, kind, reason, stacktrace, span_id, parent_span_id |

  ## Span Correlation

  All events include `span_id` and `parent_span_id` for correlation:
  - `span_id` - 8-character hex string, unique per span
  - `parent_span_id` - The span_id of the parent span, or `nil` for root spans

  Nested spans maintain a parent-child hierarchy. For example, a tool call within
  a turn will have the turn's span_id as its parent_span_id.

  ## Usage

  Attach handlers using `:telemetry.attach_many/4`:

      :telemetry.attach_many(
        "my-handler",
        [
          [:ptc_runner, :sub_agent, :run, :stop],
          [:ptc_runner, :sub_agent, :tool, :stop]
        ],
        &MyApp.Telemetry.handle_event/4,
        nil
      )

  ## Duration

  Duration measurements use native time units via `System.monotonic_time/0`.
  Convert to milliseconds with `System.convert_time_unit(duration, :native, :millisecond)`.
  """

  @prefix [:ptc_runner, :sub_agent]
  @span_stack_key :ptc_telemetry_span_stack

  @doc """
  Execute a function within a telemetry span.

  Emits `:start`, `:stop`, and `:exception` events automatically.
  The start metadata is passed as-is. The stop metadata receives
  any additional measurements or metadata returned from the function.

  All events include `span_id` and `parent_span_id` for correlation.

  ## Parameters

  - `event_suffix` - List of atoms to append to the prefix (e.g., `[:run]`)
  - `start_meta` - Metadata map for the start event
  - `fun` - Zero-arity function to execute. Should return one of:
    - `{result, stop_meta}` - where `stop_meta` is merged into stop event metadata
    - `{result, extra_measurements, stop_meta}` - where `extra_measurements` is merged
      into stop measurements and `stop_meta` is merged into stop event metadata

  """
  @spec span(list(atom()), map(), (-> {any(), map()} | {any(), map(), map()})) :: any()
  def span(event_suffix, start_meta, fun) when is_list(event_suffix) and is_function(fun, 0) do
    span_id = generate_span_id()
    parent_span_id = push_span(span_id)

    span_meta = %{span_id: span_id, parent_span_id: parent_span_id}
    start_meta_with_span = Map.merge(start_meta, span_meta)

    # Wrap the function to inject span IDs into stop metadata
    wrapped_fun = fn ->
      case fun.() do
        {result, stop_meta} ->
          {result, Map.merge(stop_meta, span_meta)}

        {result, extra_measurements, stop_meta} ->
          {result, extra_measurements, Map.merge(stop_meta, span_meta)}
      end
    end

    try do
      :telemetry.span(@prefix ++ event_suffix, start_meta_with_span, wrapped_fun)
    after
      pop_span()
    end
  end

  @doc """
  Emit a telemetry event.

  Automatically includes `span_id` and `parent_span_id` from the current span context.

  ## Parameters

  - `event_suffix` - List of atoms to append to the prefix
  - `measurements` - Map of measurements (default: `%{}`)
  - `metadata` - Map of metadata

  """
  @spec emit(list(atom()), map(), map()) :: :ok
  def emit(event_suffix, measurements \\ %{}, metadata) when is_list(event_suffix) do
    metadata_with_span = Map.merge(metadata, current_span_context())
    :telemetry.execute(@prefix ++ event_suffix, measurements, metadata_with_span)
  end

  @doc """
  Returns the telemetry event prefix.

  ## Examples

      iex> PtcRunner.SubAgent.Telemetry.prefix()
      [:ptc_runner, :sub_agent]
  """
  @spec prefix() :: list(atom())
  def prefix, do: @prefix

  @doc """
  Returns the current span ID, or nil if not within a span.
  """
  @spec current_span_id() :: String.t() | nil
  def current_span_id do
    case Process.get(@span_stack_key, []) do
      [current | _] -> current
      [] -> nil
    end
  end

  # Generate an 8-character hex span ID
  defp generate_span_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  # Push a new span onto the stack, returning the parent span ID
  defp push_span(span_id) do
    stack = Process.get(@span_stack_key, [])
    parent_span_id = List.first(stack)
    Process.put(@span_stack_key, [span_id | stack])
    parent_span_id
  end

  # Pop the current span from the stack
  defp pop_span do
    case Process.get(@span_stack_key, []) do
      [_current | rest] -> Process.put(@span_stack_key, rest)
      [] -> :ok
    end
  end

  # Get the current span context for emit/3
  defp current_span_context do
    case Process.get(@span_stack_key, []) do
      [current | rest] ->
        %{span_id: current, parent_span_id: List.first(rest)}

      [] ->
        %{span_id: nil, parent_span_id: nil}
    end
  end
end
