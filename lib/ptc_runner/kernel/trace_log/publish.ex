defmodule PtcRunner.Kernel.TraceLog.Publish do
  @moduledoc "Canonical JSONL publication and publication-handle callback assembly."

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.TraceLog.Append
  alias PtcRunner.Kernel.TracePublication

  import PtcRunner.Kernel.TraceLog.Source,
    only: [same_file: 2, decode_jsonl: 1, validate_loaded: 2, normalize: 1, reserved_path?: 1]

  @default_source_bytes 8_000_000
  @bound_publication_helper ~S"""
  set -eu
  final_name=$1
  temporary_name=$2
  byte_count=$3
  marker_name=$4
  umask 077
  trap 'rm -f "$temporary_name" "$marker_name"' EXIT HUP INT TERM
  : > "$marker_name"
  printf 'READY\n'
  command=$(dd bs=1 count=1 2>/dev/null)
  [ "$command" = W ]
  # BSD head rejects a zero byte count.
  if [ "$byte_count" -gt 0 ]; then
    head -c "$byte_count" > "$temporary_name"
  else
    : > "$temporary_name"
  fi
  printf 'DATA\n'
  sentinel=$(dd bs=1 count=1 2>/dev/null)
  [ "$sentinel" = X ]
  sync
  if ln "$temporary_name" "$final_name" 2>/dev/null; then
    :
  elif cmp -s "$temporary_name" "$final_name"; then
    :
  else
    exit 1
  fi
  sync
  rm -f "$temporary_name" "$marker_name"
  trap - EXIT HUP INT TERM
  sync
  """

  @spec publish_jsonl(binary(), [map()], keyword()) :: :ok | {:error, atom()}
  def publish_jsonl(path, events, opts \\ [])

  def publish_jsonl(path, events, opts)
      when is_binary(path) and is_list(events) and is_list(opts) do
    with true <-
           Keyword.keys(opts) -- [:max_source_bytes, :fault_hook, :expected_parent_identity] == [],
         true <- String.valid?(path),
         true <- String.ends_with?(path, ".jsonl") and not reserved_path?(path),
         {:ok, path} <- PrivateDirectory.anchor(path),
         max_bytes when max_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         fault_hook when is_nil(fault_hook) or is_function(fault_hook, 1) <-
           Keyword.get(opts, :fault_hook),
         expected_parent_identity = Keyword.get(opts, :expected_parent_identity),
         true <- valid_expected_parent_identity?(expected_parent_identity),
         normalized = normalize(events),
         {:ok, _validated, _source_id} <- validate_loaded(normalized, max_bytes),
         :ok <- publication_fault(fault_hook, :after_validation),
         {:ok, encoded} <- encode_jsonl(normalized, max_bytes),
         :ok <- publication_fault(fault_hook, :after_encoding) do
      publish_encoded(path, encoded, fault_hook, expected_parent_identity)
    else
      false ->
        {:error, :invalid_trace_log}

      {:error, reason} when reason in [:malformed_source, :unsupported_version] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :trace_persistence_failed}

      _ ->
        {:error, :invalid_trace_log}
    end
  rescue
    _exception -> {:error, :trace_persistence_failed}
  end

  def publish_jsonl(_path, _events, _opts), do: {:error, :invalid_trace_log}

  # Preserve the original global publication lock identity.
  defp publish_encoded(path, encoded, fault_hook, nil) do
    :global.trans({{PtcRunner.Kernel.TraceLog, {:publish, path}}, self()}, fn ->
      publish_at_path(path, encoded, fault_hook)
    end)
  end

  defp publish_encoded(path, encoded, fault_hook, expected_parent_identity) do
    :global.trans({{PtcRunner.Kernel.TraceLog, {:publish, path}}, self()}, fn ->
      publish_bound(path, encoded, fault_hook, expected_parent_identity)
    end)
  end

  defp publish_bound(path, encoded, fault_hook, expected_parent_identity) do
    case start_bound_publisher(path, encoded, expected_parent_identity) do
      {:ok, lease} ->
        try do
          with :ok <- publication_fault(fault_hook, :before_write),
               :ok <- publication_fault(fault_hook, :during_write),
               :ok <- publication_fault(fault_hook, :after_sync),
               true <- Port.command(lease.port, ["W", encoded]),
               :ok <- await_bound_data(lease.port, ""),
               true <- Port.command(lease.port, "X"),
               :ok <- await_bound_publication(lease.port),
               :ok <- publication_fault(fault_hook, :after_publish),
               :ok <- publication_fault(fault_hook, :cleanup) do
            verify_parent_identity(path, expected_parent_identity)
          else
            {:error, _reason} = error -> error
          end
        after
          close_bound_lease(lease)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp start_bound_publisher(path, encoded, expected_parent_identity) do
    with executable when is_binary(executable) <- System.find_executable("sh"),
         parent = Path.dirname(path),
         final_name = Path.basename(path),
         temporary_name =
           ".ptc-tmp-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         marker_name =
           ".ptc-marker-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         port <-
           Port.open(
             {:spawn_executable, executable},
             [
               :binary,
               :exit_status,
               :use_stdio,
               :stderr_to_stdout,
               {:cd, parent},
               {:env, PtcRunner.ChildEnvironment.clear_environment(["PATH"])},
               {:args,
                [
                  "-c",
                  @bound_publication_helper,
                  "--",
                  final_name,
                  temporary_name,
                  Integer.to_string(byte_size(encoded)),
                  marker_name
                ]}
             ]
           ),
         result <-
           await_bound_ready(port, parent, marker_name, expected_parent_identity, "") do
      case result do
        :ok ->
          {:ok,
           %{port: port, parent: parent, temporary_name: temporary_name, marker_name: marker_name}}

        {:error, _reason} = error ->
          close_bound_lease(%{
            port: port,
            parent: parent,
            temporary_name: temporary_name,
            marker_name: marker_name
          })

          error
      end
    else
      nil -> {:error, :trace_persistence_failed}
    end
  rescue
    _exception -> {:error, :trace_persistence_failed}
  catch
    _kind, _reason -> {:error, :trace_persistence_failed}
  end

  defp await_bound_ready(port, parent, marker_name, expected, buffered) do
    receive do
      {^port, {:data, data}} ->
        parse_bound_ready(port, parent, marker_name, expected, buffered <> data)

      {^port, {:exit_status, _status}} ->
        {:error, :trace_persistence_failed}
    after
      5_000 -> {:error, :trace_persistence_failed}
    end
  end

  defp parse_bound_ready(port, parent, marker_name, expected, buffered) do
    case String.split(buffered, "\n", parts: 2) do
      ["READY", _rest] ->
        verify_bound_marker(parent, marker_name, expected)

      [_line, _rest] ->
        {:error, :trace_persistence_failed}

      [_partial] ->
        await_bound_ready(port, parent, marker_name, expected, buffered)
    end
  end

  defp verify_bound_marker(parent, marker_name, expected) do
    marker = Path.join(parent, marker_name)

    with :ok <- verify_parent_identity(marker, expected),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(marker) do
      :ok
    else
      _ -> {:error, :trace_persistence_failed}
    end
  end

  defp await_bound_data(port, buffered) do
    receive do
      {^port, {:data, data}} ->
        case String.split(buffered <> data, "\n", parts: 2) do
          ["DATA", _rest] -> :ok
          [_line, _rest] -> {:error, :trace_persistence_failed}
          [_partial] -> await_bound_data(port, buffered <> data)
        end

      {^port, {:exit_status, _status}} ->
        {:error, :trace_persistence_failed}
    after
      5_000 -> {:error, :trace_persistence_failed}
    end
  end

  defp await_bound_publication(port) do
    receive do
      {^port, {:data, _diagnostic}} -> await_bound_publication(port)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, _status}} -> {:error, :trace_persistence_failed}
    after
      30_000 -> {:error, :trace_persistence_failed}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp close_bound_lease(lease) do
    abort_bound_publisher(lease.port)
    _ = File.rm(Path.join(lease.parent, lease.temporary_name))
    _ = File.rm(Path.join(lease.parent, lease.marker_name))
    :ok
  end

  defp abort_bound_publisher(port) do
    if Port.info(port) do
      _ = safe_port_command(port, "A")
      await_bound_shutdown(port)
    end

    close_port(port)
  end

  defp safe_port_command(port, data) do
    Port.command(port, data)
  catch
    :error, :badarg -> false
  end

  defp await_bound_shutdown(port) do
    receive do
      {^port, {:data, _diagnostic}} -> await_bound_shutdown(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp publish_at_path(path, encoded, fault_hook) do
    case read_publication(path, byte_size(encoded), fault_hook) do
      {:ok, ^encoded} -> sync_directory(Path.dirname(path))
      {:ok, _different} -> {:error, :trace_collision}
      {:error, :enoent} -> publish_new(path, encoded, fault_hook)
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_expected_parent_identity?(nil), do: true

  defp valid_expected_parent_identity?({major, minor, inode}),
    do: is_integer(major) and is_integer(minor) and is_integer(inode)

  defp valid_expected_parent_identity?(_identity), do: false

  defp verify_parent_identity(_path, nil), do: :ok

  defp verify_parent_identity(path, expected) do
    case File.stat(Path.dirname(path)) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: major,
         minor_device: minor,
         inode: inode
       }}
      when {major, minor, inode} == expected ->
        :ok

      _ ->
        {:error, :trace_persistence_failed}
    end
  end

  defp publish_new(path, encoded, fault_hook) do
    temporary =
      path <> ".ptc-tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    result =
      with :ok <- publication_fault(fault_hook, :before_write),
           {:ok, device} <-
             :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive]) do
        try do
          with {:ok, file_info} <- :file.read_file_info(device),
               opened = File.Stat.from_record(file_info),
               :ok <- write_publication(device, encoded, fault_hook),
               :ok <- :file.sync(device),
               :ok <- publication_fault(fault_hook, :after_sync),
               :ok <- link_publication(temporary, path, opened, encoded),
               :ok <- sync_directory(Path.dirname(path)),
               :ok <- publication_fault(fault_hook, :after_publish) do
            :ok
          else
            {:error, _reason} = error -> error
          end
        after
          :file.close(device)
        end
      else
        {:error, _reason} = error -> error
      end

    cleanup_result = cleanup_temporary(temporary, fault_hook)

    cleanup_result =
      case cleanup_result do
        :ok -> sync_directory(Path.dirname(path))
        {:error, _reason} = error -> error
      end

    case {result, cleanup_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _cleanup} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end

  defp write_publication(device, encoded, fault_hook) do
    case publication_fault(fault_hook, :during_write) do
      :ok ->
        :file.write(device, encoded)

      {:error, :partial_write} ->
        partial_bytes = div(byte_size(encoded), 2)
        _ = :file.write(device, binary_part(encoded, 0, partial_bytes))
        {:error, :trace_persistence_failed}

      {:error, _reason} = error ->
        error
    end
  end

  defp link_publication(temporary, path, opened, encoded) do
    with {:ok, current} <- File.lstat(temporary),
         :ok <- publication_same_file(opened, current),
         true <- current.type == :regular and current.size == byte_size(encoded) do
      case File.ln(temporary, path) do
        :ok -> verify_linked_publication(path, opened, encoded)
        {:error, :eexist} -> verify_publication(path, encoded)
        {:error, _reason} -> {:error, :trace_persistence_failed}
      end
    else
      _ -> {:error, :trace_collision}
    end
  end

  defp verify_linked_publication(path, opened, encoded) do
    with {:ok, linked} <- File.lstat(path),
         :ok <- publication_same_file(opened, linked),
         {:ok, ^encoded} <- read_publication(path, byte_size(encoded), nil),
         {:ok, current} <- File.lstat(path),
         :ok <- publication_same_file(opened, current) do
      :ok
    else
      _ -> {:error, :trace_collision}
    end
  end

  defp publication_same_file(expected, current) do
    case same_file(expected, current) do
      :ok -> :ok
      {:error, _reason} -> {:error, :trace_collision}
    end
  end

  defp verify_publication(path, encoded) do
    case read_publication(path, byte_size(encoded), nil) do
      {:ok, ^encoded} -> :ok
      {:ok, _different} -> {:error, :trace_collision}
      {:error, _reason} -> {:error, :trace_collision}
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:directory, :read, :raw]) do
      {:ok, device} ->
        try do
          case :file.sync(device) do
            :ok -> :ok
            {:error, _reason} -> {:error, :trace_persistence_failed}
          end
        after
          :file.close(device)
        end

      {:error, _reason} ->
        {:error, :trace_persistence_failed}
    end
  end

  defp read_publication(path, max_bytes, fault_hook) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size} = expected} when size <= max_bytes ->
        with :ok <- publication_fault(fault_hook, :before_publication_read),
             {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
          try do
            with {:ok, file_info} <- :file.read_file_info(device),
                 opened = File.Stat.from_record(file_info),
                 :ok <- same_file(expected, opened),
                 true <- opened.type == :regular and opened.size <= max_bytes,
                 {:ok, source} <- bounded_publication_read(device, max_bytes),
                 {:ok, current} <- File.lstat(path),
                 :ok <- same_file(expected, current),
                 true <- current.type == :regular and current.size == opened.size do
              {:ok, source}
            else
              _ -> {:error, :trace_collision}
            end
          after
            :file.close(device)
          end
        else
          {:error, :trace_persistence_failed} = error -> error
          _ -> {:error, :trace_collision}
        end

      {:ok, %File.Stat{}} ->
        {:error, :trace_collision}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, _reason} ->
        {:error, :trace_persistence_failed}
    end
  end

  defp bounded_publication_read(device, max_bytes) do
    case :file.read(device, max_bytes + 1) do
      {:ok, source} when byte_size(source) <= max_bytes -> {:ok, source}
      :eof -> {:ok, ""}
      _ -> {:error, :trace_collision}
    end
  end

  defp cleanup_temporary(temporary, fault_hook) do
    injected = publication_fault(fault_hook, :cleanup)

    removed =
      case File.rm(temporary) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> {:error, :trace_persistence_failed}
      end

    case {injected, removed} do
      {:ok, :ok} -> :ok
      {{:error, _reason} = error, _removed} -> error
      {:ok, {:error, _reason} = error} -> error
    end
  end

  defp publication_fault(nil, _stage), do: :ok

  defp publication_fault(hook, stage) do
    case hook.(stage) do
      :ok -> :ok
      {:error, :partial_write} = error -> error
      {:error, _reason} -> {:error, :trace_persistence_failed}
      _ -> {:error, :trace_persistence_failed}
    end
  rescue
    _exception -> {:error, :trace_persistence_failed}
  catch
    _kind, _reason -> {:error, :trace_persistence_failed}
  end

  @doc false
  @spec publish_handle(
          PtcRunner.Kernel.PublicationHandle.t(),
          [map()],
          boolean(),
          nil | (atom() -> term())
        ) :: :ok | {:error, atom()}
  def publish_handle(handle, events, private?, fault_hook \\ nil) do
    TracePublication.publish(
      handle,
      events,
      private?,
      fault_hook,
      %{
        normalize: &normalize/1,
        validate: &validate_loaded(&1, @default_source_bytes),
        encode: &encode_jsonl(&1, @default_source_bytes),
        read: &PublicationHandle.read/2,
        decode: &decode_jsonl/1,
        within_limit: &within_append_limit/2,
        lock: &Append.with_append_authority_lock/2,
        validate_path: &Append.validate_append_path/2,
        fault: &publication_fault/2
      }
    )
  end

  defp within_append_limit(existing_source, encoded)
       when is_binary(existing_source) and is_binary(encoded) do
    if byte_size(existing_source) + byte_size(encoded) <= @default_source_bytes,
      do: :ok,
      else: {:error, :source_limit_exceeded}
  end

  @spec encode_jsonl([map()], pos_integer()) :: {:ok, binary()} | {:error, atom()}
  defp encode_jsonl(events, max_bytes) do
    Enum.reduce_while(events, {:ok, [], 0}, fn event, {:ok, encoded, bytes} ->
      case DeterministicJSON.encode(event) do
        {:ok, line} when bytes + byte_size(line) + 1 <= max_bytes ->
          {:cont, {:ok, ["\n", line | encoded], bytes + byte_size(line) + 1}}

        _ ->
          {:halt, {:error, :source_limit_exceeded}}
      end
    end)
    |> case do
      {:ok, encoded, _bytes} -> {:ok, encoded |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _reason} = error -> error
    end
  end
end
