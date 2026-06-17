defmodule PtcRunner.PreludeStore.Server do
  @moduledoc false

  use GenServer

  alias PtcRunner.PreludeCandidate
  alias PtcRunner.PreludeStore

  @call_timeout 5_000

  @spec start_link(keyword()) :: {:ok, PreludeStore.t()} | {:error, term()}
  def start_link(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        {:ok, %PreludeStore{pid: pid, opts: opts}}

      other ->
        other
    end
  end

  @spec list(PreludeStore.t()) :: [map()]
  def list(%PreludeStore{pid: pid}), do: GenServer.call(pid, :list, @call_timeout)

  @spec history(PreludeStore.t(), String.t()) :: {:ok, [map()]} | {:error, map()}
  def history(%PreludeStore{pid: pid}, id), do: GenServer.call(pid, {:history, id}, @call_timeout)

  @spec read(PreludeStore.t(), map()) :: {:ok, PreludeCandidate.t()} | {:error, map()}
  def read(%PreludeStore{pid: pid}, ref), do: GenServer.call(pid, {:read, ref}, @call_timeout)

  @spec append(PreludeStore.t(), PreludeCandidate.t(), String.t() | nil) ::
          {:ok, map()} | {:error, map()}
  def append(%PreludeStore{pid: pid}, candidate, parent_checksum) do
    GenServer.call(pid, {:append, candidate, parent_checksum}, @call_timeout)
  end

  @spec set_default(PreludeStore.t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def set_default(%PreludeStore{pid: pid}, ref, metadata) do
    GenServer.call(pid, {:set_default, ref, metadata}, @call_timeout)
  end

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:ordered_set, :private])

    {:ok,
     %{
       table: table,
       max_versions: Keyword.get(opts, :max_versions, 1_000),
       max_ids: Keyword.get(opts, :max_ids, 1_000),
       max_total_bytes: Keyword.get(opts, :max_total_bytes, 10 * 1024 * 1024),
       total_bytes: 0,
       version_bytes: %{},
       current_bytes: %{},
       latest_bytes: %{},
       pinned_versions: %{}
     }}
  end

  @impl true
  def handle_call(:list, _from, state) do
    ids =
      state.table
      |> :ets.match({{:current, :"$1"}, :_})
      |> List.flatten()
      |> Enum.sort()

    rows = Enum.map(ids, &list_row(state.table, &1))
    {:reply, rows, state}
  end

  def handle_call({:read, %{id: id} = ref}, _from, state) do
    result =
      with {:ok, version} <- resolve_version(state.table, ref),
           {:ok, candidate} <- lookup_version(state.table, id, version),
           :ok <- verify_checksum(candidate, Map.get(ref, :checksum)) do
        {:ok, candidate}
      end

    {:reply, result, state}
  end

  def handle_call({:history, id}, _from, state) do
    versions = retained_versions(state.table, id)

    result =
      case versions do
        [] ->
          {:error, %{reason: :not_found, message: "prelude `#{id}` not found"}}

        versions ->
          {:ok, Enum.map(versions, &history_row(state.table, id, &1))}
      end

    {:reply, result, state}
  end

  def handle_call({:append, %PreludeCandidate{} = candidate, parent_checksum}, _from, state) do
    {result, state} =
      with :ok <- recheck_parent(state.table, candidate.id, parent_checksum),
           :ok <- check_id_bound(state.table, candidate.id, state.max_ids) do
        append_candidate(state, candidate)
      else
        {:error, _} = error -> {error, state}
      end

    {:reply, result, state}
  end

  def handle_call({:set_default, %{id: id} = ref, metadata}, _from, state) do
    selected_at = DateTime.utc_now()

    {result, state} =
      with {:ok, version} <- resolve_version(state.table, ref),
           {:ok, candidate} <- lookup_version(state.table, id, version),
           :ok <- verify_checksum(candidate, Map.get(ref, :checksum)) do
        set_current(state, id, version, selected_at, metadata)
      else
        {:error, _} = error -> {error, state}
      end

    {:reply, result, state}
  end

  defp list_row(table, id) do
    {:ok, current_version} = resolve_version(table, %{id: id})
    {:ok, current} = lookup_version(table, id, current_version)
    latest_version = latest_version(table, id)
    current_entry = current_entry(table, id)

    current
    |> candidate_fields()
    |> Map.merge(%{
      current_version: current_version,
      latest_version: latest_version,
      versions_count: retained_version_count(table, id),
      origin: PreludeCandidate.public_origin(current.origin),
      default_metadata: PreludeCandidate.public_metadata(current_entry.metadata),
      created_at: first_created_at(table, id),
      updated_at: current_entry.updated_at
    })
  end

  defp history_row(table, id, version) do
    {:ok, candidate} = lookup_version(table, id, version)
    current_version = current_version(table, id)

    candidate
    |> candidate_fields()
    |> Map.merge(%{
      version: version,
      current: version == current_version,
      latest: version == latest_version(table, id),
      origin: PreludeCandidate.public_origin(candidate.origin),
      created_at: candidate.created_at
    })
  end

  defp selection_row(table, candidate, selected_at, metadata) do
    candidate
    |> candidate_fields()
    |> Map.merge(%{
      current_version: candidate.version,
      latest_version: latest_version(table, candidate.id),
      metadata: PreludeCandidate.public_metadata(metadata),
      updated_at: selected_at
    })
  end

  defp resolve_version(table, %{id: id, version: version}) when is_integer(version) do
    case lookup_version(table, id, version) do
      {:ok, _candidate} -> {:ok, version}
      {:error, _} = error -> error
    end
  end

  defp resolve_version(table, %{id: id}) do
    case current_version(table, id) do
      0 -> {:error, %{reason: :not_found, message: "prelude `#{id}` not found"}}
      version -> {:ok, version}
    end
  end

  defp lookup_version(table, id, version) do
    case :ets.lookup(table, {:version, id, version}) do
      [{{:version, ^id, ^version}, candidate}] -> {:ok, candidate}
      [] -> {:error, %{reason: :not_found, message: "prelude `#{id}@#{version}` not found"}}
    end
  end

  defp verify_checksum(_candidate, nil), do: :ok

  defp verify_checksum(%PreludeCandidate{} = candidate, checksum) do
    if PreludeCandidate.checksum(candidate) == checksum do
      :ok
    else
      {:error,
       %{
         reason: :checksum_mismatch,
         message: "prelude checksum mismatch",
         expected_checksum: checksum,
         actual_checksum: PreludeCandidate.checksum(candidate)
       }}
    end
  end

  defp recheck_parent(_table, _id, nil), do: :ok

  defp recheck_parent(table, id, checksum) do
    case resolve_version(table, %{id: id}) do
      {:ok, version} ->
        {:ok, current} = lookup_version(table, id, version)

        if PreludeCandidate.checksum(current) == checksum do
          :ok
        else
          stale_base(checksum, PreludeCandidate.checksum(current))
        end

      {:error, %{reason: :not_found}} ->
        stale_base(checksum, nil)
    end
  end

  defp check_id_bound(table, id, max_ids) do
    if known_id?(table, id) or id_count(table) < max_ids do
      :ok
    else
      {:error,
       %{
         reason: :id_limit_exceeded,
         message: "prelude store reached id limit #{max_ids}",
         limit: max_ids
       }}
    end
  end

  defp append_candidate(state, candidate) do
    table = state.table
    version = latest_version(table, candidate.id) + 1
    candidate = %{candidate | version: version, created_at: DateTime.utc_now()}
    delete_versions = prunable_versions(state, candidate.id, version)
    reclaimed_bytes = reclaimed_bytes(state.version_bytes, candidate.id, delete_versions)
    version_row = version_row(candidate)
    latest_row = latest_row(candidate.id, version)

    current_row = current_row(candidate.id, version, candidate.created_at, candidate.metadata)

    version_row_bytes = row_bytes(version_row)
    latest_row_bytes = row_bytes(latest_row)
    current_row_bytes = row_bytes(current_row)

    projected_total =
      state.total_bytes - reclaimed_bytes - current_bytes(state, candidate.id) -
        latest_bytes(state, candidate.id) + version_row_bytes + current_row_bytes +
        latest_row_bytes

    if projected_total > state.max_total_bytes do
      {{:error,
        %{
          reason: :store_bytes_exceeded,
          message: "prelude store would exceed #{state.max_total_bytes} retained bytes",
          limit_bytes: state.max_total_bytes
        }}, state}
    else
      Enum.each(delete_versions, &:ets.delete(table, {:version, candidate.id, &1}))

      :ets.insert(table, version_row)
      :ets.insert(table, latest_row)
      :ets.insert(table, current_row)

      version_bytes =
        state.version_bytes
        |> Map.drop(Enum.map(delete_versions, &{candidate.id, &1}))
        |> Map.put({candidate.id, version}, version_row_bytes)

      state = %{
        state
        | total_bytes: projected_total,
          version_bytes: version_bytes,
          current_bytes: Map.put(state.current_bytes, candidate.id, current_row_bytes),
          latest_bytes: Map.put(state.latest_bytes, candidate.id, latest_row_bytes)
      }

      {{:ok, Map.put(candidate_fields(candidate), :version, candidate.version)}, state}
    end
  end

  defp candidate_fields(%PreludeCandidate{} = candidate) do
    %{
      id: candidate.id,
      checksum: PreludeCandidate.checksum(candidate),
      namespaces: candidate.compiled.namespaces,
      exports: PreludeCandidate.export_names(candidate),
      metadata: PreludeCandidate.public_metadata(candidate.metadata)
    }
  end

  defp prunable_versions(state, id, new_version) do
    keep =
      new_version
      |> retained_version_ring(state.max_versions, pinned_versions(state, id))
      |> MapSet.new()

    state.table
    |> retained_versions(id)
    |> Enum.reject(&MapSet.member?(keep, &1))
  end

  defp latest_ring(_new_version, count) when count <= 0, do: []

  defp latest_ring(new_version, count),
    do: max(1, new_version - count + 1)..new_version |> Enum.to_list()

  defp reclaimed_bytes(version_bytes, id, versions) do
    Enum.reduce(versions, 0, fn version, acc ->
      acc + Map.get(version_bytes, {id, version}, 0)
    end)
  end

  defp retained_version_ring(new_version, max_versions, pinned_versions) do
    pinned_versions
    |> MapSet.to_list()
    |> Kernel.++(latest_ring(new_version, max_versions))
    |> Enum.uniq()
  end

  defp current_bytes(state, id), do: Map.get(state.current_bytes, id, 0)
  defp latest_bytes(state, id), do: Map.get(state.latest_bytes, id, 0)
  defp pinned_versions(state, id), do: Map.get(state.pinned_versions, id, MapSet.new())

  defp version_row(candidate), do: {{:version, candidate.id, candidate.version}, candidate}
  defp latest_row(id, version), do: {{:latest, id}, version}

  defp current_row(id, version, updated_at, metadata),
    do: {{:current, id}, %{version: version, updated_at: updated_at, metadata: metadata}}

  defp row_bytes(row), do: :erlang.external_size(row)

  defp latest_version(table, id) do
    case :ets.lookup(table, {:latest, id}) do
      [{{:latest, ^id}, version}] ->
        version

      [] ->
        current_version(table, id)
    end
  end

  defp retained_versions(table, id) do
    table
    |> :ets.match({{:version, id, :"$1"}, :_})
    |> List.flatten()
    |> Enum.sort()
  end

  defp retained_version_count(table, id), do: table |> retained_versions(id) |> length()

  defp current_version(table, id), do: current_entry(table, id).version

  defp current_entry(table, id) do
    case :ets.lookup(table, {:current, id}) do
      [{{:current, ^id}, %{version: version, updated_at: updated_at, metadata: metadata}}] ->
        %{version: version, updated_at: updated_at, metadata: metadata}

      [] ->
        %{version: 0, updated_at: nil, metadata: %{}}
    end
  end

  defp set_current(state, id, version, updated_at, metadata) do
    row = current_row(id, version, updated_at, metadata)
    row_bytes = row_bytes(row)
    projected_total = state.total_bytes - current_bytes(state, id) + row_bytes

    if projected_total > state.max_total_bytes do
      {{:error,
        %{
          reason: :store_bytes_exceeded,
          message: "prelude store would exceed #{state.max_total_bytes} retained bytes",
          limit_bytes: state.max_total_bytes
        }}, state}
    else
      :ets.insert(state.table, row)

      state = %{
        state
        | total_bytes: projected_total,
          current_bytes: Map.put(state.current_bytes, id, row_bytes),
          pinned_versions:
            Map.update(state.pinned_versions, id, MapSet.new([version]), &MapSet.put(&1, version))
      }

      {:ok, candidate} = lookup_version(state.table, id, version)
      {{:ok, selection_row(state.table, candidate, updated_at, metadata)}, state}
    end
  end

  defp first_created_at(table, id) do
    case retained_versions(table, id) do
      [version | _] ->
        {:ok, candidate} = lookup_version(table, id, version)
        candidate.created_at

      [] ->
        nil
    end
  end

  defp known_id?(table, id), do: current_version(table, id) > 0 or latest_version(table, id) > 0

  defp id_count(table) do
    table
    |> :ets.match({{:latest, :"$1"}, :_})
    |> List.flatten()
    |> Enum.count()
  end

  defp stale_base(expected, actual) do
    {:error,
     %{
       reason: :stale_base,
       message: "parent_checksum does not match current prelude checksum",
       expected_parent_checksum: expected,
       actual_parent_checksum: actual
     }}
  end
end
