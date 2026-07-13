defmodule PtcRunner.Kernel.Events do
  @moduledoc """
  Internal canonical event helpers.

  Sink failure is reflected atomically into run state so a private fail-closed
  event policy becomes the terminal run outcome.
  """

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.RunState

  @doc "Emits an event and records fail-closed sink failure in run state."
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

  @doc "Builds a run-local identifier for an evaluation or capability attempt."
  def id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  @doc "Returns non-negative elapsed monotonic milliseconds."
  def duration_ms(started_ms),
    do: max(System.monotonic_time(:millisecond) - started_ms, 0)
end
