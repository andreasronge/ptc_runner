defmodule PtcGateway.EventLog do
  @moduledoc false
  use GenServer
  use PtcGateway.OwnerStatusRedaction
  import Bitwise
  alias PtcRunner.Kernel.PrivateDirectory

  @capacity 256
  @interval_ms 1_000

  def start_link(config), do: GenServer.start_link(__MODULE__, config)
  def callbacks(nil, _tool), do: nil

  def callbacks(handle, tool) do
    %{
      emit: fn record -> emit(handle, Map.put(record, :tool, tool)) end,
      observe: fn handles -> GenServer.call(elem(handle, 0), {:observe, tool, handles}) end
    }
  end

  def shutdown(owner), do: GenServer.call(owner, :shutdown)
  def checkpoint(owner), do: GenServer.call(owner, :checkpoint)
  def close(owner), do: GenServer.call(owner, :close)
  def handle(owner), do: GenServer.call(owner, :handle)

  # Reserve before sending: even a stalled file writer has a bounded mailbox.
  # Counters use a fixed, startup-registered table instead of queued messages.
  def emit(nil, _record), do: :ok

  def emit({owner, slots, counters}, record) do
    key = {record[:tool], record[:provider]}

    if :atomics.add_get(slots, 1, 1) <= @capacity do
      send(owner, {:event, record})
    else
      :atomics.sub(slots, 1, 1)
      increment(counters, key, :dropped_events)
    end

    :ok
  end

  def counter(nil, _tool, _provider, _kind), do: :ok

  def counter({_owner, _slots, table}, tool, provider, kind),
    do: increment(table, {tool, provider}, kind)

  defp increment(table, key, kind) do
    :ets.update_counter(table, {key, kind}, {2, 1})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def register(nil, _tool, _providers), do: :ok

  def register({_owner, _slots, table}, tool, providers) do
    for provider <- providers,
        kind <- [:busy, :detached, :settlement_timeout, :dropped_events],
        do: :ets.insert_new(table, {{{tool, provider}, kind}, 0})

    :ok
  end

  @impl true
  def init(config) do
    directory = config["directory"]

    with :ok <- ensure_directory(directory),
         {:ok, uid} <- directory_owner(directory),
         {:ok, files} <- inventory(directory, uid, config["max_file_bytes"]),
         :ok <- PrivateDirectory.create(Path.join(directory, ".gateway-lock")) do
      counters = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
      slots = :atomics.new(1, signed: true)

      state = %{
        directory: directory,
        uid: uid,
        config: config,
        files: files,
        start_ref:
          String.pad_leading(
            String.downcase(Integer.to_string(System.system_time(:microsecond), 16)),
            16,
            "0"
          ) <>
            Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        sequence: 0,
        io: nil,
        path: nil,
        size: 0,
        counters: counters,
        slots: slots,
        transports: %{},
        shutting_down: false
      }

      register({self(), slots, counters}, nil, [nil])
      Process.send_after(self(), :interval, @interval_ms)
      {:ok, state}
    else
      _ -> {:stop, :artifact_root_unavailable}
    end
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:error, :enoent} -> PrivateDirectory.create(path)
      {:ok, %{type: :directory}} -> :ok
      _ -> {:error, :artifact_root_unavailable}
    end
  end

  defp directory_owner(directory) do
    with {:ok, uid} <- PrivateDirectory.preflight_owner(Path.join(directory, "probe")),
         {:ok, %{type: :directory, uid: ^uid, mode: mode}} <- File.lstat(directory),
         true <- band(mode, 0o777) == 0o700 do
      {:ok, uid}
    else
      _ -> {:error, :artifact_root_unavailable}
    end
  end

  defp inventory(directory, uid, max_file_bytes) do
    with {:ok, names} <- File.ls(directory) do
      Enum.reduce_while(names -- [".gateway-lock"], {:ok, []}, fn name, {:ok, files} ->
        path = Path.join(directory, name)

        with true <- Regex.match?(~r/\A[0-9a-f]{32}-[0-9]{20}\.jsonl\z/, name),
             {:ok, %{type: :regular, uid: ^uid, mode: mode, links: 1, size: size}} <-
               File.lstat(path, time: :posix),
             true <- band(mode, 0o777) == 0o600 and size <= max_file_bytes do
          {:cont, {:ok, [{name, path} | files]}}
        else
          _ -> {:halt, {:error, :artifact_root_unavailable}}
        end
      end)
    end
  end

  @impl true
  def handle_call(:handle, _from, state),
    do: {:reply, {self(), state.slots, state.counters}, state}

  def handle_call(:shutdown, _from, %{shutting_down: true} = state), do: {:reply, :ok, state}

  def handle_call(:shutdown, _from, state),
    do: {:reply, :ok, %{snapshot_tails(state) | shutting_down: true}}

  def handle_call(:checkpoint, _from, state), do: {:reply, :ok, snapshot_tails(state)}
  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, drain_events(state)}

  def handle_call({:observe, tool, handles}, _from, state) do
    handle = {self(), state.slots, state.counters}
    register(handle, tool, Enum.map(handles, & &1.provider_name))

    transports =
      Enum.reduce(handles, state.transports, fn transport, acc ->
        provider = transport.provider_name

        events = %{
          counter: fn kind ->
            counter(handle, tool, provider, kind)
          end
        }

        observe_transport(transport.pid, events)
        Map.put(acc, Process.monitor(transport.pid), {tool, provider, transport})
      end)

    {:reply, :ok, %{state | transports: transports}}
  end

  @impl true
  def handle_info({:event, record}, state) do
    state = write_record(state, record)
    :atomics.sub(state.slots, 1, 1)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.transports, ref) do
      {nil, _} ->
        {:noreply, state}

      {{tool, provider, transport}, remaining} ->
        state = %{state | transports: remaining}
        snapshot = transport_snapshot(transport)

        classified =
          if snapshot[:finish_reason] || snapshot[:failed?],
            do: {:mcp_transport_error, snapshot},
            else: reason

        state =
          write_record(state, %{
            kind: :transport,
            tool: tool,
            provider: provider,
            fault: fault(classified),
            exit_status: exit_status(classified)
          })

        state =
          if state.shutting_down do
            state
          else
            write_record(state, %{
              kind: :readiness,
              tool: tool,
              provider: provider,
              transition: :not_ready,
              cause: :provider_runtime_lost
            })
          end

        {:noreply, stderr_tail(state, tool, provider, transport)}
    end
  end

  def handle_info(:interval, state) do
    state = flush_counters(state)
    Process.send_after(self(), :interval, @interval_ms)
    {:noreply, state}
  end

  defp flush_counters(state) do
    Enum.reduce(:ets.tab2list(state.counters), state, fn
      {{key, kind}, count}, acc when count > 0 ->
        # Subtract exactly the snapshot; concurrent increments belong to the
        # next interval. Restore on failure, including dropped-event reports.
        :ets.update_counter(state.counters, {key, kind}, {2, -count})
        {tool, provider} = key

        record = %{
          kind: kind,
          tool: tool,
          provider: provider,
          count: count,
          interval_ms: @interval_ms
        }

        case write(acc, record) do
          {:ok, next} ->
            next

          {:error, next} ->
            :ets.update_counter(state.counters, {key, kind}, {2, count})
            if kind != :dropped_events, do: increment(state.counters, key, :dropped_events)
            next
        end

      _, acc ->
        acc
    end)
  end

  defp write_record(state, record) do
    case write(state, record) do
      {:ok, next} ->
        next

      {:error, next} ->
        increment(state.counters, {record[:tool], record[:provider]}, :dropped_events)
        next
    end
  end

  defp write(state, record) do
    if PtcGateway.EventRecord.valid?(record),
      do: write_valid(state, record),
      else: {:error, state}
  end

  defp write_valid(state, record) do
    bytes =
      Jason.encode!(Map.put(record, :timestamp, DateTime.to_iso8601(DateTime.utc_now()))) <> "\n"

    with true <- byte_size(bytes) <= state.config["max_file_bytes"],
         {:ok, next} <- room(state, byte_size(bytes)) do
      case :file.write(next.io, bytes) do
        :ok -> {:ok, %{next | size: next.size + byte_size(bytes)}}
        _ -> {:error, close_file(next)}
      end
    else
      {:error, next} when is_map(next) -> {:error, next}
      _ -> {:error, close_file(state)}
    end
  end

  defp room(%{io: io, size: size} = state, bytes) when not is_nil(io) do
    if size + bytes <= state.config["max_file_bytes"],
      do: {:ok, state},
      else: rotate(close_file(state))
  end

  defp room(state, _bytes), do: rotate(state)

  defp rotate(state) do
    sequence = state.sequence + 1

    name =
      state.start_ref <>
        "-" <> String.pad_leading(Integer.to_string(sequence), 20, "0") <> ".jsonl"

    path = Path.join(state.directory, name)

    with {:ok, uid} <- directory_owner(state.directory),
         true <- uid == state.uid,
         {:ok, files} <- inventory(state.directory, state.uid, state.config["max_file_bytes"]),
         {:ok, io} <- File.open(path, [:raw, :binary, :append, :exclusive]) do
      next = %{state | sequence: sequence, io: io, path: path, size: 0}

      case File.chmod(path, 0o600) do
        :ok ->
          files = Enum.sort(files)

          {remove, keep} =
            Enum.split(files, max(length(files) - state.config["max_retained_files"] + 1, 0))

          if Enum.all?(remove, fn {_, file} -> File.rm(file) == :ok end) do
            {:ok, %{next | files: keep ++ [{name, path}]}}
          else
            File.close(io)
            File.rm(path)
            {:error, state}
          end

        _ ->
          File.close(io)
          File.rm(path)
          {:error, state}
      end
    else
      _ -> {:error, state}
    end
  end

  defp close_file(%{io: nil} = state), do: state

  defp close_file(state) do
    File.close(state.io)
    %{state | io: nil, path: nil, size: 0}
  end

  defp observe_transport(pid, events) do
    GenServer.call(pid, {:events, events})
  catch
    :exit, _ -> :ok
  end

  defp transport_snapshot(%{__struct__: PtcRunner.Kernel.MCPStdioTransport} = transport),
    do: PtcRunner.Kernel.MCPStdioTransport.event_snapshot(transport)

  defp transport_snapshot(_), do: %{}

  defp fault(reason) when reason in [:killed, :normal, :shutdown], do: reason

  defp fault({:mcp_transport_error, %{finish_reason: reason}})
       when reason in [
              :close,
              :server_exit,
              :owner_eof,
              :launcher_signal,
              :protocol_error,
              :close_timeout
            ],
       do: reason

  defp fault(_), do: :transport_error

  defp exit_status({:mcp_transport_error, %{exit_status: status}}) when is_integer(status),
    do: status

  defp exit_status(_), do: nil

  defp stderr_tail(
         %{config: %{"stderr" => true}} = state,
         tool,
         provider,
         %{__struct__: PtcRunner.Kernel.MCPStdioTransport} = transport
       ) do
    case PtcRunner.Kernel.MCPStdioTransport.event_snapshot(transport) do
      %{stderr: text, stderr_truncated?: truncated} ->
        limit = div(state.config["max_file_bytes"] - 512, 6)
        offset = max(byte_size(text) - limit, 0)
        tail = text |> binary_part(offset, byte_size(text) - offset) |> PtcRunner.Utf8.sanitize()

        write_record(state, %{
          kind: :stderr_tail,
          tool: tool,
          provider: provider,
          text: tail,
          truncated: truncated or offset > 0
        })

      _ ->
        state
    end
  end

  defp stderr_tail(state, _tool, _provider, _transport), do: state

  defp snapshot_tails(state) do
    Enum.reduce(state.transports, state, fn {_, {tool, provider, transport}}, acc ->
      stderr_tail(acc, tool, provider, transport)
    end)
  end

  defp drain_events(state) do
    receive do
      {:event, record} ->
        :atomics.sub(state.slots, 1, 1)
        drain_events(write_record(state, record))
    after
      0 -> state
    end
  end

  @impl true
  def terminate(_reason, state) do
    state |> drain_events() |> flush_counters() |> close_file()
    File.rmdir(Path.join(state.directory, ".gateway-lock"))
    :ok
  end
end
