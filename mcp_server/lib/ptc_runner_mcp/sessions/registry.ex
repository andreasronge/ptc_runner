defmodule PtcRunnerMcp.Sessions.Registry do
  @moduledoc """
  Registry and quota owner for live PTC-Lisp sessions.

  The registry owns lookup indexes and monitors session processes. Session
  state itself lives inside `PtcRunnerMcp.Sessions.Session`.
  """

  use GenServer

  alias PtcRunnerMcp.Sessions.{Config, Owner, Supervisor}

  @max_tombstones 1024
  @names_registry PtcRunnerMcp.Sessions.Names

  defstruct sessions: %{},
            by_owner: %{},
            monitors: %{},
            tombstones: %{},
            session_supervisor: PtcRunnerMcp.Sessions.Supervisor,
            names_registry: nil

  @type session_meta :: %{
          id: String.t(),
          pid: pid(),
          owner: Owner.t(),
          owner_hash: String.t(),
          title: String.t() | nil,
          mode: :read_only | :write_capable,
          created_at: DateTime.t()
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    {:ok,
     %__MODULE__{
       session_supervisor: Keyword.get(opts, :session_supervisor, Supervisor),
       names_registry: Keyword.get(opts, :names_registry, default_names_registry(name))
     }}
  end

  @doc "Create and register a new session."
  @spec start_session(Owner.t(), map() | keyword(), GenServer.server()) ::
          {:ok, session_meta()} | {:error, atom() | map()}
  def start_session(owner, opts \\ %{}, registry \\ __MODULE__) when is_map(owner) do
    GenServer.call(registry, {:start_session, owner, Map.new(opts)})
  end

  @doc "Lookup a live session by id."
  @spec lookup(String.t(), GenServer.server()) ::
          {:ok, session_meta()} | {:error, :session_not_found | :session_closed}
  def lookup(session_id, registry \\ __MODULE__)

  def lookup(session_id, __MODULE__) when is_binary(session_id) do
    case live_lookup(session_id, Process.whereis(__MODULE__)) do
      [{pid, meta}] when is_pid(pid) ->
        # The `Sessions.Names` fast path can briefly return a dead pid: a
        # terminated session is pruned asynchronously, so between its `:DOWN`
        # and that prune the entry still resolves here. Handing back a dead
        # pid makes callers crash with `:noproc`; fall through to the
        # authoritative GenServer, which returns the `:session_closed`
        # tombstone instead.
        if Process.alive?(pid) do
          {:ok, Map.put(meta, :pid, pid)}
        else
          GenServer.call(__MODULE__, {:lookup, session_id})
        end

      _ ->
        GenServer.call(__MODULE__, {:lookup, session_id})
    end
  end

  def lookup(session_id, registry) when is_binary(session_id) do
    GenServer.call(registry, {:lookup, session_id})
  end

  defp live_lookup(_session_id, nil), do: []

  defp live_lookup(session_id, registry_pid) do
    case Process.whereis(@names_registry) do
      nil ->
        []

      _pid ->
        @names_registry
        |> Elixir.Registry.lookup(session_id)
        |> Enum.flat_map(fn
          {pid, %{registry_pid: ^registry_pid} = meta} ->
            [{pid, Map.delete(meta, :registry_pid)}]

          _entry ->
            []
        end)
    end
  end

  @doc "List sessions for the given owner."
  @spec list(Owner.t(), GenServer.server()) :: [session_meta()]
  def list(owner, registry \\ __MODULE__) when is_map(owner) do
    GenServer.call(registry, {:list, owner})
  end

  @doc "Mark a session as explicitly closed; actual removal happens on `:DOWN`."
  @spec mark_closed(String.t(), term(), GenServer.server()) :: :ok
  def mark_closed(session_id, reason, registry \\ __MODULE__) when is_binary(session_id) do
    GenServer.cast(registry, {:mark_closed, session_id, reason})
  end

  @impl GenServer
  def handle_call({:start_session, owner, opts}, _from, state) do
    config = Config.get()
    owner_hash = Owner.fingerprint(owner)

    cond do
      map_size(state.sessions) >= config.max_sessions ->
        {:reply, {:error, :max_sessions_exceeded}, state}

      Map.has_key?(state.sessions, Map.get(opts, :session_id)) ->
        {:reply, {:error, :session_id_collision}, state}

      owner_count(state, owner_hash) >= config.max_sessions_per_owner ->
        {:reply, {:error, :max_sessions_per_owner_exceeded}, state}

      true ->
        start_child(owner, owner_hash, opts, state)
    end
  end

  def handle_call({:lookup, session_id}, _from, state) do
    cond do
      Map.has_key?(state.sessions, session_id) ->
        {:reply, {:ok, Map.fetch!(state.sessions, session_id)}, state}

      Map.has_key?(state.tombstones, session_id) ->
        {:reply, {:error, :session_closed}, state}

      true ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  def handle_call({:list, owner}, _from, state) do
    owner_hash = Owner.fingerprint(owner)
    ids = Map.get(state.by_owner, owner_hash, MapSet.new())

    sessions =
      ids
      |> Enum.flat_map(fn id ->
        case Map.fetch(state.sessions, id) do
          {:ok, meta} -> [meta]
          :error -> []
        end
      end)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    {:reply, sessions, state}
  end

  @impl GenServer
  def handle_cast({:mark_closed, session_id, reason}, state) do
    tombstone = %{closed_at: DateTime.utc_now(), reason: reason}
    {:noreply, %{state | tombstones: put_tombstone(state.tombstones, session_id, tombstone)}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {session_id, monitors} ->
        {meta, sessions} = Map.pop(state.sessions, session_id)
        state = %{state | sessions: sessions, monitors: monitors}

        state =
          if meta do
            state
            |> remove_owner_index(meta.owner_hash, session_id)
            |> maybe_tombstone(session_id, reason)
          else
            state
          end

        {:noreply, state}
    end
  end

  defp start_child(owner, owner_hash, opts, state) do
    id = Map.get(opts, :session_id) || generate_id()
    title = string_or_nil(Map.get(opts, :title))
    mode = parse_mode(Map.get(opts, :mode))
    ttl_ms = Config.clamp_ttl_ms(Map.get(opts, :ttl_ms))
    created_at = DateTime.utc_now()

    meta = %{
      id: id,
      owner: owner,
      owner_hash: owner_hash,
      title: title,
      mode: mode,
      created_at: created_at
    }

    child_opts =
      [
        id: id,
        owner: owner,
        title: title,
        mode: mode,
        ttl_ms: ttl_ms,
        limits: Config.session_limits(),
        registry: self()
      ]
      |> maybe_put_name(state.names_registry, id, Map.put(meta, :registry_pid, self()))

    case Supervisor.start_session(child_opts, state.session_supervisor) do
      {:ok, pid} ->
        register_started_child(pid, meta, state)

      {:ok, pid, _info} ->
        register_started_child(pid, meta, state)

      {:error, reason} ->
        {:reply, {:error, %{reason: :sessions_unavailable, detail: inspect(reason)}}, state}
    end
  end

  defp register_started_child(pid, meta_without_pid, state) do
    ref = Process.monitor(pid)
    meta = Map.put(meta_without_pid, :pid, pid)

    state =
      state
      |> put_in([Access.key!(:sessions), meta.id], meta)
      |> put_in([Access.key!(:monitors), ref], meta.id)
      |> add_owner_index(meta.owner_hash, meta.id)

    :telemetry.execute([:ptc_lisp, :session, :start], %{count: 1}, %{
      session_id: meta.id,
      owner_hash: meta.owner_hash,
      mode: meta.mode
    })

    {:reply, {:ok, meta}, state}
  end

  defp maybe_put_name(child_opts, nil, _id, _meta), do: child_opts

  defp maybe_put_name(child_opts, names_registry, id, meta) do
    Keyword.put(child_opts, :name, {:via, Elixir.Registry, {names_registry, id, meta}})
  end

  defp default_names_registry(__MODULE__), do: @names_registry
  defp default_names_registry(_name), do: nil

  defp owner_count(state, owner_hash) do
    state.by_owner
    |> Map.get(owner_hash, MapSet.new())
    |> case do
      nil -> MapSet.new()
      set -> set
    end
    |> MapSet.size()
  end

  defp add_owner_index(state, owner_hash, session_id) do
    update_in(state.by_owner[owner_hash], fn
      nil -> MapSet.new([session_id])
      set -> MapSet.put(set, session_id)
    end)
  end

  defp remove_owner_index(state, owner_hash, session_id) do
    by_owner =
      case Map.get(state.by_owner, owner_hash) do
        nil ->
          state.by_owner

        set ->
          updated = MapSet.delete(set, session_id)

          if MapSet.size(updated) == 0 do
            Map.delete(state.by_owner, owner_hash)
          else
            Map.put(state.by_owner, owner_hash, updated)
          end
      end

    %{state | by_owner: by_owner}
  end

  defp maybe_tombstone(state, session_id, reason) when reason in [:normal, :shutdown] do
    Map.update!(state, :tombstones, fn tombstones ->
      tombstone = %{closed_at: DateTime.utc_now(), reason: reason}

      if Map.has_key?(tombstones, session_id),
        do: tombstones,
        else: put_tombstone(tombstones, session_id, tombstone)
    end)
  end

  defp maybe_tombstone(state, _session_id, _reason), do: state

  defp put_tombstone(tombstones, session_id, tombstone) do
    tombstones
    |> Map.put(session_id, tombstone)
    |> prune_tombstones()
  end

  defp prune_tombstones(tombstones) when map_size(tombstones) <= @max_tombstones, do: tombstones

  defp prune_tombstones(tombstones) do
    tombstones
    |> Enum.sort_by(fn {_id, tombstone} -> tombstone.closed_at end, {:desc, DateTime})
    |> Enum.take(@max_tombstones)
    |> Map.new()
  end

  defp generate_id do
    "ptcs_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp parse_mode("write_capable"), do: :write_capable
  defp parse_mode(:write_capable), do: :write_capable
  defp parse_mode(_other), do: :read_only
end
