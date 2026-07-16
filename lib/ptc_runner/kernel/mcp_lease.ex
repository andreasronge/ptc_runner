defmodule PtcRunner.Kernel.MCPLease do
  @moduledoc false

  use GenServer

  @protocol "2025-11-25"

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

  @spec begin_request(t()) :: {:ok, map()} | {:error, :session_expired | :closed}
  def begin_request(%__MODULE__{pid: pid}), do: safe_call(pid, :begin_request)

  @spec finish_request(t()) :: :ok
  def finish_request(%__MODULE__{pid: pid}) do
    case safe_call(pid, :finish_request) do
      :ok -> :ok
      {:error, :closed} -> :ok
    end
  end

  @spec set_session(t(), binary() | nil) :: :ok | {:error, :closed}
  def set_session(%__MODULE__{pid: pid}, session_id),
    do: safe_call(pid, {:set_session, session_id})

  @spec expire(t()) :: :ok
  def expire(%__MODULE__{pid: pid}) do
    case safe_call(pid, :expire) do
      :ok -> :ok
      {:error, :closed} -> :ok
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    case safe_call(pid, :close) do
      :ok -> :ok
      {:error, :closed} -> :ok
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
       session_id: nil,
       next_id: 1,
       expired?: false,
       active: %{},
       closing: nil
     }}
  end

  @impl GenServer
  def handle_call(:begin_request, _from, %{expired?: true} = state),
    do: {:reply, {:error, :session_expired}, state}

  def handle_call(:begin_request, _from, %{closing: closing} = state)
      when not is_nil(closing),
      do: {:reply, {:error, :closed}, state}

  def handle_call(:begin_request, {caller, _tag}, state) do
    request = %{
      endpoint: state.endpoint,
      headers: state.headers,
      timeout_ms: state.timeout_ms,
      session_id: state.session_id,
      protocol: @protocol,
      id: state.next_id
    }

    active = Map.put(state.active, caller, Process.monitor(caller))
    {:reply, {:ok, request}, %{state | next_id: state.next_id + 1, active: active}}
  end

  def handle_call(:finish_request, {caller, _tag}, state) do
    state = release_active(state, caller)
    finish_or_continue(state, :ok)
  end

  def handle_call({:set_session, session_id}, _from, state)
      when is_nil(session_id) do
    {:reply, :ok, %{state | session_id: session_id}}
  end

  def handle_call({:set_session, session_id}, _from, state) when is_binary(session_id) do
    if valid_session_id?(session_id),
      do: {:reply, :ok, %{state | session_id: session_id}},
      else: {:reply, {:error, :invalid_session}, state}
  end

  def handle_call(:expire, _from, state) do
    state = %{state | expired?: true, closing: state.closing || :expired}
    finish_or_continue(state, :ok)
  end

  def handle_call(:close, _from, %{closing: {:close, _pending_from}} = state),
    do: {:reply, :ok, state}

  def handle_call(:close, from, state) do
    state = %{state | closing: {:close, from}}
    kill_active(state.active)

    if map_size(state.active) == 0,
      do: {:stop, :normal, :ok, state},
      else: {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    state = %{state | closing: state.closing || :owner_down}
    kill_active(state.active)

    if map_size(state.active) == 0,
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.active do
      %{^pid => ^ref} -> state |> release_active(pid, false) |> close_or_continue()
      _active -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if is_binary(state.session_id), do: terminate_session(state)
    :ok
  end

  defp terminate_session(state) do
    with {:ok, installed_headers} <- safe_headers(state.headers) do
      headers =
        installed_headers ++
          [
            {"mcp-protocol-version", @protocol},
            {"mcp-session-id", state.session_id}
          ]

      timeout_ms = min(state.timeout_ms, 1_000)

      task =
        Task.async(fn ->
          Req.delete(state.endpoint,
            headers: headers,
            connect_options: [timeout: timeout_ms],
            pool_timeout: timeout_ms,
            receive_timeout: timeout_ms,
            retry: false,
            redirect: false,
            decode_body: false
          )
        end)

      _ = Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill)
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_headers(headers) do
    case headers.() do
      values when is_list(values) -> {:ok, values}
      _values -> {:error, :invalid_headers}
    end
  rescue
    _exception -> {:error, :invalid_headers}
  catch
    _kind, _reason -> {:error, :invalid_headers}
  end

  defp safe_call(pid, request) do
    GenServer.call(pid, request)
  catch
    :exit, _reason -> {:error, :closed}
  end

  defp valid_session_id?(session_id),
    do: String.valid?(session_id) and session_id =~ ~r/\A[!-~]{1,1024}\z/

  defp release_active(state, caller, demonitor? \\ true) do
    {ref, active} = Map.pop(state.active, caller)
    if demonitor? and is_reference(ref), do: Process.demonitor(ref, [:flush])
    %{state | active: active}
  end

  defp finish_or_continue(%{active: active, closing: closing} = state, reply)
       when map_size(active) == 0 and not is_nil(closing),
       do: {:stop, :normal, reply, state}

  defp finish_or_continue(state, reply), do: {:reply, reply, state}

  defp close_or_continue(%{active: active, closing: nil} = state) when map_size(active) == 0,
    do: {:noreply, state}

  defp close_or_continue(%{active: active, closing: {:close, from}} = state)
       when map_size(active) == 0 do
    GenServer.reply(from, :ok)
    {:stop, :normal, state}
  end

  defp close_or_continue(%{active: active} = state) when map_size(active) == 0,
    do: {:stop, :normal, state}

  defp close_or_continue(state), do: {:noreply, state}

  defp kill_active(active),
    do: Enum.each(Map.keys(active), &Process.exit(&1, :kill))
end
