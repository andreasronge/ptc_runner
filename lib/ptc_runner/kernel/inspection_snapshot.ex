defmodule PtcRunner.Kernel.InspectionSnapshot do
  @moduledoc """
  Owner-bound immutable capture of private inspection artifacts.

  A snapshot inventories one bounded directory, loads each regular
  `.inspection.jsonl` artifact exactly once through `InspectionArtifact`, and
  validates every artifact against an already captured `TraceSnapshot`.
  Duplicate runs, orphaned identities, malformed artifacts, incomplete
  input/output joins, replacement during capture, and aggregate or retained
  limits fail the entire capture. No partial catalog is published.

  The owner process holds only compiled query collections and safe metadata.
  Paths and private records are redacted from process status. Its tokenized
  handle is opaque and capabilities retain only that handle.
  """

  use GenServer

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionQuery
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Lisp.RetainedSize

  @default_source_bytes 64_000_000
  @default_retained_bytes 128_000_000
  @default_result_bytes 1_000_000
  @default_directory_entries 4_096
  @default_files 1_024
  @max_artifact_bytes 16_000_000
  @listing_timeout_ms 5_000
  @listing_heap_words 1_000_000
  @operations [
    :list_runs,
    :model_exchanges,
    :capability_calls,
    :generated_sources,
    :effective_preludes,
    :provider_exchanges
  ]

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @typedoc """
  Opaque handle to the canonical trace snapshot this capture is correlated with.

  Declared locally so the public inspection API does not borrow a type from the
  internal trace-snapshot implementation.
  """
  @type trace_snapshot :: term()

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @type retained_limit_error ::
          {:source_retained_limit_exceeded,
           %{
             source: :ptc_inspection_snapshot,
             measured_bytes: pos_integer(),
             limit_bytes: pos_integer()
           }}

  @spec start({:directory, binary()}, trace_snapshot(), keyword()) ::
          {:ok, t()} | {:error, atom() | retained_limit_error()}
  def start(source, trace_snapshot, opts \\ [])

  def start({:directory, directory}, %TraceSnapshot{} = trace_snapshot, opts)
      when is_binary(directory) and is_list(opts) do
    allowed = [
      :owner,
      :max_source_bytes,
      :max_retained_bytes,
      :max_result_bytes,
      :max_directory_entries,
      :max_files,
      :capture_hook,
      :listing_hook
    ]

    with true <- Keyword.keys(opts) -- allowed == [],
         true <- String.valid?(directory),
         true <- TraceSnapshot.valid?(trace_snapshot),
         owner when is_pid(owner) <- Keyword.get(opts, :owner, self()),
         max_source_bytes when max_source_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         max_retained_bytes when max_retained_bytes in 1..@default_retained_bytes <-
           Keyword.get(opts, :max_retained_bytes, @default_retained_bytes),
         max_result_bytes when max_result_bytes in 1..@default_result_bytes <-
           Keyword.get(opts, :max_result_bytes, @default_result_bytes),
         max_directory_entries
         when max_directory_entries in 1..@default_directory_entries <-
           Keyword.get(opts, :max_directory_entries, @default_directory_entries),
         max_files when max_files in 1..@default_files <-
           Keyword.get(opts, :max_files, @default_files),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         listing_hook when is_nil(listing_hook) or is_function(listing_hook, 0) <-
           Keyword.get(opts, :listing_hook) do
      token = make_ref()

      case GenServer.start(
             __MODULE__,
             {Path.expand(directory), trace_snapshot, owner, token, max_source_bytes,
              max_retained_bytes, max_result_bytes, max_directory_entries, max_files,
              capture_hook, listing_hook}
           ) do
        {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
        {:error, {:source_retained_limit_exceeded, _details} = reason} -> {:error, reason}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        {:error, _reason} -> {:error, :source_unavailable}
      end
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  def start(_source, _trace_snapshot, _opts), do: {:error, :invalid_snapshot}

  @spec query(t(), InspectionQuery.operation(), map()) ::
          {:ok, map()} | {:error, atom()}
  def query(%__MODULE__{} = snapshot, operation, arguments)
      when operation in @operations and is_map(arguments),
      do: call(snapshot, {:query, operation, arguments})

  def query(_snapshot, _operation, _arguments), do: {:error, :invalid_query}

  @spec info(t()) :: {:ok, map()} | {:error, atom()}
  def info(%__MODULE__{} = snapshot), do: call(snapshot, :info)
  def info(_snapshot), do: {:error, :invalid_snapshot}

  @doc false
  @spec transfer_owner(t(), pid()) :: :ok | {:error, atom()}
  def transfer_owner(%__MODULE__{} = snapshot, owner) when is_pid(owner),
    do: call(snapshot, {:transfer_owner, owner})

  def transfer_owner(_snapshot, _owner), do: {:error, :invalid_snapshot}

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = snapshot) do
    case call(snapshot, :stop) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  def stop(_snapshot), do: :ok

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{pid: pid, token: token}),
    do: is_pid(pid) and is_reference(token)

  def valid?(_snapshot), do: false

  @doc false
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{pid: pid}), do: Process.alive?(pid)

  @impl GenServer
  def init(
        {directory, trace_snapshot, owner, token, max_source_bytes, max_retained_bytes,
         max_result_bytes, max_directory_entries, max_files, capture_hook, listing_hook}
      ) do
    owner_ref = Process.monitor(owner)
    trace_ref = Process.monitor(trace_snapshot.pid)

    capture = fn ->
      capture(
        directory,
        trace_snapshot,
        max_source_bytes,
        max_retained_bytes,
        max_directory_entries,
        max_files,
        capture_hook,
        listing_hook
      )
    end

    case capture_for_dependencies(capture, owner, owner_ref, trace_snapshot.pid, trace_ref) do
      {:ok, capture} ->
        {:ok, snapshot_state(capture, token, owner_ref, trace_ref, max_result_bytes)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({token, :info}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.info}, state}

  def handle_call({token, {:query, operation, arguments}}, _from, %{token: token} = state) do
    result =
      InspectionQuery.query(
        state.collections,
        state.source_id,
        operation,
        arguments,
        state.max_result_bytes
      )

    {:reply, result, state}
  end

  def handle_call({token, :stop}, _from, %{token: token} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call({token, {:transfer_owner, owner}}, _from, %{token: token} = state)
      when is_pid(owner) do
    if Process.alive?(owner) do
      Process.demonitor(state.owner_ref, [:flush])
      {:reply, :ok, %{state | owner_ref: Process.monitor(owner)}}
    else
      {:reply, {:error, :snapshot_unavailable}, state}
    end
  end

  def handle_call({_token, _request}, _from, state),
    do: {:reply, {:error, :invalid_snapshot}, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :invalid_snapshot}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, owner_ref, :process, _owner, _reason}, %{owner_ref: owner_ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, trace_ref, :process, _trace, _reason}, %{trace_ref: trace_ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  defp call(%__MODULE__{pid: pid, token: token}, request) when is_pid(pid) do
    GenServer.call(pid, {token, request}, :infinity)
  catch
    :exit, _reason -> {:error, :snapshot_unavailable}
  end

  defp call(_snapshot, _request), do: {:error, :invalid_snapshot}

  defp capture(
         directory,
         trace_snapshot,
         max_source_bytes,
         max_retained_bytes,
         max_directory_entries,
         max_files,
         capture_hook,
         listing_hook
       ) do
    with {:ok, trace_info} <- TraceSnapshot.info(trace_snapshot),
         {:ok, before} <- inventory(directory, max_directory_entries, max_files, listing_hook),
         true <- before.source_bytes <= max_source_bytes,
         {:ok, artifacts} <- load_artifacts(directory, before.files),
         :ok <- run_capture_hook(capture_hook),
         {:ok, after_capture} <-
           changed_inventory(directory, max_directory_entries, max_files, listing_hook),
         :ok <- same_inventory(before, after_capture),
         :ok <- validate_unique_runs(artifacts),
         :ok <- validate_correlations(artifacts, trace_snapshot),
         {:ok, compiled} <- InspectionQuery.compile(artifacts, trace_info.capture_id),
         retained_bytes
         when is_integer(retained_bytes) and retained_bytes <= max_retained_bytes <-
           RetainedSize.bytes(compiled.collections) do
      collections = RetainedSize.detach_binaries(compiled.collections)

      {:ok,
       %{
         source_id: compiled.source_id,
         collections: collections,
         source_bytes: before.source_bytes,
         retained_bytes: retained_bytes,
         file_count: length(before.files),
         run_count: length(artifacts),
         trace_capture_id: trace_info.capture_id
       }}
    else
      false ->
        {:error, :source_limit_exceeded}

      retained_bytes when is_integer(retained_bytes) ->
        {:error,
         {:source_retained_limit_exceeded,
          %{
            source: :ptc_inspection_snapshot,
            measured_bytes: retained_bytes,
            limit_bytes: max_retained_bytes
          }}}

      :oversized ->
        {:error, :source_retained_limit_exceeded}

      {:error, reason} when is_atom(reason) ->
        {:error, normalize_capture_error(reason)}
    end
  end

  defp inventory(directory, max_directory_entries, max_files, listing_hook) do
    with {:ok, %File.Stat{type: :directory} = directory_stat} <-
           File.lstat(directory, time: :posix),
         {:ok, names} <- bounded_names(directory, max_directory_entries, listing_hook),
         supported = Enum.filter(names, &supported_name?/1) |> Enum.sort(),
         true <- length(supported) <= max_files,
         {:ok, files} <- inventory_files(directory, supported) do
      {:ok,
       %{
         directory: stat_identity(directory_stat),
         files: files,
         source_bytes: Enum.reduce(files, 0, fn {_name, stat}, total -> total + stat.size end)
       }}
    else
      false -> {:error, :source_limit_exceeded}
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} = error -> error
    end
  end

  defp changed_inventory(directory, max_directory_entries, max_files, listing_hook) do
    case inventory(directory, max_directory_entries, max_files, listing_hook) do
      {:ok, inventory} -> {:ok, inventory}
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp bounded_names(directory, max_directory_entries, listing_hook) do
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
           timeout_ms: @listing_timeout_ms,
           max_heap_words: @listing_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, result} -> result
      {:error, :heap_exceeded} -> {:error, :source_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp supported_name?(name) do
    is_binary(name) and Path.basename(name) == name and
      String.ends_with?(name, ".inspection.jsonl")
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

  defp load_artifacts(directory, files) do
    Enum.reduce_while(files, {:ok, []}, fn {name, expected}, {:ok, artifacts} ->
      path = Path.join(directory, name)

      case InspectionArtifact.load(path, max_bytes: min(expected.size, @max_artifact_bytes)) do
        {:ok, records} -> {:cont, {:ok, [records | artifacts]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_unique_runs(artifacts) do
    run_ids = Enum.map(artifacts, fn [first | _rest] -> first["run_id"] end)

    if run_ids == Enum.uniq(run_ids),
      do: :ok,
      else: {:error, :duplicate_inspection_run}
  end

  defp validate_correlations(artifacts, trace_snapshot) do
    Enum.reduce_while(artifacts, :ok, fn records, :ok ->
      case TraceSnapshot.validate_inspection(trace_snapshot, records) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp same_inventory(inventory, inventory), do: :ok
  defp same_inventory(_before, _after), do: {:error, :source_changed}

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

  defp normalize_capture_error(reason)
       when reason in [
              :source_limit_exceeded,
              :source_retained_limit_exceeded,
              :source_changed,
              :source_unavailable,
              :inspection_correlation_missing,
              :incomplete_inspection_correlation,
              :duplicate_inspection_run
            ],
       do: reason

  defp normalize_capture_error(_reason), do: :invalid_snapshot

  defp capture_for_dependencies(capture, owner, owner_ref, trace, trace_ref) do
    reply_alias = Process.alias()
    reply_ref = make_ref()

    {worker, worker_ref} =
      Process.spawn(fn -> send(reply_alias, {reply_ref, capture.()}) end, [:monitor])

    receive do
      {^reply_ref, result} ->
        Process.unalias(reply_alias)
        Process.demonitor(worker_ref, [:flush])

        if Process.alive?(owner),
          do: result,
          else: {:error, :snapshot_unavailable}

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        terminate_capture(worker, worker_ref, reply_alias)
        {:error, :snapshot_unavailable}

      {:DOWN, ^trace_ref, :process, ^trace, _reason} ->
        terminate_capture(worker, worker_ref, reply_alias)
        {:error, :snapshot_unavailable}

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        Process.unalias(reply_alias)
        {:error, :source_unavailable}
    end
  end

  defp terminate_capture(worker, worker_ref, reply_alias) do
    Process.unalias(reply_alias)
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp snapshot_state(capture, token, owner_ref, trace_ref, max_result_bytes) do
    %{
      token: token,
      owner_ref: owner_ref,
      trace_ref: trace_ref,
      collections: capture.collections,
      source_id: capture.source_id,
      max_result_bytes: max_result_bytes,
      info: %{
        capture_id: capture.source_id,
        captured_at: DateTime.utc_now(),
        file_count: capture.file_count,
        run_count: capture.run_count,
        source_bytes: capture.source_bytes,
        retained_bytes: capture.retained_bytes,
        trace_capture_id: capture.trace_capture_id
      }
    }
  end

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
