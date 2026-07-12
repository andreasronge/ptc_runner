defmodule PtcRunner.Kernel.EventSink do
  @moduledoc "A bounded canonical event sink with explicit normal/private policies."
  use GenServer

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Lisp.RetainedSize

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type policy :: :normal | :private
  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(policy(), Limits.t(), keyword()) :: {:ok, t()} | {:error, :invalid_event_sink}
  def start(policy, %Limits{} = limits, opts \\ []) when policy in [:normal, :private] do
    token = make_ref()
    run_id = Keyword.get(opts, :run_id, "run-#{System.unique_integer([:positive])}")
    trace_id = Keyword.get(opts, :trace_id, run_id)

    if is_binary(run_id) and is_binary(trace_id) do
      owner = Keyword.get(opts, :owner, self())
      {:ok, pid} = GenServer.start(__MODULE__, {policy, limits, token, run_id, trace_id, owner})
      {:ok, %__MODULE__{pid: pid, token: token}}
    else
      {:error, :invalid_event_sink}
    end
  end

  @spec emit(t(), binary(), map()) :: :ok | {:error, :event_sink_error}
  def emit(sink, type, data) when is_binary(type) and is_map(data),
    do: call(sink, {:emit, type, data})

  @spec events(t()) :: [map()]
  def events(sink), do: call(sink, :events)

  @spec dropped(t()) :: map()
  def dropped(sink), do: call(sink, :dropped)

  @spec policy(t()) :: policy() | {:error, :event_sink_error}
  def policy(sink), do: call(sink, :policy)

  @spec stop(t()) :: :ok
  def stop(sink), do: GenServer.stop(sink.pid, :normal)

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

  defp call(%__MODULE__{pid: pid, token: token}, request),
    do: GenServer.call(pid, {token, request})
end
