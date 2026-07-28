defmodule PtcRunner.Kernel.MCPRequestContext do
  @moduledoc false

  use GenServer

  @enforce_keys [:pid]
  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  @spec start(keyword()) :: {:ok, t()}
  def start(opts) do
    owner = Keyword.fetch!(opts, :owner)
    endpoint = Keyword.fetch!(opts, :endpoint)
    headers = Keyword.fetch!(opts, :headers)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    {:ok, pid} = GenServer.start(__MODULE__, {owner, endpoint, headers, timeout_ms})
    {:ok, %__MODULE__{pid: pid}}
  end

  @spec begin_request(t()) :: {:ok, map()} | {:error, :closed}
  def begin_request(%__MODULE__{pid: pid}), do: safe_call(pid, :begin_request)

  @spec finish_request(t()) :: :ok
  def finish_request(%__MODULE__{pid: pid}) do
    case safe_call(pid, :finish_request) do
      :ok -> :ok
      {:error, :closed} -> :ok
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    ref = Process.monitor(pid)

    try do
      _ = safe_call(pid, :close)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    after
      Process.demonitor(ref, [:flush])
    end
  end

  @impl GenServer
  def init({owner, endpoint, headers, timeout_ms}) do
    {:ok,
     %{
       owner_ref: Process.monitor(owner),
       endpoint: endpoint,
       headers: headers,
       timeout_ms: timeout_ms,
       next_id: 1,
       active: %{},
       closing: nil
     }}
  end

  @impl GenServer
  def handle_call(:begin_request, _from, %{closing: closing} = state)
      when not is_nil(closing),
      do: {:reply, {:error, :closed}, state}

  def handle_call(:begin_request, {caller, _tag}, state) do
    request = %{
      endpoint: state.endpoint,
      headers: state.headers,
      timeout_ms: state.timeout_ms,
      id: state.next_id
    }

    active = Map.put(state.active, caller, Process.monitor(caller))
    {:reply, {:ok, request}, %{state | next_id: state.next_id + 1, active: active}}
  end

  def handle_call(:finish_request, {caller, _tag}, state) do
    state = release_active(state, caller)
    finish_or_continue(state, :ok)
  end

  def handle_call(:close, from, %{closing: {reason, waiters}} = state) do
    {:noreply, %{state | closing: {reason, [from | waiters]}}}
  end

  def handle_call(:close, from, state) do
    state = %{state | closing: {:close, [from]}}
    kill_active(state.active)

    if map_size(state.active) == 0,
      do: stop_and_reply(state),
      else: {:noreply, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    state = %{state | closing: state.closing || {:owner_down, []}}
    kill_active(state.active)

    if map_size(state.active) == 0,
      do: stop_and_reply(state),
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.active do
      %{^pid => ^ref} -> state |> release_active(pid, false) |> close_or_continue()
      _active -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  defp safe_call(pid, request) do
    GenServer.call(pid, request)
  catch
    :exit, _reason -> {:error, :closed}
  end

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp release_active(state, caller, demonitor? \\ true) do
    {ref, active} = Map.pop(state.active, caller)
    if demonitor? and is_reference(ref), do: Process.demonitor(ref, [:flush])
    %{state | active: active}
  end

  defp finish_or_continue(%{active: active, closing: {_reason, _waiters}} = state, reply)
       when map_size(active) == 0 do
    reply_waiters(state)
    {:stop, :normal, reply, state}
  end

  defp finish_or_continue(state, reply), do: {:reply, reply, state}

  defp close_or_continue(%{active: active, closing: nil} = state) when map_size(active) == 0,
    do: {:noreply, state}

  defp close_or_continue(%{active: active, closing: {_reason, _waiters}} = state)
       when map_size(active) == 0,
       do: stop_and_reply(state)

  defp close_or_continue(state), do: {:noreply, state}

  defp stop_and_reply(state) do
    reply_waiters(state)
    {:stop, :normal, state}
  end

  defp reply_waiters(%{closing: {_reason, waiters}}),
    do: Enum.each(waiters, &GenServer.reply(&1, :ok))

  defp kill_active(active),
    do: Enum.each(Map.keys(active), &Process.exit(&1, :kill))
end
