defmodule PtcRunnerMcp.Http.SessionRegistry do
  @moduledoc false

  use GenServer

  alias PtcRunnerMcp.Http.Session
  alias PtcRunnerMcp.{Log, Sessions}
  alias PtcRunnerMcp.Sessions.Owner, as: PtcOwner

  defstruct sessions: %{},
            by_owner: %{},
            monitors: %{},
            config: %{},
            draining?: false,
            cleanup_ref: nil

  @cleanup_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    ref = Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:ok, %__MODULE__{config: config, cleanup_ref: ref}}
  end

  @spec create(map(), String.t(), GenServer.server()) ::
          {:ok, map()} | {:error, :max_sessions | :max_sessions_per_owner}
  def create(owner, protocol_version, registry \\ __MODULE__) do
    GenServer.call(registry, {:create, owner, protocol_version}, 5_000)
  end

  @spec lookup(String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, :not_found}
  def lookup(id, owner, registry \\ __MODULE__) do
    GenServer.call(registry, {:lookup, id, owner}, 5_000)
  end

  @spec delete(String.t(), map(), GenServer.server()) :: :ok | {:error, :not_found}
  def delete(id, owner, registry \\ __MODULE__) do
    GenServer.call(registry, {:delete, id, owner}, 5_000)
  end

  @spec saturated?(GenServer.server()) :: boolean()
  def saturated?(registry \\ __MODULE__) do
    GenServer.call(registry, :saturated?, 5_000)
  end

  @spec draining?(GenServer.server()) :: boolean()
  def draining?(registry \\ __MODULE__) do
    GenServer.call(registry, :draining?, 5_000)
  end

  @spec drain(GenServer.server()) :: :ok
  def drain(registry \\ __MODULE__) do
    GenServer.call(registry, :drain, 5_000)
  end

  @impl GenServer
  def handle_call({:create, owner, protocol_version}, _from, state) do
    cond do
      state.draining? ->
        {:reply, {:error, :draining}, state}

      map_size(state.sessions) >= state.config.max_sessions ->
        {:reply, {:error, :max_sessions}, state}

      owner_count(state, owner.hash) >= state.config.max_sessions_per_owner ->
        {:reply, {:error, :max_sessions_per_owner}, state}

      true ->
        id = generate_id()

        case Session.start(
               id: id,
               owner: owner,
               owner_hash: owner.hash,
               protocol_version: protocol_version,
               max_in_flight: state.config.max_in_flight_per_session
             ) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            meta = %{
              id: id,
              pid: pid,
              owner: owner,
              owner_hash: owner.hash,
              protocol_version: protocol_version
            }

            state =
              state
              |> put_in([Access.key!(:sessions), id], meta)
              |> put_in([Access.key!(:monitors), ref], id)
              |> add_owner_index(owner.hash, id)

            {:reply, {:ok, meta}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:lookup, id, owner}, _from, state) do
    case Map.fetch(state.sessions, id) do
      {:ok, %{owner: ^owner} = meta} -> {:reply, {:ok, meta}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, id, owner}, _from, state) do
    case Map.fetch(state.sessions, id) do
      {:ok, %{owner: ^owner, pid: pid}} ->
        _ = Session.cancel_all(pid, :delete)
        stop_session(pid)
        {:reply, :ok, remove_session(state, id, :delete)}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:saturated?, _from, state) do
    {:reply, map_size(state.sessions) >= state.config.max_sessions, state}
  end

  def handle_call(:draining?, _from, state), do: {:reply, state.draining?, state}

  def handle_call(:drain, _from, state) do
    Enum.each(state.sessions, fn {_id, meta} -> _ = Session.cancel_all(meta.pid, :shutdown) end)
    {:reply, :ok, %{state | draining?: true}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} -> {:noreply, %{state | monitors: monitors}}
      {id, monitors} -> {:noreply, remove_session(%{state | monitors: monitors}, id, reason)}
    end
  end

  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(state.sessions, state, fn {id, meta}, acc ->
        cond do
          safe_expired?(meta.pid, now, acc.config.session_ttl_ms) ->
            _ = Session.cancel_all(meta.pid, :ttl)
            stop_session(meta.pid)
            remove_session(acc, id, :ttl)

          safe_idle?(meta.pid, now, acc.config.session_idle_timeout_ms) ->
            _ = Session.cancel_all(meta.pid, :idle)
            stop_session(meta.pid)
            remove_session(acc, id, :idle)

          true ->
            acc
        end
      end)

    ref = Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, %{state | cleanup_ref: ref}}
  end

  defp remove_session(state, id, reason) do
    case Map.pop(state.sessions, id) do
      {nil, sessions} ->
        %{state | sessions: sessions}

      {meta, sessions} ->
        Log.log(:info, "http_session_closed", %{session_hash: hash(id), reason: inspect(reason)})
        Sessions.close_owner(PtcOwner.http(id), reason)

        state
        |> Map.put(:sessions, sessions)
        |> remove_owner_index(meta.owner_hash, id)
    end
  end

  defp safe_idle?(pid, now, ms) do
    Session.idle?(pid, now, ms)
  catch
    :exit, _ -> false
  end

  defp safe_expired?(pid, now, ms) do
    Session.expired?(pid, now, ms)
  catch
    :exit, _ -> false
  end

  defp stop_session(pid) when is_pid(pid) do
    Session.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp add_owner_index(state, owner_hash, id) do
    update_in(state.by_owner[owner_hash], fn ids -> MapSet.put(ids || MapSet.new(), id) end)
  end

  defp remove_owner_index(state, owner_hash, id) do
    state =
      update_in(state.by_owner[owner_hash], fn
        nil ->
          nil

        ids ->
          ids = MapSet.delete(ids, id)
          if MapSet.size(ids) == 0, do: nil, else: ids
      end)

    if is_nil(Map.get(state.by_owner, owner_hash)) do
      %{state | by_owner: Map.delete(state.by_owner, owner_hash)}
    else
      state
    end
  end

  defp owner_count(state, owner_hash),
    do: state.by_owner |> Map.get(owner_hash, MapSet.new()) |> MapSet.size()

  defp generate_id do
    "mcp_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  defp hash(id),
    do: :crypto.hash(:sha256, id) |> Base.encode16(case: :lower) |> String.slice(0, 16)
end
