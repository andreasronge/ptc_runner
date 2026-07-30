defmodule PtcRunner.Kernel.TraceLog do
  @moduledoc """
  Bounded canonical trace loading, validation, filtering, and pagination.

  A source is an in-memory `PtcRunner.Kernel.EventSink`, one JSONL file, or a
  directory of JSONL files. Loading validates the complete event envelope,
  schema version, JSON-like data, run/trace identity, timestamps, and monotonic
  sequence before deriving query results. Each run must begin with exactly one
  `run-started`; it may remain open or end with exactly one final
  `run-stopped`.

  Supported query operations are:

  - `:list_runs` — bounded filtered run summaries, including the run-started
    sequence and component-override provenance;
  - `:get_run` — one run summary by run ID;
  - `:list_turns` — ordered evaluation/capability facts for one run;
  - `:counters` — aggregate counters for filtered runs.

  Pagination cursors are bound to the source and operation. Every source and
  result has an aggregate byte ceiling. Normal directory sources exclude the
  reserved private filename suffix; private files require an explicit source.

  The internal trace-snapshot owner uses this module's canonical validation and
  query execution against one immutable normal directory capture. A snapshot
  is deliberately not another public `t:source/0` variant.
  """

  alias Jason.OrderedObject
  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.PrivateDirectory

  @default_source_bytes 8_000_000
  @default_result_bytes 1_000_000
  @default_capture_directory_entries 4_096
  @default_capture_trace_files 1_024
  @capture_listing_timeout_ms 5_000
  @capture_listing_heap_words 1_000_000
  @default_limit 20
  @max_limit 100
  @max_cursor_bytes 1_024
  @max_string_bytes 256
  @event_type ~r/\A[a-z][a-z0-9-]{0,127}\z/
  @event_keys ~w(schema_version run_id trace_id sequence timestamp type data)
  @append_lock_timeout_ms 30_000
  @append_lock_helper ~S"""
  set -eu
  lock_kind=$1
  lock_executable=$2
  shell=$3
  lock_file=$4
  lock_body='printf "READY\n"; IFS= read -r command; [ "$command" = X ]; printf "DONE\n"'
  case "$lock_kind" in
    lockf) exec "$lock_executable" -k -t 30 "$lock_file" "$shell" -c "$lock_body" ;;
    flock) exec "$lock_executable" -w 30 "$lock_file" "$shell" -c "$lock_body" ;;
    *) exit 1 ;;
  esac
  """
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
  head -c "$byte_count" > "$temporary_name"
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

  @enforce_keys [:source, :source_kind, :max_source_bytes, :max_result_bytes]
  defstruct [:source, :source_kind, :max_source_bytes, :max_result_bytes]

  @type source :: EventSink.t() | {:file, binary()} | {:directory, binary()}
  @type t :: %__MODULE__{
          source: source(),
          source_kind: :sanitized | :private,
          max_source_bytes: pos_integer(),
          max_result_bytes: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_trace_log}
  @doc """
  Constructs a query boundary from required `:source` and optional positive
  `:max_source_bytes` and `:max_result_bytes` limits.
  """
  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:source, :max_source_bytes, :max_result_bytes] == [],
         {:ok, source, source_kind} <- validate_source(Keyword.get(opts, :source)),
         max_source_bytes when is_integer(max_source_bytes) and max_source_bytes > 0 <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Keyword.get(opts, :max_result_bytes, @default_result_bytes) do
      {:ok,
       %__MODULE__{
         source: source,
         source_kind: source_kind,
         max_source_bytes: max_source_bytes,
         max_result_bytes: max_result_bytes
       }}
    else
      _ -> {:error, :invalid_trace_log}
    end
  end

  def new(_opts), do: {:error, :invalid_trace_log}

  @spec query(t(), :list_runs | :get_run | :list_turns | :counters, map()) ::
          {:ok, map()} | {:error, atom()}
  @doc "Executes one validated, source-scoped bounded trace query."
  def query(%__MODULE__{} = trace_log, operation, arguments)
      when operation in [:list_runs, :get_run, :list_turns, :counters] and is_map(arguments) do
    with {:ok, events, source_id} <- load(trace_log),
         do:
           execute(
             operation,
             events,
             source_id,
             arguments,
             trace_log.max_result_bytes,
             trace_log.source_kind
           )
  end

  def query(_trace_log, _operation, _arguments), do: {:error, :invalid_query}

  @doc false
  @spec query_loaded(
          [map()],
          binary(),
          :list_runs | :get_run | :list_turns | :counters,
          map(),
          pos_integer(),
          :sanitized | :private
        ) :: {:ok, map()} | {:error, atom()}
  def query_loaded(events, source_id, operation, arguments, max_result_bytes, source_kind)
      when is_list(events) and is_binary(source_id) and
             operation in [:list_runs, :get_run, :list_turns, :counters] and is_map(arguments) and
             is_integer(max_result_bytes) and max_result_bytes > 0 and
             source_kind in [:sanitized, :private] do
    execute(operation, events, source_id, arguments, max_result_bytes, source_kind)
  end

  def query_loaded(_events, _source_id, _operation, _arguments, _max_result_bytes, _source_kind),
    do: {:error, :invalid_query}

  @doc false
  @spec capture_directory(binary(), keyword()) ::
          {:ok, %{events: [map()], source_id: binary(), source_bytes: non_neg_integer()}}
          | {:error, atom()}
  def capture_directory(directory, opts \\ [])

  def capture_directory(directory, opts) when is_binary(directory) and is_list(opts) do
    with true <-
           Keyword.keys(opts) --
             [
               :max_source_bytes,
               :max_directory_entries,
               :max_trace_files,
               :capture_hook,
               :listing_hook
             ] == [],
         true <- String.valid?(directory),
         max_source_bytes when max_source_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         max_directory_entries
         when max_directory_entries in 1..@default_capture_directory_entries <-
           Keyword.get(
             opts,
             :max_directory_entries,
             @default_capture_directory_entries
           ),
         max_trace_files when max_trace_files in 1..@default_capture_trace_files <-
           Keyword.get(opts, :max_trace_files, @default_capture_trace_files),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         listing_hook when is_nil(listing_hook) or is_function(listing_hook, 0) <-
           Keyword.get(opts, :listing_hook),
         {:ok, capture} <-
           capture_normal_directory(
             Path.expand(directory),
             max_source_bytes,
             max_directory_entries,
             max_trace_files,
             capture_hook,
             listing_hook
           ) do
      {:ok, capture}
    else
      false -> {:error, :invalid_trace_log}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trace_log}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  def capture_directory(_directory, _opts), do: {:error, :invalid_trace_log}

  @doc """
  Appends canonical events to one admin-selected JSONL file under a total byte
  cap. `private: true` requires safe parent ancestry and a mode-`0600` file,
  owned by the current process authority or root, creating a missing file
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
      :global.trans({{__MODULE__, {:append, path}}, self()}, fn ->
        with_append_lock(path, fn ->
          append_locked(path, normalize(events), max_bytes, private?, append_hook)
        end)
      end)
    else
      _ -> {:error, :invalid_trace_log}
    end
  end

  def append_jsonl(_path, _events, _opts), do: {:error, :invalid_trace_log}

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
         :ok <- preflight_trace_destination(path, private?),
         :ok <- preflight_append_lock() do
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

  defp with_append_lock(path, callback, attempts \\ 3)

  defp with_append_lock(_path, _callback, 0), do: {:error, :source_unavailable}

  defp with_append_lock(path, callback, attempts) do
    with {:ok, scope} <- append_path_lock_scope(path),
         {:ok, port} <- start_append_lock(scope) do
      result =
        try do
          case append_path_lock_scope(path) do
            {:ok, ^scope} -> callback.()
            _changed -> :retry_append_lock
          end
        after
          release_append_lock(port)
        end

      if result == :retry_append_lock,
        do: with_append_lock(path, callback, attempts - 1),
        else: result
    else
      _ -> {:error, :source_unavailable}
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
      _ -> {:error, :source_unavailable}
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

  defp preflight_append_lock do
    with {:ok, _root} <- append_lock_root(),
         {:ok, _shell, _lock_kind, _lock_executable} <- append_lock_executables() do
      :ok
    end
  end

  defp await_append_lock(port) do
    receive do
      {^port, {:data, {:eol, "READY"}}} -> :ok
      {^port, {:data, _diagnostic}} -> await_append_lock(port)
      {^port, {:exit_status, _status}} -> {:error, :source_unavailable}
    after
      @append_lock_timeout_ms ->
        if Port.info(port), do: Port.close(port)
        {:error, :source_unavailable}
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
    with {:ok, scope, _stat} <- append_inode_lock_scope(path),
         {:ok, port} <- start_append_lock(scope) do
      result =
        try do
          case append_inode_lock_scope(path) do
            {:ok, ^scope, locked_stat} -> callback.(locked_stat)
            _changed -> :retry_inode_append_lock
          end
        after
          release_append_lock(port)
        end

      if result == :retry_inode_append_lock,
        do: with_inode_append_lock(path, callback, attempts - 1),
        else: result
    else
      _ -> {:error, :source_unavailable}
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
      {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}}
      when Bitwise.band(mode, 0o777) == 0o700 ->
        :ok

      {:error, :enoent} ->
        {:error, :enoent}

      _unsafe_or_unavailable ->
        {:error, :source_unavailable}
    end
  end

  defp append_lock_name(scope) do
    digest =
      scope
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "#{digest}.lock"
  end

  @doc false
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

  defp execute(:list_runs, events, source_id, arguments, max_result_bytes, source_kind) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(limit cursor status run_id trace_id tags name model provider from to)
           ),
         :ok <- validate_run_filters(arguments),
         {:ok, page} <- page_options(arguments, source_id, :list_runs) do
      events
      |> runs(source_kind)
      |> filter_runs(arguments)
      |> paginate(page, source_id, max_result_bytes)
    end
  end

  defp execute(
         :get_run,
         events,
         _source_id,
         %{"run_id" => run_id} = arguments,
         max_result_bytes,
         source_kind
       ) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         :ok <- valid_string(run_id),
         metadata when not is_nil(metadata) <-
           Enum.find(runs(events, source_kind), &(&1["run_id"] == run_id)),
         :ok <- within_result_limit(metadata, max_result_bytes) do
      {:ok, metadata}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(:get_run, _events, _source_id, _arguments, _max_result_bytes, _source_kind),
    do: {:error, :invalid_query}

  defp execute(
         :list_turns,
         events,
         source_id,
         %{"run_id" => run_id} = arguments,
         max_result_bytes,
         _source_kind
       ) do
    with :ok <- validate_keys(arguments, ~w(run_id limit cursor status evaluation_id capability)),
         :ok <- valid_string(run_id),
         :ok <- validate_turn_filters(arguments),
         true <- Enum.any?(events, &(&1["run_id"] == run_id)),
         {:ok, page} <- page_options(arguments, source_id, :list_turns) do
      events
      |> Enum.filter(&(&1["run_id"] == run_id and turn_matches?(&1, arguments)))
      |> Enum.sort_by(& &1["sequence"])
      |> paginate(page, source_id, max_result_bytes)
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(:list_turns, _events, _source_id, _arguments, _max_result_bytes, _source_kind),
    do: {:error, :invalid_query}

  defp execute(:counters, events, _source_id, arguments, max_result_bytes, source_kind) do
    with :ok <-
           validate_keys(arguments, ~w(status run_id trace_id tags name model provider from to)),
         :ok <- validate_run_filters(arguments) do
      selected_ids =
        events |> runs(source_kind) |> filter_runs(arguments) |> MapSet.new(& &1["run_id"])

      selected = Enum.filter(events, &MapSet.member?(selected_ids, &1["run_id"]))
      result = counters(selected)

      with :ok <- within_result_limit(result, max_result_bytes), do: {:ok, result}
    end
  end

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

  defp publish_encoded(path, encoded, fault_hook, nil) do
    :global.trans({{__MODULE__, {:publish, path}}, self()}, fn ->
      publish_at_path(path, encoded, fault_hook)
    end)
  end

  defp publish_encoded(path, encoded, fault_hook, expected_parent_identity) do
    :global.trans({{__MODULE__, {:publish, path}}, self()}, fn ->
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

  defp preflight_private_trace(path, %File.Stat{mode: mode, uid: owner}) do
    with {:ok, uid} <- PrivateDirectory.preflight_owner(path),
         true <- owner in [0, uid] and Bitwise.band(mode, 0o777) == 0o600,
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
  # preflight reports them apart instead of collapsing both to "unavailable".
  # The append path keeps its single closed reason.
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
      {:ok, %File.Stat{type: :regular, mode: mode, uid: owner}}
      when owner in [0, uid] and Bitwise.band(mode, 0o777) == 0o600 ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :source_unavailable}

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
           opened.type == :regular and opened.uid in [0, uid] and
             Bitwise.band(opened.mode, 0o777) == 0o600,
         {:ok, current} <- File.lstat(path, time: :posix),
         true <-
           current.type == :regular and current.uid in [0, uid] and
             Bitwise.band(current.mode, 0o777) == 0o600,
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

  defp validate_source(%EventSink{} = sink) do
    case EventSink.policy(sink) do
      :normal -> {:ok, sink, :sanitized}
      _ -> {:error, :invalid_trace_log}
    end
  catch
    :exit, _reason -> {:error, :invalid_trace_log}
  end

  defp validate_source({:private, %EventSink{} = sink}) do
    case EventSink.policy(sink) do
      :private -> {:ok, sink, :private}
      _ -> {:error, :invalid_trace_log}
    end
  catch
    :exit, _reason -> {:error, :invalid_trace_log}
  end

  defp validate_source({:file, path}) when is_binary(path) do
    case {reserved_path?(path), File.lstat(path)} do
      {true, _stat} ->
        {:error, :invalid_trace_log}

      {false, {:ok, %File.Stat{type: :regular}}} ->
        {:ok, {:file, Path.expand(path)}, :sanitized}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source({:directory, path}) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, {:directory, Path.expand(path)}, :sanitized}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source({:private_file, path}) when is_binary(path) do
    case {private_path?(path), File.lstat(path)} do
      {true, {:ok, %File.Stat{type: :regular}}} ->
        {:ok, {:file, Path.expand(path)}, :private}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source({:private_directory, path}) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, {:directory, Path.expand(path)}, :private}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source(_source), do: {:error, :invalid_trace_log}

  defp load(%__MODULE__{source: %EventSink{} = sink} = trace_log) do
    sink
    |> EventSink.events()
    |> normalize()
    |> validate_loaded(trace_log.max_source_bytes)
  catch
    :exit, _reason -> {:error, :source_unavailable}
  end

  defp load(%__MODULE__{source: {:file, path}, max_source_bytes: max_bytes}) do
    with {:ok, source} <- read_regular_file(path, max_bytes),
         {:ok, events} <- decode_jsonl(source),
         do: validate_loaded(events, max_bytes)
  end

  defp load(%__MODULE__{source: {:directory, directory}, max_source_bytes: max_bytes} = trace_log) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:ok, names} <- File.ls(directory),
         {:ok, events} <-
           load_files(directory, supported_names(names, trace_log.source_kind), max_bytes) do
      validate_loaded(events, max_bytes)
    else
      {:error, reason} = error when reason in [:source_limit_exceeded, :malformed_source] ->
        error

      _ ->
        {:error, :source_unavailable}
    end
  end

  defp supported_names(names, source_kind) do
    names
    |> Enum.filter(&supported_name?(&1, source_kind))
    |> Enum.sort()
  end

  defp supported_name?(name, source_kind) do
    Path.basename(name) == name and String.ends_with?(name, ".jsonl") and
      not inspection_path?(name) and private_path?(name) == (source_kind == :private)
  end

  defp capture_normal_directory(
         directory,
         max_source_bytes,
         max_directory_entries,
         max_trace_files,
         capture_hook,
         listing_hook
       ) do
    with {:ok, before_inventory} <-
           directory_inventory(directory, max_directory_entries, max_trace_files, listing_hook),
         {:ok, sources, source_bytes} <-
           read_inventory(directory, before_inventory.files, max_source_bytes),
         :ok <- run_capture_hook(capture_hook),
         {:ok, after_read_inventory} <-
           changed_inventory(directory, max_directory_entries, max_trace_files, listing_hook),
         :ok <- same_inventory(before_inventory, after_read_inventory),
         :ok <- verify_sources(directory, after_read_inventory.files, sources),
         {:ok, after_verify_inventory} <-
           changed_inventory(directory, max_directory_entries, max_trace_files, listing_hook),
         :ok <- same_inventory(after_read_inventory, after_verify_inventory),
         :ok <- verify_sources(directory, after_verify_inventory.files, sources),
         {:ok, events} <- decode_sources(sources),
         {:ok, events, source_id} <- validate_loaded(events, max_source_bytes) do
      {:ok, %{events: events, source_id: source_id, source_bytes: source_bytes}}
    end
  end

  defp directory_inventory(directory, max_directory_entries, max_trace_files, listing_hook) do
    with {:ok, %File.Stat{type: :directory} = directory_stat} <-
           File.lstat(directory, time: :posix),
         {:ok, names} <- bounded_directory_names(directory, max_directory_entries, listing_hook),
         {:ok, names} <-
           bounded_supported_names(names, :sanitized, max_trace_files),
         {:ok, files} <- inventory_files(directory, names) do
      {:ok, %{directory: stat_identity(directory_stat), files: files}}
    else
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, :source_limit_exceeded} = error -> error
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp changed_inventory(directory, max_directory_entries, max_trace_files, listing_hook) do
    case directory_inventory(directory, max_directory_entries, max_trace_files, listing_hook) do
      {:ok, inventory} -> {:ok, inventory}
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp bounded_directory_names(directory, max_directory_entries, listing_hook) do
    case BoundedWorker.run(
           fn ->
             if listing_hook, do: listing_hook.()

             with {:ok, names} <- File.ls(directory),
                  true <- length(names) <= max_directory_entries do
               {:ok, names}
             else
               false -> {:error, :source_limit_exceeded}
               {:error, _reason} -> {:error, :source_unavailable}
             end
           end,
           timeout_ms: @capture_listing_timeout_ms,
           max_heap_words: @capture_listing_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, result} -> result
      {:error, :heap_exceeded} -> {:error, :source_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp bounded_supported_names(names, source_kind, max_trace_files) do
    supported = Enum.filter(names, &supported_name?(&1, source_kind))

    if length(supported) <= max_trace_files,
      do: {:ok, Enum.sort(supported)},
      else: {:error, :source_limit_exceeded}
  end

  defp inventory_files(directory, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, files} ->
      case File.lstat(Path.join(directory, name), time: :posix) do
        {:ok, %File.Stat{type: :regular} = stat} ->
          {:cont, {:ok, [{name, stat_identity(stat)} | files]}}

        {:ok, %File.Stat{}} ->
          {:halt, {:error, :malformed_source}}

        {:error, _reason} ->
          {:halt, {:error, :source_unavailable}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  defp read_inventory(directory, files, max_source_bytes) do
    source_bytes = Enum.reduce(files, 0, fn {_name, stat}, bytes -> bytes + stat.size end)

    if source_bytes <= max_source_bytes do
      Enum.reduce_while(files, {:ok, []}, fn {name, expected}, {:ok, sources} ->
        case read_inventory_file(Path.join(directory, name), expected) do
          {:ok, source} -> {:cont, {:ok, [{name, source} | sources]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, sources} -> {:ok, Enum.reverse(sources), source_bytes}
        {:error, _reason} = error -> error
      end
    else
      {:error, :source_limit_exceeded}
    end
  end

  defp read_inventory_file(path, expected) do
    with {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)),
         {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        read_inventory_device(device, expected)
      after
        :file.close(device)
      end
    else
      {:ok, %File.Stat{}} -> {:error, :source_changed}
      {:error, :source_changed} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp read_inventory_device(device, expected) do
    with {:ok, before_info} <- :file.read_file_info(device, time: :posix),
         :ok <-
           same_stat_identity(expected, before_info |> File.Stat.from_record() |> stat_identity()),
         {:ok, source} <- read_exact_source(device, expected.size),
         {:ok, after_info} <- :file.read_file_info(device, time: :posix),
         :ok <-
           same_stat_identity(expected, after_info |> File.Stat.from_record() |> stat_identity()) do
      {:ok, source}
    else
      {:error, :source_changed} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp read_exact_source(device, 0) do
    case :file.read(device, 1) do
      :eof -> {:ok, ""}
      _ -> {:error, :source_changed}
    end
  end

  defp read_exact_source(device, expected_size) do
    case :file.read(device, expected_size + 1) do
      {:ok, source} when byte_size(source) == expected_size -> {:ok, source}
      _ -> {:error, :source_changed}
    end
  end

  defp verify_sources(directory, files, sources) do
    expected_sources = Map.new(sources)

    Enum.reduce_while(files, :ok, fn {name, expected}, :ok ->
      with {:ok, source} <- read_inventory_file(Path.join(directory, name), expected),
           true <- source == Map.fetch!(expected_sources, name) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :source_changed}}
      end
    end)
  end

  defp decode_sources(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn {_name, source}, {:ok, event_groups} ->
      case decode_jsonl(source) do
        {:ok, events} -> {:cont, {:ok, [events | event_groups]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, event_groups} -> {:ok, event_groups |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp same_inventory(inventory, inventory), do: :ok
  defp same_inventory(_before, _after), do: {:error, :source_changed}

  defp same_stat_identity(identity, identity), do: :ok
  defp same_stat_identity(_expected, _current), do: {:error, :source_changed}

  defp stat_identity(%File.Stat{} = stat) do
    %{
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      type: stat.type,
      size: stat.size,
      mode: stat.mode,
      mtime: stat.mtime,
      ctime: stat.ctime
    }
  end

  defp run_capture_hook(nil), do: :ok

  defp run_capture_hook(capture_hook) do
    case capture_hook.() do
      :ok -> :ok
      _other -> {:error, :source_unavailable}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  catch
    _kind, _reason -> {:error, :source_unavailable}
  end

  defp load_files(directory, names, max_bytes) do
    Enum.reduce_while(names, {:ok, {[], 0}}, fn name, {:ok, {event_groups, bytes}} ->
      path = Path.join(directory, name)
      remaining = max_bytes - bytes

      with {:ok, source} <- read_regular_file(path, remaining),
           {:ok, events} <- decode_jsonl(source) do
        {:cont, {:ok, {[events | event_groups], bytes + byte_size(source)}}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {event_groups, _bytes}} -> {:ok, event_groups |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp read_regular_file(_path, remaining) when remaining < 0,
    do: {:error, :source_limit_exceeded}

  defp read_regular_file(path, remaining) do
    with {:ok, %File.Stat{type: :regular} = expected} <- File.lstat(path),
         true <- expected.size <= remaining,
         {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened = File.Stat.from_record(file_info),
             :ok <- same_file(expected, opened),
             true <- opened.type == :regular and opened.size <= remaining do
          case :file.read(device, remaining + 1) do
            {:ok, source} when byte_size(source) <= remaining -> {:ok, source}
            :eof -> {:ok, ""}
            {:ok, _source} -> {:error, :source_limit_exceeded}
            {:error, _reason} -> {:error, :source_unavailable}
          end
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

  defp same_file(
         %File.Stat{major_device: device, minor_device: minor, inode: inode},
         %File.Stat{major_device: device, minor_device: minor, inode: inode}
       ),
       do: :ok

  defp same_file(_expected, _opened), do: {:error, :source_changed}

  defp decode_jsonl(source) do
    source
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      with {:ok, decoded} <- Jason.decode(line, objects: :ordered_objects),
           {:ok, event} <- ordered_map(decoded),
           true <- is_map(event) do
        {:cont, {:ok, [event | events]}}
      else
        _ -> {:halt, {:error, :malformed_source}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_map(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
        case ordered_map(value) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(map, key, normalized)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_json_key}
    end
  end

  defp ordered_map(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case ordered_map(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_map(value), do: {:ok, value}

  defp validate_loaded(events, max_bytes) when is_list(events) do
    encoded_bytes = Enum.reduce(events, 0, &(&2 + byte_size(Jason.encode!(&1))))

    with true <- encoded_bytes <= max_bytes,
         :ok <- validate_events(events) do
      source_id = digest(events)

      {:ok, events, source_id}
    else
      false -> {:error, :source_limit_exceeded}
      {:error, _reason} = error -> error
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  defp validate_events(events) do
    initial = %{sequences: %{}, run_traces: %{}, trace_runs: %{}, run_lifecycles: %{}}

    Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, state} ->
      with :ok <- validate_event(event),
           trace_id = event["trace_id"],
           run_id = event["run_id"],
           sequence = event["sequence"],
           previous = Map.get(state.sequences, trace_id, 0),
           true <- sequence > previous,
           :ok <- same_identity(state, run_id, trace_id),
           {:ok, run_lifecycles} <-
             advance_run_lifecycle(state.run_lifecycles, run_id, event["type"]) do
        {:cont,
         {:ok,
          %{
            sequences: Map.put(state.sequences, trace_id, sequence),
            run_traces: Map.put(state.run_traces, run_id, trace_id),
            trace_runs: Map.put(state.trace_runs, trace_id, run_id),
            run_lifecycles: run_lifecycles
          }}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :malformed_source}}
      end
    end)
    |> case do
      {:ok, _state} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp advance_run_lifecycle(run_lifecycles, run_id, type) do
    case {Map.get(run_lifecycles, run_id), type} do
      {nil, "run-started"} ->
        {:ok, Map.put(run_lifecycles, run_id, :open)}

      {:open, "run-stopped"} ->
        {:ok, Map.put(run_lifecycles, run_id, :stopped)}

      {:open, "run-started"} ->
        {:error, :malformed_source}

      {:open, _type} ->
        {:ok, run_lifecycles}

      {_lifecycle, _type} ->
        {:error, :malformed_source}
    end
  end

  defp same_identity(state, run_id, trace_id) do
    with existing_trace when existing_trace in [nil, trace_id] <-
           Map.get(state.run_traces, run_id),
         existing_run when existing_run in [nil, run_id] <- Map.get(state.trace_runs, trace_id) do
      :ok
    else
      _other -> {:error, :malformed_source}
    end
  end

  defp validate_event(event) when is_map(event) do
    with true <- Enum.sort(Map.keys(event)) == Enum.sort(@event_keys),
         1 <- event["schema_version"],
         :ok <- valid_string(event["run_id"]),
         :ok <- valid_string(event["trace_id"]),
         sequence when is_integer(sequence) and sequence > 0 <- event["sequence"],
         timestamp when is_binary(timestamp) <- event["timestamp"],
         {:ok, _datetime, 0} <- DateTime.from_iso8601(timestamp),
         type when is_binary(type) <- event["type"],
         true <- type =~ @event_type,
         true <- JSONValue.map?(event["data"]) do
      :ok
    else
      version when is_integer(version) and version != 1 -> {:error, :unsupported_version}
      _ -> {:error, :malformed_source}
    end
  end

  defp validate_event(_event), do: {:error, :malformed_source}

  defp runs(events, source_kind) do
    events
    |> Enum.group_by(& &1["run_id"])
    |> Enum.map(fn {run_id, run_events} -> run_metadata(run_id, run_events, source_kind) end)
    |> Enum.sort(fn left, right ->
      {timestamp_sort_value(left["start_timestamp"]), left["run_id"]} >=
        {timestamp_sort_value(right["start_timestamp"]), right["run_id"]}
    end)
  end

  defp run_metadata(run_id, events, source_kind) do
    started = Enum.find(events, &(&1["type"] == "run-started"))
    stopped = events |> Enum.filter(&(&1["type"] == "run-stopped")) |> List.last()
    labels = event_data(started, "labels", %{})
    workflow_calls = capability_call_count(events, "workflow")
    mission_calls = capability_call_count(events, "mission")

    %{
      "run_id" => run_id,
      "trace_id" => event_value(started || List.first(events), "trace_id"),
      "start_timestamp" => event_value(started, "timestamp"),
      "stop_timestamp" => event_value(stopped, "timestamp"),
      "status" => stringify(event_data(stopped, "outcome")),
      "terminal_reason" => event_data(stopped, "reason"),
      "labels" => labels,
      "tags" => Map.get(labels, "tags", %{}),
      "name" => Map.get(labels, "name"),
      "model" => Map.get(labels, "model"),
      "provider" => Map.get(labels, "provider"),
      "subordinate_evaluations" => evaluation_count(events, "mission"),
      "workflow_capability_calls" => workflow_calls,
      "mission_capability_calls" => mission_calls,
      "llm_calls" => capability_name_count(events, "llm-request"),
      "error_count" => Enum.count(events, &error_event?/1),
      "duration_ms" => duration_ms(started, stopped),
      "workflow_prelude" => event_data(started, "workflow_prelude", empty_prelude()),
      "mission_prelude" => event_data(started, "mission_prelude", empty_prelude()),
      "mission_inventory_hash" => event_data(started, "mission_inventory_hash"),
      "mission_inventory_bytes" => event_data(started, "mission_inventory_bytes"),
      "mission_model_context_hash" => event_data(started, "mission_model_context_hash"),
      "mission_model_context_bytes" => event_data(started, "mission_model_context_bytes"),
      "component_overrides" => event_data(started, "component_overrides", []),
      "connector_snapshots" => event_data(started, "connector_snapshots", []),
      "session_profile" => event_data(started, "session_profile"),
      "positions" => event_positions(started),
      "complete" => not is_nil(stopped),
      "truncated" => Enum.any?(events, &(&1["type"] == "events-dropped")),
      "schema_version" => 1,
      "source" => Atom.to_string(source_kind)
    }
  end

  # Absent prelude data projects to an empty graph. Legacy run-started
  # payloads without dependency_indices pass through verbatim — the query
  # layer never invents missing edges.
  defp empty_prelude,
    do: %{"component_ids" => [], "dependency_indices" => [], "hash" => nil}

  defp event_positions(%{"sequence" => sequence}) when is_integer(sequence) and sequence > 0,
    do: [sequence]

  defp event_positions(_event), do: []

  defp filter_runs(items, arguments) do
    Enum.filter(items, fn item ->
      equal_filter?(item, arguments, "status") and equal_filter?(item, arguments, "run_id") and
        equal_filter?(item, arguments, "trace_id") and equal_filter?(item, arguments, "name") and
        equal_filter?(item, arguments, "model") and equal_filter?(item, arguments, "provider") and
        tags_match?(item["tags"], arguments["tags"]) and
        after_or_equal?(item["start_timestamp"], arguments["from"]) and
        before_or_equal?(item["start_timestamp"], arguments["to"])
    end)
  end

  defp equal_filter?(item, arguments, key),
    do: is_nil(arguments[key]) or item[key] == arguments[key]

  defp tags_match?(_tags, nil), do: true

  defp tags_match?(tags, expected),
    do: Enum.all?(expected, fn {key, value} -> tags[key] == value end)

  defp after_or_equal?(_timestamp, nil), do: true
  defp after_or_equal?(nil, _from), do: false
  defp after_or_equal?(timestamp, from), do: compare_timestamp(timestamp, from) != :lt
  defp before_or_equal?(_timestamp, nil), do: true
  defp before_or_equal?(nil, _to), do: false
  defp before_or_equal?(timestamp, to), do: compare_timestamp(timestamp, to) != :gt

  defp compare_timestamp(left, right) do
    {:ok, left_at, 0} = DateTime.from_iso8601(left)
    {:ok, right_at, 0} = DateTime.from_iso8601(right)
    DateTime.compare(left_at, right_at)
  end

  defp timestamp_sort_value(nil), do: -1

  defp timestamp_sort_value(timestamp) do
    {:ok, datetime, 0} = DateTime.from_iso8601(timestamp)
    DateTime.to_unix(datetime, :microsecond)
  end

  defp turn_matches?(event, arguments) do
    status = stringify(event_data(event, "status") || event_data(event, "outcome"))

    (is_nil(arguments["status"]) or status == arguments["status"]) and
      (is_nil(arguments["evaluation_id"]) or
         event_data(event, "evaluation_id") == arguments["evaluation_id"]) and
      (is_nil(arguments["capability"]) or event_data(event, "name") == arguments["capability"])
  end

  defp counters(events) do
    %{
      "events" => length(events),
      "runs" => events |> Enum.map(& &1["run_id"]) |> Enum.uniq() |> length(),
      "errors" => Enum.count(events, &error_event?/1),
      "evaluations" => Enum.count(events, &(&1["type"] == "evaluation-started")),
      "workflow_capability_calls" => capability_call_count(events, "workflow"),
      "mission_capability_calls" => capability_call_count(events, "mission")
    }
  end

  defp capability_call_count(events, environment) do
    Enum.count(events, fn event ->
      event["type"] == "capability-started" and
        stringify(event_data(event, "environment")) == environment
    end)
  end

  defp capability_name_count(events, name) do
    Enum.count(events, &(&1["type"] == "capability-started" and event_data(&1, "name") == name))
  end

  defp evaluation_count(events, environment) do
    Enum.count(events, fn event ->
      event["type"] == "evaluation-started" and
        stringify(event_data(event, "environment")) == environment
    end)
  end

  defp error_event?(event) do
    event["type"] == "limit-exceeded" or
      stringify(event_data(event, "status") || event_data(event, "outcome")) == "error"
  end

  defp duration_ms(nil, _stopped), do: nil
  defp duration_ms(_started, nil), do: nil

  defp duration_ms(started, stopped) do
    with {:ok, started_at, 0} <- DateTime.from_iso8601(started["timestamp"]),
         {:ok, stopped_at, 0} <- DateTime.from_iso8601(stopped["timestamp"]) do
      max(DateTime.diff(stopped_at, started_at, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp page_options(arguments, source_id, operation) do
    limit = Map.get(arguments, "limit", @default_limit)
    query_id = digest({operation, Map.drop(arguments, ["cursor", "limit"])})

    with true <- is_integer(limit) and limit in 1..@max_limit,
         {:ok, offset} <- cursor_offset(Map.get(arguments, "cursor"), source_id, query_id) do
      {:ok, %{limit: limit, offset: offset, query_id: query_id}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_query}
    end
  end

  defp cursor_offset(nil, _source_id, _query_id), do: {:ok, 0}

  defp cursor_offset(cursor, source_id, query_id)
       when is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes do
    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{"offset" => offset, "source" => cursor_source, "query" => cursor_query} = payload} <-
           Jason.decode(encoded),
         true <- map_size(payload) == 3,
         true <- is_integer(offset) and offset >= 0,
         true <- is_binary(cursor_source) and is_binary(cursor_query) do
      cond do
        cursor_source != source_id -> {:error, :source_changed}
        cursor_query != query_id -> {:error, :invalid_query}
        true -> {:ok, offset}
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp cursor_offset(_cursor, _source_id, _query_id), do: {:error, :invalid_query}

  defp paginate(
         items,
         %{limit: limit, offset: offset, query_id: query_id},
         source_id,
         max_result_bytes
       ) do
    selected = items |> Enum.drop(offset) |> Enum.take(limit)
    fit_page(selected, items, offset, source_id, query_id, max_result_bytes)
  end

  defp fit_page(selected, all_items, offset, source_id, query_id, max_result_bytes) do
    result = page_result(selected, all_items, offset, source_id, query_id)

    cond do
      byte_size(Jason.encode!(result)) <= max_result_bytes ->
        {:ok, result}

      selected == [] ->
        {:error, :result_limit_exceeded}

      true ->
        context = {all_items, offset, source_id, query_id, max_result_bytes}

        fit_page_prefix(
          selected,
          context,
          1,
          length(selected) - 1,
          nil
        )
    end
  end

  defp fit_page_prefix(_selected, _context, lower, upper, best)
       when lower > upper do
    if best, do: {:ok, best}, else: {:error, :result_limit_exceeded}
  end

  defp fit_page_prefix(
         selected,
         {all_items, offset, source_id, query_id, max_result_bytes} = context,
         lower,
         upper,
         best
       ) do
    count = div(lower + upper, 2)
    result = page_result(Enum.take(selected, count), all_items, offset, source_id, query_id)

    if byte_size(Jason.encode!(result)) <= max_result_bytes do
      fit_page_prefix(
        selected,
        context,
        count + 1,
        upper,
        result
      )
    else
      fit_page_prefix(
        selected,
        context,
        lower,
        count - 1,
        best
      )
    end
  end

  defp page_result(selected, all_items, offset, source_id, query_id) do
    next_offset = offset + length(selected)
    more? = next_offset < length(all_items)

    %{
      "items" => selected,
      "next_cursor" => if(more?, do: encode_cursor(next_offset, source_id, query_id), else: nil),
      "truncated" => more?,
      "omitted_count" => max(length(all_items) - next_offset, 0)
    }
  end

  defp encode_cursor(offset, source_id, query_id) do
    %{"offset" => offset, "source" => source_id, "query" => query_id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp within_result_limit(value, max_result_bytes) do
    if byte_size(Jason.encode!(value)) <= max_result_bytes,
      do: :ok,
      else: {:error, :result_limit_exceeded}
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp validate_run_filters(arguments) do
    with :ok <-
           optional_strings(arguments, ~w(status run_id trace_id name model provider from to)),
         :ok <- valid_tags(arguments["tags"]),
         :ok <- valid_timestamp(arguments["from"]) do
      valid_timestamp(arguments["to"])
    end
  end

  defp validate_turn_filters(arguments),
    do: optional_strings(arguments, ~w(status evaluation_id capability))

  defp optional_strings(arguments, keys) do
    if Enum.all?(keys, &(is_nil(arguments[&1]) or valid_string(arguments[&1]) == :ok)),
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp valid_string(value)
       when is_binary(value) and byte_size(value) in 1..@max_string_bytes,
       do: if(String.valid?(value), do: :ok, else: {:error, :invalid_query})

  defp valid_string(_value), do: {:error, :invalid_query}
  defp valid_tags(nil), do: :ok

  defp valid_tags(tags) when is_map(tags) and map_size(tags) <= 16 do
    if Enum.all?(tags, fn {key, value} -> valid_string(key) == :ok and JSONValue.value?(value) end),
       do: :ok,
       else: {:error, :invalid_query}
  end

  defp valid_tags(_tags), do: {:error, :invalid_query}
  defp valid_timestamp(nil), do: :ok

  defp valid_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, _datetime, 0} -> :ok
      _ -> {:error, :invalid_query}
    end
  end

  defp valid_timestamp(_timestamp), do: {:error, :invalid_query}

  defp validate_keys(arguments, allowed) do
    if JSONValue.map?(arguments) and Map.keys(arguments) -- allowed == [],
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp event_data(nil, _key), do: nil
  defp event_data(event, key), do: get_in(event, ["data", key])
  defp event_data(nil, _key, default), do: default
  defp event_data(event, key, default), do: get_in(event, ["data", key]) || default
  defp event_value(nil, _key), do: nil
  defp event_value(event, key), do: event[key]
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp normalize(value) when is_struct(value, DateTime), do: DateTime.to_iso8601(value)
  defp normalize(nil), do: nil
  defp normalize(value) when is_boolean(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), normalize(item)} end)

  defp normalize(value), do: value

  defp private_path?(path), do: String.ends_with?(path, ".private.jsonl")
  defp inspection_path?(path), do: String.ends_with?(path, ".inspection.jsonl")
  defp reserved_path?(path), do: private_path?(path) or inspection_path?(path)
end
