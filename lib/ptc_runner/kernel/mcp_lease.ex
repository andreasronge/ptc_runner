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

  @spec next_request(t()) :: {:ok, map()} | {:error, :session_expired | :closed}
  def next_request(%__MODULE__{pid: pid}), do: safe_call(pid, :next_request)

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
       expired?: false
     }}
  end

  @impl GenServer
  def handle_call(:next_request, _from, %{expired?: true} = state),
    do: {:reply, {:error, :session_expired}, state}

  def handle_call(:next_request, _from, state) do
    request = %{
      endpoint: state.endpoint,
      headers: state.headers,
      timeout_ms: state.timeout_ms,
      session_id: state.session_id,
      protocol: @protocol,
      id: state.next_id
    }

    {:reply, {:ok, request}, %{state | next_id: state.next_id + 1}}
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

  def handle_call(:expire, _from, state),
    do: {:stop, :normal, :ok, %{state | expired?: true}}

  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

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

      _ =
        Req.delete(state.endpoint,
          headers: headers,
          receive_timeout: min(state.timeout_ms, 1_000),
          retry: false,
          redirect: false,
          decode_body: false
        )
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
end
