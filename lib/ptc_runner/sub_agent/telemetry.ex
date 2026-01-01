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
  | `[:run, :start]` | `%{}` | agent, context |
  | `[:run, :stop]` | `%{duration: native_time}` | agent, step, status |
  | `[:run, :exception]` | `%{duration: native_time}` | agent, kind, reason, stacktrace |
  | `[:turn, :start]` | `%{}` | agent, turn |
  | `[:turn, :stop]` | `%{duration: native_time, tokens: n}` | agent, turn, program |
  | `[:llm, :start]` | `%{}` | agent, turn, messages |
  | `[:llm, :stop]` | `%{duration: native_time, tokens: n}` | agent, turn, response |
  | `[:tool, :start]` | `%{}` | agent, tool_name, args |
  | `[:tool, :stop]` | `%{duration: native_time}` | agent, tool_name, result |
  | `[:tool, :exception]` | `%{duration: native_time}` | agent, tool_name, kind, reason, stacktrace |

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

  @doc """
  Execute a function within a telemetry span.

  Emits `:start`, `:stop`, and `:exception` events automatically.
  The start metadata is passed as-is. The stop metadata receives
  any additional measurements or metadata returned from the function.

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
    :telemetry.span(@prefix ++ event_suffix, start_meta, fun)
  end

  @doc """
  Emit a telemetry event.

  ## Parameters

  - `event_suffix` - List of atoms to append to the prefix
  - `measurements` - Map of measurements (default: `%{}`)
  - `metadata` - Map of metadata

  """
  @spec emit(list(atom()), map(), map()) :: :ok
  def emit(event_suffix, measurements \\ %{}, metadata) when is_list(event_suffix) do
    :telemetry.execute(@prefix ++ event_suffix, measurements, metadata)
  end

  @doc """
  Returns the telemetry event prefix.

  ## Examples

      iex> PtcRunner.SubAgent.Telemetry.prefix()
      [:ptc_runner, :sub_agent]
  """
  @spec prefix() :: list(atom())
  def prefix, do: @prefix
end
