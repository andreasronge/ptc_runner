defmodule PtcRunner.Kernel.EventSink do
  @moduledoc """
  Bounded in-memory owner for canonical Kernel events.

  The sink assigns schema version, run/trace identity, monotonic sequence, and
  UTC timestamp. Producers supply only event type and bounded data.

  Under `:normal` policy, a full or unavailable sink ordinarily records or
  projects loss without changing workflow execution. An internal normal sink
  may opt into fail-closed owner loss so a session cannot continue without its
  canonical recorder. The sink monitors its owner and exits when the owner
  terminates.

  Persistent JSONL storage is an explicit `PtcRunner.Kernel.TraceLog` operation
  after collection, not an arbitrary callback in the runtime path.
  """
  use GenServer

  alias PtcRunner.Kernel.EventSinkState
  alias PtcRunner.Kernel.Limits

  @enforce_keys [:pid, :token, :policy]
  defstruct [:pid, :token, :policy, fail_closed?: false]

  @type policy :: :normal | :private
  @type t :: %__MODULE__{
          pid: pid(),
          token: reference(),
          policy: policy(),
          fail_closed?: boolean()
        }

  @spec start(policy(), Limits.t(), keyword()) :: {:ok, t()} | {:error, :invalid_event_sink}
  @doc """
  Starts a sink with one policy and the event bounds from `limits`.

  Options are `:run_id`, `:trace_id`, `:owner`, and the internal normal-policy
  `:terminal_reserve` and `:fail_closed`. IDs must be binaries; a unique run ID
  is generated when omitted and is also the default trace ID.
  """
  def start(policy, %Limits{} = limits, opts \\ []) when policy in [:normal, :private] do
    with {:ok, sink_state, handle} <- prepare(policy, limits, opts) do
      owner = Keyword.get(opts, :owner, self())
      {:ok, pid} = GenServer.start(__MODULE__, {sink_state, owner})
      {:ok, struct!(__MODULE__, Map.put(handle, :pid, pid))}
    end
  end

  @doc false
  def prepare(policy, %Limits{} = limits, opts) when policy in [:normal, :private] do
    token = make_ref()
    run_id = Keyword.get_lazy(opts, :run_id, &default_run_id/0)
    trace_id = Keyword.get(opts, :trace_id, run_id)
    terminal_reserve = Keyword.get(opts, :terminal_reserve, %{count: 0, bytes: 0})
    fail_closed? = Keyword.get(opts, :fail_closed, false)

    if Keyword.keys(opts) -- [:run_id, :trace_id, :owner, :terminal_reserve, :fail_closed] == [] and
         is_binary(run_id) and is_binary(trace_id) and is_boolean(fail_closed?) and
         valid_terminal_reserve?(policy, terminal_reserve, limits) do
      state = EventSinkState.new(policy, limits, token, run_id, trace_id, terminal_reserve)
      {:ok, state, %{token: token, policy: policy, fail_closed?: fail_closed?}}
    else
      {:error, :invalid_event_sink}
    end
  end

  @spec emit(t(), binary(), map()) :: :ok | {:error, :event_sink_error}
  @doc "Emits one bounded event or applies the sink's loss policy."
  def emit(sink, type, data) when is_binary(type) and is_map(data) do
    case call(sink, {:emit, type, data}) do
      {:error, :event_sink_error} when sink.policy == :normal and not sink.fail_closed? -> :ok
      result -> result
    end
  end

  @spec events(t()) :: [map()]
  @doc "Returns retained canonical events in sequence order."
  def events(sink) do
    case call(sink, :events) do
      {:error, :event_sink_error} -> []
      events -> events
    end
  end

  @spec dropped(t()) :: map()
  @doc "Returns dropped-event counts keyed by event type."
  def dropped(sink) do
    case call(sink, :dropped) do
      {:error, :event_sink_error} -> %{"event-sink" => 1}
      dropped -> dropped
    end
  end

  @doc false
  @spec finalize(t(), map(), map()) :: :ok | {:error, :event_sink_error}
  def finalize(%__MODULE__{policy: :normal} = sink, dropped_data, stopped_data)
      when is_map(dropped_data) and is_map(stopped_data),
      do: call(sink, {:finalize, dropped_data, stopped_data})

  def finalize(_sink, _dropped_data, _stopped_data), do: {:error, :event_sink_error}

  @doc false
  @spec finalize_and_events(t(), map(), map()) ::
          {:ok, [map()]} | {:error, :event_sink_error}
  def finalize_and_events(%__MODULE__{policy: :normal} = sink, dropped_data, stopped_data)
      when is_map(dropped_data) and is_map(stopped_data),
      do: call(sink, {:finalize_and_events, dropped_data, stopped_data})

  def finalize_and_events(_sink, _dropped_data, _stopped_data),
    do: {:error, :event_sink_error}

  @spec policy(t()) :: policy() | {:error, :event_sink_error}
  @doc "Returns the configured loss policy."
  def policy(sink), do: call(sink, :policy)

  @spec identity(t()) ::
          {:ok, %{run_id: binary(), trace_id: binary()}} | {:error, :event_sink_error}
  @doc "Returns only this sink's run and trace identity to its token holder."
  def identity(sink) do
    case call(sink, :identity) do
      %{run_id: _run_id, trace_id: _trace_id} = identity -> {:ok, identity}
      {:error, :event_sink_error} = error -> error
    end
  end

  @doc false
  def session_contract(sink) do
    case call(sink, :session_contract) do
      %{terminal_reserve: _reserve, ready?: _ready?} = contract -> {:ok, contract}
      {:error, :event_sink_error} = error -> error
    end
  end

  @spec stop(t()) :: :ok
  @doc "Stops the sink. Calling it after owner-driven shutdown is harmless."
  def stop(sink) do
    GenServer.stop(sink.pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({sink_state, owner}) do
    {:ok, Map.put(sink_state, :owner_ref, Process.monitor(owner))}
  end

  @impl GenServer
  def handle_call(request, _from, state) do
    {reply, next} = EventSinkState.handle(request, state)
    {:reply, reply, next}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp valid_terminal_reserve?(:normal, %{count: count, bytes: bytes}, limits)
       when is_integer(count) and is_integer(bytes) and count >= 0 and bytes >= 0 do
    count <= limits.normal_event_count and bytes <= limits.normal_event_bytes and
      ((count == 0 and bytes == 0) or (count >= 2 and bytes >= limits.event_payload_bytes * 2))
  end

  defp valid_terminal_reserve?(:private, %{count: 0, bytes: 0}, _limits), do: true
  defp valid_terminal_reserve?(_policy, _reserve, _limits), do: false

  defp call(%__MODULE__{pid: pid, token: token}, request) do
    GenServer.call(pid, {token, request})
  catch
    :exit, _reason -> {:error, :event_sink_error}
  end

  # Run identifiers must be unique across separate OS processes: traces from
  # independent CLI invocations commonly land in one directory, and
  # `Kernel.TraceLog` fail-closes the whole directory source when two files
  # reuse a run/trace identity with restarted sequences. A per-VM counter
  # collides almost deterministically there, so the default carries entropy.
  defp default_run_id do
    "run-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end
end
