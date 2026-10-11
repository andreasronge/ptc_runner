defmodule PtcRunner.Kernel.TraceLog.Append do
  @moduledoc "Canonical JSONL append and cross-process path and inode authority leases."

  alias PtcRunner.Kernel.PrivateDirectory

  import PtcRunner.Kernel.TraceLog.Source,
    only: [
      same_file: 2,
      decode_jsonl: 1,
      validate_loaded: 2,
      normalize: 1,
      private_path?: 1,
      inspection_path?: 1
    ]

  @default_source_bytes 8_000_000
  @append_lock_timeout_ms 30_000
  @append_path_buckets 2_047
  @append_inode_buckets 2_048
  @append_lock_helper ~S"""
  set -eu
  lock_kind=$1
  lock_executable=$2
  shell=$3
  lock_file=$4
  lock_body='printf "READY\n"; IFS= read -r command; [ "$command" = X ]; printf "DONE\n"'
  case "$lock_kind" in
    lockf) exec "$lock_executable" -k -t 30 "$lock_file" "$shell" -c "$lock_body" ;;
    flock) exec "$lock_executable" -E 75 -w 30 "$lock_file" "$shell" -c "$lock_body" ;;
    *) exit 1 ;;
  esac
  """

  @doc """
  Appends canonical events to one admin-selected JSONL file under a total byte
  cap. `private: true` requires safe parent ancestry and a mode-`0600` file,
  owned by the current process authority, creating a missing file
  privately before publication. The permission-checked descriptor is retained
  through validation and append so pathname replacement cannot redirect private
  bytes. One OS-released advisory lease keyed by the parent-directory/name
  identity remains held across first-file creation. A nested device/inode lease
  serializes hard-link aliases. The fixed path-then-inode acquisition order
  applies across BEAM processes and separate local runtimes.
  """
  @spec append_jsonl(binary(), [map()], keyword()) :: :ok | {:error, atom()}
  def append_jsonl(path, events, opts \\ [])

  def append_jsonl(path, events, opts)
      when is_binary(path) and is_list(events) and is_list(opts) do
    with true <- Keyword.keys(opts) -- [:max_source_bytes, :private, :append_hook] == [],
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         private? when is_boolean(private?) <- Keyword.get(opts, :private, false),
         append_hook when is_nil(append_hook) or is_function(append_hook, 1) <-
           Keyword.get(opts, :append_hook),
         :ok <- validate_append_path(path, private?),
         {:ok, path} <- PrivateDirectory.anchor(path) do
      append_jsonl_with_lock(path, events, max_bytes, private?, append_hook)
    else
      _ -> {:error, :invalid_trace_log}
    end
  end

  def append_jsonl(_path, _events, _opts), do: {:error, :invalid_trace_log}

  # Keep the original lock namespace across this module extraction.
  defp append_jsonl_with_lock(path, events, max_bytes, private?, append_hook) do
    with_callback_lock(append_hook, fn ->
      :global.trans({{PtcRunner.Kernel.TraceLog, {:append, path}}, self()}, fn ->
        with_append_lock(path, fn ->
          append_locked(path, normalize(events), max_bytes, private?, append_hook)
        end)
      end)
    end)
  end

  @doc false
  @spec validate_append_path(term(), term()) :: :ok | {:error, atom()}
  def validate_append_path(path, private?)
      when is_binary(path) and is_boolean(private?) do
    cond do
      not String.valid?(path) ->
        {:error, :invalid_trace_path}

      not String.ends_with?(path, ".jsonl") or inspection_path?(path) ->
        {:error, :invalid_trace_path}

      private? and not private_path?(path) ->
        {:error, :private_trace_requires_private_suffix}

      not private? and private_path?(path) ->
        {:error, :normal_trace_requires_normal_suffix}

      true ->
        :ok
    end
  end

  def validate_append_path(_path, _private?), do: {:error, :invalid_trace_path}

  @doc false
  @spec preflight_destination(term(), term()) :: :ok | {:error, atom()}
  def preflight_destination(path, private?)
      when is_binary(path) and is_boolean(private?) do
    with :ok <- validate_append_path(path, private?),
         {:ok, path} <- PrivateDirectory.anchor(path),
         :ok <- preflight_trace_destination(path, private?) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  def preflight_destination(_path, _private?), do: {:error, :invalid_trace_path}

  @doc false
  @spec append_lock_identity(binary()) :: {:ok, term()} | {:error, :source_unavailable}
  def append_lock_identity(path) when is_binary(path) do
    with {:ok, path} <- PrivateDirectory.anchor(path),
         do: append_path_lock_scope(path)
  end

  def append_lock_identity(_path), do: {:error, :source_unavailable}

  @doc false
  @spec append_reservation_path(binary()) :: {:ok, binary()} | {:error, :source_unavailable}
  def append_reservation_path(path) when is_binary(path) do
    with {:ok, path} <- PrivateDirectory.anchor(path),
         {:ok, scope} <- append_path_lock_scope(path),
         {:ok, lock_root} <- append_lock_root() do
      {:ok, Path.join(lock_root, "reservation-" <> append_scope_digest(scope) <> ".lock")}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  def append_reservation_path(_path), do: {:error, :source_unavailable}

  @doc false
  @spec with_append_authority_lock(binary(), (-> result)) :: result when result: term()
  def with_append_authority_lock(path, callback)
      when is_binary(path) and is_function(callback, 0) do
    case PrivateDirectory.anchor(path) do
      {:ok, path} ->
        :global.trans({{PtcRunner.Kernel.TraceLog, {:append, path}}, self()}, fn ->
          with_append_authority_lock_at(path, callback)
        end)

      _other ->
        {:error, :source_unavailable}
    end
  end

  def with_append_authority_lock(_path, _callback), do: {:error, :source_unavailable}

  defp with_append_authority_lock_at(path, callback) do
    with_append_lock(path, fn ->
      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :regular}} ->
          with_inode_append_lock(path, fn _locked_stat -> callback.() end)

        {:error, :enoent} ->
          callback.()

        _other ->
          {:error, :source_unavailable}
      end
    end)
  end

  defp with_append_lock(path, callback, attempts \\ 3)

  defp with_append_lock(_path, _callback, 0), do: {:error, :lock_timeout}

  defp with_append_lock(path, callback, attempts) do
    case append_path_lock_scope(path) do
      {:ok, scope} ->
        result =
          with_bucket_lock(scope, fn ->
            case append_path_lock_scope(path) do
              {:ok, ^scope} -> callback.()
              _changed -> :retry_append_lock
            end
          end)

        if result == :retry_append_lock,
          do: with_append_lock(path, callback, attempts - 1),
          else: result

      _other ->
        {:error, :source_unavailable}
    end
  end

  defp start_append_lock(scope) do
    with {:ok, lock_root} <- append_lock_root(),
         {:ok, shell, lock_kind, lock_executable} <- append_lock_executables(),
         lock_file = Path.join(lock_root, append_lock_name(scope)),
         port <-
           Port.open(
             {:spawn_executable, shell},
             [
               :binary,
               :exit_status,
               :use_stdio,
               :stderr_to_stdout,
               {:line, 64},
               {:env, PtcRunner.ChildEnvironment.clear_environment(["PATH"])},
               args: [
                 "-c",
                 @append_lock_helper,
                 "ptc-trace-append-lock",
                 Atom.to_string(lock_kind),
                 lock_executable,
                 shell,
                 lock_file
               ]
             ]
           ),
         :ok <- await_append_lock(port) do
      {:ok, port}
    else
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  defp append_lock_executables do
    case System.find_executable("sh") do
      shell when is_binary(shell) ->
        cond do
          lockf = System.find_executable("lockf") -> {:ok, shell, :lockf, lockf}
          flock = System.find_executable("flock") -> {:ok, shell, :flock, flock}
          true -> {:error, :source_unavailable}
        end

      nil ->
        {:error, :source_unavailable}
    end
  end

  defp await_append_lock(port) do
    receive do
      {^port, {:data, {:eol, "READY"}}} -> :ok
      {^port, {:data, _diagnostic}} -> await_append_lock(port)
      {^port, {:exit_status, 75}} -> {:error, :lock_timeout}
      {^port, {:exit_status, _status}} -> {:error, :subprocess_failed}
    after
      @append_lock_timeout_ms ->
        if Port.info(port), do: Port.close(port)
        {:error, :lock_timeout}
    end
  end

  defp release_append_lock(port) do
    if Port.info(port) do
      _ = Port.command(port, "X\n")
      drain_append_lock(port)
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp drain_append_lock(port) do
    receive do
      {^port, {:data, _diagnostic}} -> drain_append_lock(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      2_000 ->
        if Port.info(port), do: Port.close(port)
        drain_closed_append_lock(port)
    end
  end

  defp drain_closed_append_lock(port) do
    receive do
      {^port, {:data, _diagnostic}} -> drain_closed_append_lock(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      100 -> :ok
    end
  end

  defp append_path_lock_scope(path) do
    case File.stat(Path.dirname(path), time: :posix) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: major,
         minor_device: minor,
         inode: inode
       }} ->
        name = path |> Path.basename() |> PrivateDirectory.casefold_name()
        {:ok, {:path, major, minor, inode, name}}

      _ ->
        {:error, :source_unavailable}
    end
  end

  defp with_inode_append_lock(path, callback, attempts \\ 3)

  defp with_inode_append_lock(_path, _callback, 0),
    do: {:error, :source_unavailable}

  defp with_inode_append_lock(path, callback, attempts) do
    case append_inode_lock_scope(path) do
      {:ok, scope, _stat} ->
        result =
          with_bucket_lock(scope, fn ->
            case append_inode_lock_scope(path) do
              {:ok, ^scope, locked_stat} -> callback.(locked_stat)
              _changed -> :retry_inode_append_lock
            end
          end)

        if result == :retry_inode_append_lock,
          do: with_inode_append_lock(path, callback, attempts - 1),
          else: result

      _other ->
        {:error, :source_unavailable}
    end
  end

  defp append_inode_lock_scope(path) do
    case File.lstat(path) do
      {:ok,
       %File.Stat{
         type: :regular,
         major_device: major,
         minor_device: minor,
         inode: inode
       } = stat} ->
        {:ok, {:inode, major, minor, inode}, stat}

      _ ->
        {:error, :source_unavailable}
    end
  end

  defp append_lock_root do
    base = Path.join(System.tmp_dir!(), "ptc-runner-trace-append-locks")

    with {:ok, uid} <- PrivateDirectory.preflight_owner(base),
         root = base <> "-" <> Integer.to_string(uid),
         :ok <- ensure_append_lock_root(root, uid) do
      {:ok, root}
    else
      _error -> {:error, :source_unavailable}
    end
  end

  defp ensure_append_lock_root(root, uid) do
    case validate_append_lock_root(root, uid) do
      :ok ->
        :ok

      {:error, :enoent} ->
        case PrivateDirectory.create(root) do
          :ok -> validate_append_lock_root(root, uid)
          {:error, _reason} -> validate_append_lock_root(root, uid)
        end

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp validate_append_lock_root(root, uid) do
    case File.lstat(root, time: :posix) do
      {:ok, stat} ->
        if PrivateDirectory.private_dir?(stat, uid), do: :ok, else: {:error, :source_unavailable}

      {:error, :enoent} ->
        {:error, :enoent}

      _unsafe_or_unavailable ->
        {:error, :source_unavailable}
    end
  end

  defp append_lock_name(:callback), do: "bucket-000.lock"

  defp append_lock_name(scope) do
    # Bucket zero guards append hooks before they take a path lease. Path
    # leases then precede inode leases in disjoint ranges.
    <<prefix::16, _rest::binary>> = :crypto.hash(:sha256, :erlang.term_to_binary(scope))

    bucket =
      case elem(scope, 0) do
        :path -> 1 + rem(prefix, @append_path_buckets)
        :inode -> 2_048 + Bitwise.band(prefix, @append_inode_buckets - 1)
      end

    "bucket-#{bucket |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(3, "0")}.lock"
  end

  defp with_callback_lock(nil, callback), do: callback.()
  defp with_callback_lock(_hook, callback), do: with_bucket_lock(:callback, callback)

  defp with_bucket_lock(scope, callback) do
    # An append hook may append again in this BEAM process. Its outer guard
    # prevents another hook holder from taking nested buckets in reverse order;
    # reentrant use of the same bucket needs no second port.
    name = append_lock_name(scope)
    # Reentrancy and lease identities remain bound to the original namespace.
    key = {PtcRunner.Kernel.TraceLog, :held_append_buckets}
    held = Process.get(key, [])

    if name in held do
      callback.()
    else
      case start_append_lock(scope) do
        {:ok, port} ->
          Process.put(key, [name | held])

          try do
            callback.()
          after
            release_append_lock(port)

            if held == [], do: Process.delete(key), else: Process.put(key, held)
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp append_scope_digest(scope) do
    scope
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  defp append_locked(path, events, max_bytes, true, append_hook),
    do: append_private_locked(path, events, max_bytes, append_hook)

  defp append_locked(path, events, max_bytes, false, append_hook) do
    with :ok <- ensure_trace_file(path),
         :ok <- append_fault(append_hook, :after_file_ready) do
      with_inode_append_lock(path, fn locked_stat ->
        append_regular_locked(path, events, max_bytes, locked_stat)
      end)
    end
  end

  defp append_regular_locked(path, events, max_bytes, locked_stat) do
    with {:ok, current_stat} <- File.lstat(path),
         :ok <- same_file(locked_stat, current_stat),
         {:ok, existing_source} <- read_regular_file(path, max_bytes),
         {:ok, existing_events} <- decode_jsonl(existing_source),
         {:ok, _events, _source_id} <- validate_loaded(existing_events ++ events, max_bytes),
         encoded = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")),
         true <- byte_size(existing_source) + byte_size(encoded) <= max_bytes,
         :ok <- append_regular_file(path, existing_source, encoded, max_bytes, locked_stat) do
      :ok
    else
      false -> {:error, :source_limit_exceeded}
      {:error, _reason} = error -> error
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  defp append_private_locked(path, events, max_bytes, append_hook) do
    with {:ok, uid} <- private_parent_identity(path),
         :ok <- ensure_private_trace_file(path, uid, append_hook),
         :ok <- append_fault(append_hook, :after_file_ready) do
      with_inode_append_lock(path, fn locked_stat ->
        append_private_inode_locked(path, events, max_bytes, uid, locked_stat)
      end)
    end
  end

  defp append_private_inode_locked(path, events, max_bytes, uid, locked_stat) do
    with {:ok, device} <- open_private_trace(path, uid, locked_stat) do
      try do
        with {:ok, existing_source} <- read_private_device(device, max_bytes),
             {:ok, existing_events} <- decode_jsonl(existing_source),
             {:ok, _events, _source_id} <- validate_loaded(existing_events ++ events, max_bytes),
             encoded = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")),
             true <- byte_size(existing_source) + byte_size(encoded) <= max_bytes,
             {:ok, _position} <- :file.position(device, :eof),
             :ok <- :file.write(device, encoded) do
          :ok
        else
          false -> {:error, :source_limit_exceeded}
          {:error, _reason} = error -> error
        end
      after
        :file.close(device)
      end
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  defp append_fault(nil, _stage), do: :ok
  defp append_fault(hook, stage), do: hook.(stage)

  defp read_private_device(device, max_bytes) do
    case :file.position(device, :bof) do
      {:ok, 0} -> read_device(device, max_bytes)
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp ensure_trace_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, :enoent} -> create_trace_file(path)
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp create_trace_file(path) do
    case File.write(path, "", [:exclusive]) do
      :ok ->
        :ok

      {:error, :eexist} ->
        ensure_trace_file(path)

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp preflight_trace_destination(path, private?) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        if private?,
          do: preflight_private_trace(path, stat),
          else: preflight_normal_trace(path)

      {:ok, %File.Stat{}} ->
        {:error, :invalid_trace_path}

      {:error, :enoent} ->
        preflight_missing_trace(path, private?)

      {:error, _reason} ->
        {:error, :trace_destination_unavailable}
    end
  end

  defp preflight_missing_trace(path, private?) do
    case File.lstat(Path.dirname(path)) do
      {:ok, %File.Stat{type: :directory}} ->
        if private?, do: private_creation_parent(path), else: normal_creation_parent(path)

      _missing_or_invalid ->
        {:error, :trace_destination_unavailable}
    end
  end

  defp preflight_normal_trace(path) do
    case PrivateDirectory.preflight_writable_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, preflight_reason(reason, :source_unavailable)}
    end
  end

  defp normal_creation_parent(path) do
    case PrivateDirectory.preflight_writable_parent(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, preflight_reason(reason, :source_unavailable)}
    end
  end

  defp preflight_private_trace(path, stat) do
    with {:ok, uid} <- PrivateDirectory.preflight_owner(path),
         true <- PrivateDirectory.private_file?(stat, uid),
         :ok <- PrivateDirectory.preflight_writable_file(path) do
      :ok
    else
      false -> {:error, :trace_destination_unavailable}
      {:error, reason} -> {:error, preflight_reason(reason, :trace_destination_unavailable)}
    end
  end

  # Unlike the normal-trace paths, this one has always collapsed an unavailable
  # parent into :source_unavailable. Only the unsafe split is new here.
  defp private_creation_parent(path) do
    case PrivateDirectory.preflight(path) do
      :ok -> :ok
      {:error, :private_directory_parent_unsafe} -> {:error, :trace_destination_unsafe}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  # An untrusted ancestor — one owned outside this authority, or a
  # group/other-writable directory somewhere on the path -- is operator-fixable
  # and names a specific directory to go look at. A missing `id`/`mkdir` or an
  # unreadable parent is a different problem with a different remedy, so
  # preflight names the untrusted ancestor apart from both. What the remaining
  # faults collapse to still differs by call site, which is why each passes its
  # own fallback. The append path keeps its single closed reason.
  defp preflight_reason(:private_directory_parent_unsafe, _fallback),
    do: :trace_destination_unsafe

  defp preflight_reason(:private_directory_parent_unavailable, _fallback),
    do: :trace_destination_unavailable

  defp preflight_reason(_reason, fallback), do: fallback

  defp private_parent_identity(path) do
    case PrivateDirectory.preflight_owner(path) do
      {:ok, uid} -> {:ok, uid}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp ensure_private_trace_file(path, uid, append_hook) do
    case File.lstat(path) do
      {:ok, stat} ->
        if PrivateDirectory.private_file?(stat, uid), do: :ok, else: {:error, :source_unavailable}

      {:error, :enoent} ->
        publish_empty_private_trace(path, uid, append_hook)

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp publish_empty_private_trace(path, uid, append_hook) do
    {temporary_directory, temporary} = PrivateDirectory.temporary_sibling(path, "trace")

    case PrivateDirectory.create(temporary_directory) do
      :ok ->
        publish_empty_private_trace_created(
          path,
          uid,
          temporary_directory,
          temporary,
          append_hook
        )

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp publish_empty_private_trace_created(
         path,
         uid,
         temporary_directory,
         temporary,
         append_hook
       ) do
    with {:ok, :ok} <-
           File.open(temporary, [:write, :binary, :exclusive], fn _device ->
             with :ok <- append_fault(append_hook, :before_private_chmod),
                  do: File.chmod(temporary, 0o600)
           end),
         :ok <- File.ln(temporary, path) do
      :ok
    else
      {:error, :eexist} -> ensure_private_trace_file(path, uid, append_hook)
      {:ok, {:error, _reason}} -> {:error, :source_unavailable}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  after
    _ = File.rm(temporary)
    _ = File.rmdir(temporary_directory)
  end

  defp open_private_trace(path, uid, locked_stat) do
    case :file.open(String.to_charlist(path), [:read, :append, :binary, :raw]) do
      {:ok, device} ->
        case validate_open_private_trace(path, device, uid, locked_stat) do
          :ok ->
            {:ok, device}

          {:error, _reason} = error ->
            :file.close(device)
            error
        end

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp validate_open_private_trace(path, device, uid, locked_stat) do
    with {:ok, file_info} <- :file.read_file_info(device, time: :posix),
         opened = File.Stat.from_record(file_info),
         :ok <- same_file(locked_stat, opened),
         true <-
           PrivateDirectory.private_file?(opened, uid),
         {:ok, current} <- File.lstat(path, time: :posix),
         true <-
           PrivateDirectory.private_file?(current, uid),
         :ok <- same_file(opened, current) do
      :ok
    else
      _changed_or_invalid -> {:error, :source_unavailable}
    end
  end

  defp append_regular_file(path, existing_source, encoded, max_bytes, locked_stat) do
    with {:ok, %File.Stat{type: :regular} = expected} <- File.lstat(path),
         :ok <- same_file(locked_stat, expected),
         true <- expected.size == byte_size(existing_source),
         {:ok, device} <-
           :file.open(String.to_charlist(path), [:read, :append, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened = File.Stat.from_record(file_info),
             :ok <- same_file(expected, opened),
             true <- opened.type == :regular and opened.size == byte_size(existing_source),
             {:ok, 0} <- :file.position(device, :bof),
             {:ok, current_source} <- read_device(device, max_bytes),
             true <- current_source == existing_source,
             true <- byte_size(current_source) + byte_size(encoded) <= max_bytes,
             :ok <- :file.write(device, encoded) do
          :ok
        else
          false -> {:error, :source_changed}
          {:error, _reason} = error -> error
        end
      after
        :file.close(device)
      end
    else
      false -> {:error, :source_changed}
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp read_device(device, max_bytes) do
    case :file.read(device, max_bytes + 1) do
      {:ok, source} when byte_size(source) <= max_bytes -> {:ok, source}
      :eof -> {:ok, ""}
      {:ok, _source} -> {:error, :source_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  @spec read_regular_file(binary(), pos_integer()) :: {:ok, binary()} | {:error, atom()}
  defp read_regular_file(path, remaining) do
    with {:ok, %File.Stat{type: :regular} = expected} <- File.lstat(path),
         true <- expected.size <= remaining,
         {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened = File.Stat.from_record(file_info),
             :ok <- same_file(expected, opened),
             true <- opened.type == :regular and opened.size <= remaining do
          read_device(device, remaining)
        else
          false -> {:error, :source_limit_exceeded}
          {:error, _reason} = error -> error
        end
      after
        :file.close(device)
      end
    else
      false -> {:error, :source_limit_exceeded}
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end
end
