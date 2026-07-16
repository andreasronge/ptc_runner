defmodule PtcRunner.Kernel.EventSink do
  @moduledoc """
  Bounded in-memory owner for canonical Kernel events.

  The sink assigns schema version, run/trace identity, monotonic sequence, and
  UTC timestamp. Producers supply only event type and bounded data.

  Under `:normal` policy, a full or failed sink drops later events and records
  loss by event type without changing workflow execution. Under `:private`
  policy, the same condition returns `:event_sink_error` so the run can fail
  closed. The sink monitors its owner and exits when the owner terminates.

  Persistent JSONL storage is an explicit `PtcRunner.Kernel.TraceLog` operation
  after collection, not an arbitrary callback in the runtime path.
  """
  use GenServer

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Lisp.RetainedSize

  @enforce_keys [:pid, :token, :policy]
  defstruct [:pid, :token, :policy]

  @type policy :: :normal | :private
  @type t :: %__MODULE__{pid: pid(), token: reference(), policy: policy()}

  @spec start(policy(), Limits.t(), keyword()) :: {:ok, t()} | {:error, :invalid_event_sink}
  @doc """
  Starts a sink with one policy and the event bounds from `limits`.

  Options are `:run_id`, `:trace_id`, and `:owner`. IDs must be binaries; a
  unique run ID is generated when omitted and is also the default trace ID.
  """
  def start(policy, %Limits{} = limits, opts \\ []) when policy in [:normal, :private] do
    token = make_ref()
    run_id = Keyword.get_lazy(opts, :run_id, &default_run_id/0)
    trace_id = Keyword.get(opts, :trace_id, run_id)

    if is_binary(run_id) and is_binary(trace_id) do
      owner = Keyword.get(opts, :owner, self())
      {:ok, pid} = GenServer.start(__MODULE__, {policy, limits, token, run_id, trace_id, owner})
      {:ok, %__MODULE__{pid: pid, token: token, policy: policy}}
    else
      {:error, :invalid_event_sink}
    end
  end

  @spec emit(t(), binary(), map()) :: :ok | {:error, :event_sink_error}
  @doc "Emits one bounded event or applies the sink's loss policy."
  def emit(sink, type, data) when is_binary(type) and is_map(data) do
    case call(sink, {:emit, type, data}) do
      {:error, :event_sink_error} when sink.policy == :normal -> :ok
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

  @spec stop(t()) :: :ok
  @doc "Stops the sink. Calling it after owner-driven shutdown is harmless."
  def stop(sink) do
    GenServer.stop(sink.pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({policy, limits, token, run_id, trace_id, owner}) do
    {:ok,
     %{
       policy: policy,
       limits: limits,
       token: token,
       owner_ref: Process.monitor(owner),
       run_id: run_id,
       trace_id: trace_id,
       sequence: 0,
       bytes: 0,
       events: [],
       dropped: %{}
     }}
  end

  @impl GenServer
  def handle_call({token, {:emit, type, data}}, _from, %{token: token} = state) do
    case event_bytes(data, state.limits.event_payload_bytes) do
      {:ok, bytes} -> enqueue(state, type, data, bytes)
      :error -> sink_failure(state, type)
    end
  end

  def handle_call({token, :events}, _from, %{token: token} = state),
    do: {:reply, Enum.reverse(state.events), state}

  def handle_call({token, :dropped}, _from, %{token: token} = state),
    do: {:reply, state.dropped, state}

  def handle_call({token, :policy}, _from, %{token: token} = state),
    do: {:reply, state.policy, state}

  def handle_call({token, :identity}, _from, %{token: token} = state),
    do: {:reply, %{run_id: state.run_id, trace_id: state.trace_id}, state}

  def handle_call({_token, _request}, _from, state),
    do: {:reply, {:error, :event_sink_error}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue(state, type, data, bytes) do
    full? =
      length(state.events) >= state.limits.normal_event_count or
        state.bytes + bytes > state.limits.normal_event_bytes

    if full? do
      sink_failure(state, type)
    else
      event = %{
        schema_version: 1,
        run_id: state.run_id,
        trace_id: state.trace_id,
        sequence: state.sequence + 1,
        timestamp: DateTime.utc_now(),
        type: type,
        data: data
      }

      {:reply, :ok,
       %{
         state
         | sequence: state.sequence + 1,
           bytes: state.bytes + bytes,
           events: [event | state.events]
       }}
    end
  end

  defp sink_failure(%{policy: :private} = state, _type),
    do: {:reply, {:error, :event_sink_error}, state}

  defp sink_failure(state, type) do
    dropped = Map.update(state.dropped, type, 1, &(&1 + 1))
    {:reply, :ok, %{state | dropped: dropped}}
  end

  defp event_bytes(data, cap) do
    case RetainedSize.bytes_with_cap(data, cap) do
      bytes when is_integer(bytes) and bytes <= cap -> {:ok, bytes}
      _ -> :error
    end
  end

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
