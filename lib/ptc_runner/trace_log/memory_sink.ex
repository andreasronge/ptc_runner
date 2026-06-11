defmodule PtcRunner.TraceLog.MemorySink do
  @moduledoc """
  In-memory ring-buffer sink for turn-log events, alongside the JSONL file
  sink (`PtcRunner.TraceLog.Collector`).

  A `GenServer` holding recent events in memory under a total byte budget. When
  appending an event would push the buffer over `:max_bytes`, the oldest events
  are evicted until it fits (the newest event is always retained). This makes
  "analyze my last session" work with no filesystem setup — `mix ptc.repl`
  enables a sink by default, and the same `PtcRunner.TraceLog.Analyzer` queries
  read its events.

  The byte cost of each event is its JSON-encoded size (the same encoding the
  file sink writes), so the budget bounds real serialized retention. Retention
  and redaction are host policy (plan D2): the default budget is conservative
  but host-configurable via `:max_bytes`.

  Records are accepted as already-built event maps (see
  `PtcRunner.TraceLog.TurnEvent`). Like the file sink, the in-memory sink
  assigns a monotonic `seq` and stamps `timestamp` when absent, so events stay
  orderable independent of wall-clock skew.
  """

  use GenServer

  alias PtcRunner.TraceLog.Event

  # Conservative default: enough to retain the handful of real observatory
  # sandbox sessions M1 needs, while bounding unbounded growth. Host-overridable.
  @default_max_bytes 8 * 1024 * 1024

  defstruct events: [], bytes: 0, max_bytes: @default_max_bytes, seq: 0

  @type t :: %__MODULE__{
          events: [{non_neg_integer(), map()}],
          bytes: non_neg_integer(),
          max_bytes: pos_integer(),
          seq: non_neg_integer()
        }

  @doc """
  Starts an in-memory sink.

  ## Options

    * `:max_bytes` - total JSON-encoded byte budget (default: #{@default_max_bytes})
    * `:name` - optional registered name for the GenServer
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Records an event map into the sink (async). Never raises.
  """
  @spec record(GenServer.server(), map()) :: :ok
  def record(sink, event) when is_map(event) do
    GenServer.cast(sink, {:record, event})
  end

  @doc """
  Returns all retained events in chronological (oldest-first) order.
  """
  @spec events(GenServer.server()) :: [map()]
  def events(sink) do
    GenServer.call(sink, :events)
  end

  @doc "Returns the number of retained events."
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(sink) do
    GenServer.call(sink, :count)
  end

  @doc """
  Runs `fun` over the retained events (chronological order) INSIDE the sink
  process and returns its result.

  Host-side projection support (P2 of `docs/plans/sandbox-heap-rebaseline.md`):
  a caller running under a heap budget — the PTC-Lisp sandbox holding a
  `log/` introspection grant — pays only for the projected result crossing
  back, never for a copy of the full buffer. `fun` must be host-trusted code;
  if it raises, the error is re-raised in the caller and the sink survives.
  """
  @spec query(GenServer.server(), ([map()] -> term())) :: term()
  def query(sink, fun) when is_function(fun, 1) do
    case GenServer.call(sink, {:query, fun}) do
      {:ok, result} -> result
      {:error, exception, stacktrace} -> reraise(exception, stacktrace)
    end
  end

  @doc "Drops all retained events."
  @spec clear(GenServer.server()) :: :ok
  def clear(sink) do
    GenServer.cast(sink, :clear)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    {:ok, %__MODULE__{max_bytes: max(max_bytes, 1)}}
  end

  @impl true
  def handle_cast({:record, event}, state) do
    {seq, state} = next_seq(state)

    stamped =
      event
      |> Map.put("seq", seq)
      |> Map.put_new_lazy("timestamp", fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

    size = encoded_size(stamped)

    state =
      %{state | events: [{size, stamped} | state.events], bytes: state.bytes + size}
      |> evict()

    {:noreply, state}
  end

  def handle_cast(:clear, state) do
    {:noreply, %{state | events: [], bytes: 0}}
  end

  @impl true
  def handle_call(:events, _from, state) do
    {:reply, chronological_events(state), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, length(state.events), state}
  end

  def handle_call({:query, fun}, _from, state) do
    reply =
      try do
        {:ok, fun.(chronological_events(state))}
      rescue
        exception -> {:error, exception, __STACKTRACE__}
      end

    {:reply, reply, state}
  end

  # --- private ---

  defp chronological_events(state) do
    state.events
    |> Enum.reverse()
    |> Enum.map(fn {_size, event} -> event end)
  end

  defp next_seq(state) do
    seq = state.seq + 1
    {seq, %{state | seq: seq}}
  end

  # Evict oldest (tail) while over budget, but never drop the single newest event
  # (a single event larger than the whole budget is still retained, alone).
  defp evict(%__MODULE__{bytes: bytes, max_bytes: max_bytes} = state)
       when bytes <= max_bytes do
    state
  end

  defp evict(%__MODULE__{events: events} = state) when length(events) <= 1 do
    state
  end

  defp evict(%__MODULE__{events: events, bytes: bytes} = state) do
    {dropped_size, _event} = List.last(events)

    %{state | events: List.delete_at(events, -1), bytes: bytes - dropped_size}
    |> evict()
  end

  defp encoded_size(event) do
    case Event.encode(event) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> 0
    end
  end
end
