defmodule PtcRunner.Kernel.Events do
  @moduledoc """
  Internal canonical event helpers.

  Sink failure is reflected atomically into run state so a private fail-closed
  event policy becomes the terminal run outcome.
  """

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SafeMetadata

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

  @doc """
  Derives a valid W3C trace context from private run-local identifiers.

  Hashing prevents arbitrary operator-selected trace IDs from crossing the
  provider boundary. The capability attempt supplies a distinct span ID.
  """
  @spec traceparent(binary(), binary()) :: binary()
  def traceparent(trace_id, capability_id)
      when is_binary(trace_id) and is_binary(capability_id) do
    trace = digest_prefix(trace_id, 16)
    span = digest_prefix(capability_id, 8)
    "00-#{trace}-#{span}-01"
  end

  @doc "Returns non-negative elapsed monotonic milliseconds."
  def duration_ms(started_ms),
    do: max(System.monotonic_time(:millisecond) - started_ms, 0)

  @doc """
  Copies a payload-free rejection class from an error envelope onto event data.

  Known Kernel envelope `kind` and `reason` atoms remain readable. An
  unrecognized atom is retained only as a one-way fingerprint. Details,
  messages, and caller-supplied strings stay off the canonical event.
  Successful results omit these fields.
  """
  @spec put_rejection_class(map(), term()) :: map()
  def put_rejection_class(data, result) when is_map(data) do
    Map.merge(data, SafeMetadata.rejection_class(result))
  end

  defp digest_prefix(value, bytes) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, bytes)
    |> Base.encode16(case: :lower)
  end
end
