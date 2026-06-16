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

  @spec read(PreludeStore.t(), map()) :: {:ok, PreludeCandidate.t()} | {:error, map()}
  def read(%PreludeStore{pid: pid}, ref), do: GenServer.call(pid, {:read, ref}, @call_timeout)

  @spec append(PreludeStore.t(), PreludeCandidate.t(), String.t() | nil) ::
          {:ok, map()} | {:error, map()}
  def append(%PreludeStore{pid: pid}, candidate, parent_checksum) do
    GenServer.call(pid, {:append, candidate, parent_checksum}, @call_timeout)
  end

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:ordered_set, :private])

    {:ok,
     %{
       table: table,
       max_versions: Keyword.get(opts, :max_versions, 1_000)
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

  def handle_call({:append, %PreludeCandidate{} = candidate, parent_checksum}, _from, state) do
    result =
      with :ok <- recheck_parent(state.table, candidate.id, parent_checksum),
           :ok <- check_version_bound(state.table, candidate.id, state.max_versions) do
        append_candidate(state.table, candidate)
      end

    {:reply, result, state}
  end

  defp list_row(table, id) do
    {:ok, current_version} = resolve_version(table, %{id: id})
    {:ok, current} = lookup_version(table, id, current_version)
    latest_version = latest_version(table, id)

    %{
      id: id,
      current_version: current_version,
      latest_version: latest_version,
      versions_count: latest_version,
      checksum: PreludeCandidate.checksum(current),
      namespaces: current.compiled.namespaces,
      exports: PreludeCandidate.export_names(current),
      origin: PreludeCandidate.public_origin(current.origin),
      metadata: PreludeCandidate.public_metadata(current.metadata),
      created_at: first_created_at(table, id),
      updated_at: current.created_at
    }
  end

  defp resolve_version(table, %{id: id, version: version}) when is_integer(version) do
    case lookup_version(table, id, version) do
      {:ok, _candidate} -> {:ok, version}
      {:error, _} = error -> error
    end
  end

  defp resolve_version(table, %{id: id}) do
    case :ets.lookup(table, {:current, id}) do
      [{{:current, ^id}, version}] -> {:ok, version}
      [] -> {:error, %{reason: :not_found, message: "prelude `#{id}` not found"}}
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

  defp check_version_bound(table, id, max_versions) do
    latest = latest_version(table, id)

    if latest >= max_versions do
      {:error,
       %{
         reason: :version_limit_exceeded,
         message: "prelude `#{id}` reached version limit #{max_versions}",
         limit: max_versions
       }}
    else
      :ok
    end
  end

  defp append_candidate(table, candidate) do
    version = latest_version(table, candidate.id) + 1
    candidate = %{candidate | version: version, created_at: DateTime.utc_now()}

    :ets.insert(table, {{:version, candidate.id, version}, candidate})
    :ets.insert(table, {{:current, candidate.id}, version})

    {:ok,
     %{
       id: candidate.id,
       version: candidate.version,
       checksum: PreludeCandidate.checksum(candidate),
       namespaces: candidate.compiled.namespaces,
       exports: PreludeCandidate.export_names(candidate),
       metadata: PreludeCandidate.public_metadata(candidate.metadata)
     }}
  end

  defp latest_version(table, id) do
    case :ets.lookup(table, {:current, id}) do
      [{{:current, ^id}, version}] -> version
      [] -> 0
    end
  end

  defp first_created_at(table, id) do
    case lookup_version(table, id, 1) do
      {:ok, candidate} -> candidate.created_at
      {:error, _} -> nil
    end
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
