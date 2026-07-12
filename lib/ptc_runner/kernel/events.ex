defmodule PtcRunner.Kernel.Events do
  @moduledoc false

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.RunState

  def emit(_state, nil, _type, _data), do: :ok

  def emit(state, sink, type, data) do
    case EventSink.emit(sink, type, data) do
      :ok ->
        :ok

      {:error, :event_sink_error} = error ->
        :ok = RunState.fail(state, :event_sink_error, :event_sink_error)
        error
    end
  end

  def id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  def duration_ms(started_ms),
    do: max(System.monotonic_time(:millisecond) - started_ms, 0)
end
