defmodule PtcGateway.PrivateAudit do
  @moduledoc """
  Opaque owner for a private bounded append-only audit spool.

  Startup resolves and validates the directory ancestry, rejects a linked audit
  directory, creates missing directories owner-only, and durably opens a new
  0600 file before pruning oldest closed files down to the retention bound. A
  startup that fails after opening its replacement removes it. A
  create/append/sync probe finishes before startup returns. The probe is
  removed; active files contain no invented audit record. Files use increasing
  numeric names and are never truncated.
  The directory is exclusively locked for this owner's lifetime. Per-call
  records, fencing and shutdown policy belong to the execution integration.

  Appends share a sync after 2 ms, 64 records or 64 KiB (also bounded by the
  configured file size). A larger valid record is synced alone. Replies follow
  the successful sync; failures refuse every pending caller and stop the owner.
  Normal shutdown flushes pending records through the same barrier.
  """
  use GenServer
  use PtcGateway.OwnerStatusRedaction
  alias PtcRunner.Kernel.PrivateDirectory
  import Bitwise

  @batch_delay_ms 2
  @batch_records 64
  @batch_bytes 65_536

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @spec append(pid(), map()) :: :ok | {:error, :audit_unavailable}
  def append(owner, record), do: GenServer.call(owner, {:append, record}, :infinity)
  @doc false
  def child_spec(config),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, restart: :temporary}

  @impl true
  def init(config) do
    case open(config) do
      {:ok, state} ->
        {:ok,
         Map.merge(state, %{pending: [], count: 0, bytes: 0, timer: nil, sync: &:file.sync/1})}

      _ ->
        {:stop, :audit_unavailable}
    end
  end

  defp open(config) do
    directory = config["directory"]
    lock = Path.join(directory, ".gateway-lock")

    with :ok <- hierarchy(directory),
         {:ok, uid} <- PrivateDirectory.preflight_owner(Path.join(directory, "probe")),
         {:ok, %{type: :directory, uid: ^uid, mode: mode}} <- File.lstat(directory),
         true <- band(mode, 0o777) == 0o700,
         :ok <- PrivateDirectory.create(lock) do
      case open_locked(config, uid) do
        {:ok, state} ->
          {:ok, Map.put(state, :lock, lock)}

        _ ->
          File.rmdir(lock)
          {:error, :audit_unavailable}
      end
    else
      _ -> {:error, :audit_unavailable}
    end
  end

  defp hierarchy("/"), do: :ok

  defp hierarchy(path) do
    with :ok <- hierarchy(Path.dirname(path)) do
      case File.stat(path) do
        {:ok, %{type: :directory}} -> :ok
        {:error, :enoent} -> PrivateDirectory.create(path)
        _ -> {:error, :audit_unavailable}
      end
    end
  end

  defp open_locked(config, uid) do
    directory = config["directory"]

    with {:ok, names} <- File.ls(directory),
         {:ok, files} <-
           inventory(names -- [".gateway-lock"], directory, uid, config["max_file_bytes"]),
         sequence = Enum.reduce(files, 0, fn {n, _}, acc -> max(n, acc) end) + 1,
         true <- sequence < 100_000_000_000_000_000_000,
         path =
           Path.join(
             directory,
             String.pad_leading(Integer.to_string(sequence), 20, "0") <> ".jsonl"
           ),
         {:ok, io} <- File.open(path, [:raw, :binary, :append, :exclusive]) do
      case probe(io, path, directory) do
        :ok ->
          case retain(files, config["max_retained_files"] - 1, directory) do
            :ok ->
              {:ok, %{io: io, path: path, directory: directory, config: config}}

            _ ->
              discard(io, path)
          end

        _ ->
          discard(io, path)
      end
    else
      _ -> {:error, :audit_unavailable}
    end
  end

  # The replacement carries no record until the gateway serves a call, so a
  # startup that fails after opening it removes it again rather than leaving an
  # empty file to count against the next startup's retention bound.
  defp discard(io, path) do
    File.close(io)
    File.rm(path)
    {:error, :audit_unavailable}
  end

  defp inventory(names, directory, uid, max_bytes) do
    Enum.reduce_while(Enum.sort(names), {:ok, []}, fn name, {:ok, acc} ->
      path = Path.join(directory, name)

      with true <- Regex.match?(~r/\A[0-9]{20}\.jsonl\z/, name),
           {:ok, %{type: :regular, uid: ^uid, mode: mode, size: size, links: 1}} <-
             File.lstat(path),
           true <- band(mode, 0o777) == 0o600 and size <= max_bytes,
           {sequence, ".jsonl"} <- Integer.parse(name) do
        {:cont, {:ok, [{sequence, path} | acc]}}
      else
        _ -> {:halt, {:error, :audit_unavailable}}
      end
    end)
  end

  defp probe(io, path, directory) do
    with :ok <- File.chmod(path, 0o600),
         :ok <- append_probe(Path.join(directory, ".gateway-lock/probe")),
         :ok <- :file.sync(io) do
      sync_directory(directory)
    end
  end

  defp sync_directory(directory) do
    with {:ok, dir} <- :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      result = :file.sync(dir)
      closed = :file.close(dir)
      if result == :ok and closed == :ok, do: :ok, else: {:error, :audit_unavailable}
    end
  end

  defp retain(files, count, directory) do
    with :ok <- prune(files, count), do: sync_directory(directory)
  end

  defp append_probe(path) do
    case File.open(path, [:raw, :binary, :append, :exclusive]) do
      {:ok, probe} ->
        result =
          with :ok <- File.chmod(path, 0o600),
               :ok <- :file.write(probe, "probe\n"),
               do: :file.sync(probe)

        closed = File.close(probe)
        removed = File.rm(path)

        if result == :ok and closed == :ok and removed == :ok,
          do: :ok,
          else: {:error, :audit_unavailable}

      _ ->
        {:error, :audit_unavailable}
    end
  end

  # Rotation removes closed files oldest first, and only once the replacement is
  # durable. Narrowing max_retained_files therefore prunes down to the new bound
  # on the next startup, which is the deletion that bound asks for.
  defp prune(files, retain) do
    files
    |> Enum.sort()
    |> Enum.take(max(length(files) - retain, 0))
    |> Enum.reduce_while(:ok, fn {_, path}, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :audit_unavailable}}
      end
    end)
  end

  @impl true
  def handle_call({:append, record}, from, state) do
    with true <- audit_record?(record),
         {:ok, encoded} <- PtcRunner.Kernel.DeterministicJSON.encode(record),
         bytes = byte_size(encoded) + 1,
         true <- bytes <= state.config["max_file_bytes"] do
      case make_room(state, bytes) do
        {:ok, state} ->
          state = enqueue(state, from, encoded, bytes)

          if state.count >= @batch_records or state.bytes >= byte_limit(state),
            do: flush_reply(state),
            else: {:noreply, state}

        {:error, state} ->
          {:stop, :audit_unavailable, {:error, :audit_unavailable}, state}
      end
    else
      _ ->
        {:stop, :audit_unavailable, {:error, :audit_unavailable}, fail_pending(state)}
    end
  end

  @impl true
  def handle_info({:flush, token}, %{timer: {_, token}} = state), do: flush_reply(state)
  def handle_info({:flush, _stale}, state), do: {:noreply, state}

  defp byte_limit(state), do: min(@batch_bytes, state.config["max_file_bytes"])

  defp make_room(%{count: 0} = state, _bytes), do: {:ok, state}

  defp make_room(state, bytes) do
    if state.bytes + bytes > byte_limit(state), do: flush(state), else: {:ok, state}
  end

  defp enqueue(state, from, encoded, bytes) do
    timer = state.timer || new_timer()

    %{
      state
      | pending: [{from, [encoded, "\n"]} | state.pending],
        count: state.count + 1,
        bytes: state.bytes + bytes,
        timer: timer
    }
  end

  defp new_timer do
    token = make_ref()
    {Process.send_after(self(), {:flush, token}, @batch_delay_ms), token}
  end

  defp flush_reply(state) do
    case flush(state) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:stop, :audit_unavailable, state}
    end
  end

  defp flush(%{count: 0} = state), do: {:ok, state}

  defp flush(state) do
    case ensure_space(state, state.bytes) do
      {:ok, state} ->
        records = state.pending |> Enum.reverse() |> Enum.map(&elem(&1, 1))

        with :ok <- :file.write(state.io, records),
             :ok <- state.sync.(state.io) do
          {:ok, reply_pending(state, :ok)}
        else
          _ -> {:error, fail_pending(state)}
        end

      _ ->
        {:error, fail_pending(state)}
    end
  end

  defp fail_pending(state), do: reply_pending(state, {:error, :audit_unavailable})

  defp reply_pending(state, result) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    for {from, _} <- Enum.reverse(state.pending), do: GenServer.reply(from, result)
    %{state | pending: [], count: 0, bytes: 0, timer: nil}
  end

  defp ensure_space(state, bytes) do
    with {:ok, %{size: size}} <- File.stat(state.path) do
      if size + bytes <= state.config["max_file_bytes"], do: {:ok, state}, else: rotate(state)
    end
  end

  defp rotate(state) do
    name = Path.basename(state.path, ".jsonl")

    with {sequence, ""} <- Integer.parse(name),
         true <- sequence < 99_999_999_999_999_999_999,
         path <-
           Path.join(
             state.directory,
             String.pad_leading(Integer.to_string(sequence + 1), 20, "0") <> ".jsonl"
           ),
         {:ok, io} <- File.open(path, [:raw, :binary, :append, :exclusive]),
         :ok <- File.chmod(path, 0o600),
         :ok <- :file.sync(io),
         :ok <- sync_directory(state.directory),
         :ok <- File.close(state.io),
         {:ok, names} <- File.ls(state.directory),
         {:ok, uid} <- PrivateDirectory.preflight_owner(path),
         {:ok, files} <-
           inventory(
             names -- [".gateway-lock", Path.basename(path)],
             state.directory,
             uid,
             state.config["max_file_bytes"]
           ),
         :ok <- prune(files, state.config["max_retained_files"] - 1),
         :ok <- sync_directory(state.directory) do
      {:ok, %{state | io: io, path: path}}
    else
      _ -> {:error, :audit_unavailable}
    end
  end

  defp audit_record?(record) when is_map(record) do
    Map.keys(record) |> Enum.sort() ==
      Enum.sort(
        ~w(call_id run_ref tool_name started_at ended_at outcome_code dispatch_state write_effects_may_have_occurred disconnected cleanup_status)
      ) and
      is_binary(record["call_id"]) and
      is_binary(record["run_ref"]) and
      is_binary(record["tool_name"]) and
      is_binary(record["started_at"]) and is_binary(record["ended_at"]) and
      is_binary(record["outcome_code"]) and is_binary(record["dispatch_state"]) and
      is_boolean(record["write_effects_may_have_occurred"]) and
      is_boolean(record["disconnected"]) and is_binary(record["cleanup_status"])
  end

  defp audit_record?(_record), do: false

  @impl true
  def terminate(reason, state) do
    state =
      if reason in [:normal, :shutdown] do
        {_, state} = flush(state)
        state
      else
        fail_pending(state)
      end

    File.close(state.io)
    File.rmdir(state.lock)
    :ok
  end
end
