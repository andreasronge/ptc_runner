defmodule PtcRunner.Kernel.EventSink do
  @moduledoc """
  Bounded in-memory owner for canonical Kernel events.

  The sink assigns schema version, run/trace identity, monotonic sequence, and
  UTC timestamp. Producers supply only a canonical bounded event type and data
  that normalize to JSON without key collisions. Per-event payload accounting
  and aggregate accounting cover the payload and complete retained envelope,
  respectively, so every retained event is consumable by `TraceLog`.

  Under `:normal` policy, a full or unavailable sink ordinarily records or
  projects loss without changing workflow execution. An internal normal sink
  may opt into fail-closed owner loss so a session cannot continue without its
  canonical recorder. Normal sinks reserve two measured terminal envelopes by default.
  Finalization atomically appends the bounded loss summary and `run-stopped`,
  freezes the recorder, and returns the exact terminal batch and drop snapshot.
  Runner and session startup atomically claim the recorder while retaining
  `run-started`, so one configuration cannot execute twice or concurrently.
  Later emits cannot mutate either snapshot. Drop accounting retains at most
  sixteen event-type buckets plus a saturating `$overflow` count. The sink
  monitors its owner and exits when the owner terminates.

  Persistent JSONL storage is an explicit `PtcRunner.Kernel.TraceLog` operation
  after collection, not an arbitrary callback in the runtime path.
  """
  use GenServer

  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.EventSinkState
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.OwnerHandoff

  @stop_timeout_ms 5_000

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
  `:terminal_reserve` and `:fail_closed`. Normal sinks default to the standard
  two-event terminal reserve; private sinks reserve nothing. IDs must be valid UTF-8 binaries from
  1 through 256 bytes; a unique run ID is generated when omitted and is also
  the default trace ID.
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
    terminal_reserve = Keyword.get(opts, :terminal_reserve, terminal_reserve(policy, limits))
    fail_closed? = Keyword.get(opts, :fail_closed, false)

    if Keyword.keys(opts) -- [:run_id, :trace_id, :owner, :terminal_reserve, :fail_closed] == [] and
         valid_id?(run_id) and valid_id?(trace_id) and is_boolean(fail_closed?) and
         valid_terminal_reserve?(policy, terminal_reserve, limits) and
         terminal_payload_capacity?(policy, limits, terminal_reserve) do
      state = EventSinkState.new(policy, limits, token, run_id, trace_id, terminal_reserve)
      {:ok, state, %{token: token, policy: policy, fail_closed?: fail_closed?}}
    else
      {:error, :invalid_event_sink}
    end
  end

  @doc false
  @spec terminal_reserve(policy(), Limits.t()) :: %{
          count: non_neg_integer(),
          bytes: non_neg_integer()
        }
  def terminal_reserve(:normal, %Limits{} = limits),
    do: %{
      count: 2,
      bytes:
        limits.event_payload_bytes * 2 + terminal_envelope_bytes("events-dropped") +
          terminal_envelope_bytes("run-stopped")
    }

  def terminal_reserve(:private, %Limits{}), do: %{count: 0, bytes: 0}

  @spec emit(t(), binary(), map()) :: :ok | {:error, :event_sink_error}
  @doc "Emits one bounded event or applies the sink's loss policy."
  def emit(sink, type, data) when is_binary(type) and is_map(data) do
    case call(sink, {:emit, type, data}) do
      {:error, :event_sink_error} when sink.policy == :normal and not sink.fail_closed? -> :ok
      result -> result
    end
  end

  @doc false
  @spec begin(t(), map()) :: :ok | {:error, :event_sink_error}
  def begin(%__MODULE__{} = sink, data) when is_map(data) do
    case claim(sink, make_ref(), data) do
      {:error, reason}
      when reason in [:event_sink_already_claimed, :event_sink_claimed_by_other] ->
        {:error, :event_sink_error}

      result ->
        result
    end
  end

  def begin(_sink, _data), do: {:error, :event_sink_error}

  @doc false
  @spec claim(t(), reference(), map()) ::
          :ok
          | {:error,
             :event_sink_error
             | :event_sink_already_claimed
             | :event_sink_claimed_by_other}
  def claim(%__MODULE__{} = sink, claim_id, data)
      when is_reference(claim_id) and is_map(data),
      do: call(sink, {:begin, claim_id, data})

  def claim(_sink, _claim_id, _data), do: {:error, :event_sink_error}

  @doc false
  def begin_capacity?(%__MODULE__{} = sink, data) when is_map(data),
    do: call(sink, {:begin_capacity?, data}) == true

  def begin_capacity?(_sink, _data), do: false

  @doc false
  def terminal_usage_capacity?(sink, %Limits{} = limits, usage) do
    case required_terminal_payload_bytes(sink, usage) do
      bytes when is_integer(bytes) -> limits.event_payload_bytes >= bytes
      :error -> false
    end
  end

  def terminal_usage_capacity?(_sink, _limits, _usage), do: false

  @doc """
  Returns the `event_payload_bytes` one terminal payload of `usage` needs.

  Admission compares this against the effective limit, and the refusal reports
  it, so the number a caller is told to raise to is the number that refused
  them. Normal policy charges the saturated reachable drop map at its
  conservative bound rather than at whatever the current run happens to hold.
  """
  @spec required_terminal_payload_bytes(t(), map()) :: pos_integer() | :error
  def required_terminal_payload_bytes(%__MODULE__{policy: policy}, usage)
      when policy in [:normal, :private] and is_map(usage) do
    {dropped, drop_map_headroom} =
      if policy == :normal,
        do: EventBudget.maximum_dropped_with_headroom(),
        else: {%{}, 0}

    usage = Map.put(usage, :events_dropped, dropped)

    payloads = [
      %{outcome: :error, reason: EventBudget.maximum_terminal_reason(), usage: usage},
      %{
        outcome: :ok,
        reason: nil,
        result_hash: "sha256:" <> String.duplicate("f", 64),
        usage: usage
      }
    ]

    Enum.reduce_while(payloads, 1, fn payload, required ->
      case EventSinkState.payload_bytes(payload) do
        bytes when is_integer(bytes) -> {:cont, max(required, bytes + drop_map_headroom)}
        :error -> {:halt, :error}
      end
    end)
  end

  def required_terminal_payload_bytes(_sink, _usage), do: :error

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
  @spec finalize_and_events(t(), map()) ::
          {:ok, %{events: [map()], dropped: map()}} | {:error, :event_sink_error}
  def finalize_and_events(%__MODULE__{} = sink, stopped_data) when is_map(stopped_data),
    do: call(sink, {:finalize_and_events, stopped_data})

  def finalize_and_events(_sink, _stopped_data), do: {:error, :event_sink_error}

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
      %{terminal_reserve: _reserve, ready?: _ready?, begun?: _begun?} = contract ->
        {:ok, contract}

      {:error, :event_sink_error} = error ->
        error
    end
  end

  @doc false
  @spec owner?(t()) :: boolean()
  def owner?(sink), do: call(sink, :owner?) == true

  @doc false
  @spec owner(t()) :: {:ok, pid()} | {:error, :event_sink_error}
  def owner(sink), do: call(sink, :owner)

  @doc false
  @spec transfer_owner(t(), pid()) :: :ok | {:error, :event_sink_error}
  def transfer_owner(%__MODULE__{} = sink, owner) when is_pid(owner),
    do: call(sink, {:transfer_owner, owner})

  def transfer_owner(_sink, _owner), do: {:error, :event_sink_error}

  @doc false
  @spec stop_timeout_ms() :: pos_integer()
  def stop_timeout_ms, do: @stop_timeout_ms

  @spec stop(t()) :: :ok
  @doc "Stops the sink. Calling it after owner-driven shutdown is harmless."
  def stop(sink), do: stop(sink, @stop_timeout_ms)

  @doc false
  @spec stop(t(), timeout()) :: :ok
  def stop(sink, timeout) do
    ref = Process.monitor(sink.pid)

    try do
      try do
        GenServer.stop(sink.pid, :normal, timeout)
      catch
        :exit, _reason -> :ok
      end

      if Process.alive?(sink.pid), do: Process.exit(sink.pid, :kill)
      await_stop(ref, sink.pid, timeout)
    after
      Process.demonitor(ref, [:flush])
    end
  end

  @impl GenServer
  def init({sink_state, owner}) do
    {:ok,
     sink_state
     |> Map.put(:owner, owner)
     |> Map.put(:owner_ref, Process.monitor(owner))
     |> Map.put(:owner_transferable?, true)}
  end

  @impl GenServer
  def handle_call({token, :owner}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.owner}, state}

  def handle_call({token, :owner?}, {caller, _tag}, %{token: token} = state),
    do: {:reply, caller == state.owner, state}

  def handle_call(
        {token, {:transfer_owner, owner}},
        {caller, _tag},
        %{token: token, owner: caller, owner_transferable?: true} = state
      )
      when is_pid(owner) do
    case OwnerHandoff.transfer_once(state, owner) do
      {:ok, next} -> {:reply, :ok, next}
      :error -> {:reply, {:error, :event_sink_error}, state}
    end
  end

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
      ((count == 0 and bytes == 0) or
         (count >= 2 and bytes >= terminal_reserve(:normal, limits).bytes))
  end

  defp valid_terminal_reserve?(:private, %{count: 0, bytes: 0}, _limits), do: true
  defp valid_terminal_reserve?(_policy, _reserve, _limits), do: false

  defp terminal_payload_capacity?(_policy, _limits, %{count: 0, bytes: 0}), do: true
  defp terminal_payload_capacity?(:private, _limits, _reserve), do: true

  defp terminal_payload_capacity?(:normal, limits, _reserve) do
    EventBudget.normal_terminal_payload_capacity?(limits.event_payload_bytes)
  end

  defp terminal_envelope_bytes(type), do: EventBudget.terminal_envelope_bytes(type)

  defp valid_id?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp await_stop(ref, pid, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> :ok
    end
  end

  defp call(%__MODULE__{pid: pid, token: token}, request) do
    GenServer.call(pid, {token, request})
  catch
    :exit, _reason -> {:error, :event_sink_error}
  end

  # Run identifiers must be unique across separate OS processes: traces from
  # independent CLI invocations commonly land in one directory, and
  # `Kernel.TraceLog` isolates every connected file when two files reuse a
  # run/trace identity with restarted sequences. A per-VM counter collides
  # almost deterministically there, so the default carries entropy.
  defp default_run_id do
    "run-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end
end
