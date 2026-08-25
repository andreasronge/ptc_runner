defmodule PtcRunner.Kernel.TraceSnapshot do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.ResultLimit
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.SelectedCanonicalSource
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Lisp.RetainedSize

  @default_source_bytes 8_000_000
  @default_retained_bytes 32_000_000
  @default_result_bytes 1_000_000
  @default_directory_entries 4_096
  @default_trace_files 1_024
  @capture_heap_words 10_000_000
  @capture_timeout_ms 15_000
  @operations [:list_runs, :get_run, :list_turns, :counters]

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @type retained_limit_error ::
          {:source_retained_limit_exceeded,
           %{
             source: :ptc_trace_snapshot | :ptc_private_trace_snapshot,
             measured_bytes: pos_integer(),
             limit_bytes: pos_integer()
           }}

  @spec start(term(), keyword()) :: {:ok, t()} | {:error, atom() | retained_limit_error()}
  def start(source, opts \\ [])

  def start({:directory, directory}, opts) when is_binary(directory) and is_list(opts),
    do: start_capture({:directory, directory}, :ptc_trace_snapshot, :sanitized, nil, opts)

  def start({:private_authorized_directory, directory}, opts)
      when is_binary(directory) and is_list(opts),
      do:
        start_capture(
          {:directory, directory},
          :ptc_private_trace_snapshot,
          :private,
          nil,
          opts
        )

  def start({:file, path, run_ref}, opts) when is_binary(path) and is_list(opts),
    do: start_capture({:file, path}, :ptc_trace_snapshot, :sanitized, run_ref, opts)

  def start({:private_authorized_file, path, run_ref}, opts)
      when is_binary(path) and is_list(opts),
      do:
        start_capture(
          {:file, path},
          :ptc_private_trace_snapshot,
          :private,
          run_ref,
          opts
        )

  def start({:selected_canonical, directory, run_ref}, opts)
      when is_binary(directory) and is_binary(run_ref) and is_list(opts) do
    case SelectedCanonicalSource.resolve_trace(directory, run_ref) do
      {:ok, {:file, path, ^run_ref}} ->
        start_capture(
          {:selected_file, path, directory},
          :ptc_private_trace_snapshot,
          :sanitized,
          run_ref,
          opts
        )

      {:ok, {:private_authorized_file, path, ^run_ref}} ->
        start_capture(
          {:selected_file, path, directory},
          :ptc_private_trace_snapshot,
          :private,
          run_ref,
          opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start(_source, _opts), do: {:error, :invalid_snapshot}

  defp start_capture(capture_source, source, source_kind, selected_run_ref, opts)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot] and
              source_kind in [:sanitized, :private] and is_list(opts) do
    allowed = [
      :owner,
      :resource_registrar,
      :max_source_bytes,
      :max_retained_bytes,
      :max_result_bytes,
      :max_directory_entries,
      :max_trace_files,
      :capture_heap_words,
      :capture_deadline_ms,
      :capture_hook,
      :listing_hook
    ]

    with true <- Keyword.keys(opts) -- allowed == [],
         owner when is_pid(owner) <- Keyword.get(opts, :owner, self()),
         registrar <- Keyword.get(opts, :resource_registrar),
         max_source_bytes when max_source_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         max_retained_bytes when max_retained_bytes in 1..@default_retained_bytes <-
           Keyword.get(opts, :max_retained_bytes, @default_retained_bytes),
         max_result_bytes when max_result_bytes in 1..@default_result_bytes <-
           Keyword.get(opts, :max_result_bytes, @default_result_bytes),
         max_directory_entries
         when max_directory_entries in 1..@default_directory_entries <-
           Keyword.get(opts, :max_directory_entries, @default_directory_entries),
         max_trace_files when max_trace_files in 1..@default_trace_files <-
           Keyword.get(opts, :max_trace_files, @default_trace_files),
         capture_heap_words when capture_heap_words in 233..@capture_heap_words <-
           Keyword.get(opts, :capture_heap_words, @capture_heap_words),
         capture_deadline_ms when is_integer(capture_deadline_ms) <-
           Keyword.get(
             opts,
             :capture_deadline_ms,
             System.monotonic_time(:millisecond) + @capture_timeout_ms
           ),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         listing_hook when is_nil(listing_hook) or is_function(listing_hook, 0) <-
           Keyword.get(opts, :listing_hook) do
      token = make_ref()

      case GenServer.start(
             __MODULE__,
             {capture_source, source, source_kind, selected_run_ref, owner, registrar, token,
              max_source_bytes, max_retained_bytes, max_result_bytes, max_directory_entries,
              max_trace_files, capture_heap_words, capture_deadline_ms, capture_hook,
              listing_hook}
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

  defp start_capture(_capture_source, _source, _source_kind, _selected_run_ref, _opts),
    do: {:error, :invalid_snapshot}

  @spec query(t(), :list_runs | :get_run | :list_turns | :counters, map()) ::
          {:ok, map()} | {:error, atom()}
  def query(%__MODULE__{} = snapshot, operation, arguments)
      when operation in @operations and is_map(arguments),
      do: call(snapshot, {:query, operation, arguments})

  def query(_snapshot, _operation, _arguments), do: {:error, :invalid_query}

  @spec info(t()) :: {:ok, map()} | {:error, atom()}
  def info(%__MODULE__{} = snapshot), do: call(snapshot, :info)
  def info(_snapshot), do: {:error, :invalid_snapshot}

  @doc false
  @spec source(term()) ::
          {:ok, :ptc_trace_snapshot | :ptc_private_trace_snapshot} | {:error, atom()}
  def source(%__MODULE__{} = snapshot), do: call(snapshot, :source)
  def source(_snapshot), do: {:error, :invalid_snapshot}

  @doc false
  @spec result_limit(t()) :: {:ok, pos_integer()} | {:error, atom()}
  def result_limit(%__MODULE__{} = snapshot), do: call(snapshot, :result_limit)
  def result_limit(_snapshot), do: {:error, :invalid_snapshot}

  @doc false
  @spec run_exists?(t(), binary()) :: {:ok, boolean()} | {:error, atom()}
  def run_exists?(%__MODULE__{} = snapshot, run_id) when is_binary(run_id),
    do: call(snapshot, {:run_exists, run_id})

  def run_exists?(_snapshot, _run_id), do: {:error, :invalid_query}

  @doc false
  @spec validate_inspection(t(), [map()]) :: :ok | {:error, atom()}
  def validate_inspection(%__MODULE__{} = snapshot, records) when is_list(records),
    do: call(snapshot, {:validate_inspection, records})

  def validate_inspection(_snapshot, _records), do: {:error, :invalid_snapshot}

  @doc false
  @spec analysis_facts(t(), [binary()]) :: {:ok, map()} | {:error, atom()}
  def analysis_facts(%__MODULE__{} = snapshot, run_ids) when is_list(run_ids),
    do: call(snapshot, {:analysis_facts, run_ids})

  def analysis_facts(_snapshot, _run_ids), do: {:error, :invalid_snapshot}

  @doc false
  @spec transfer_owner(t(), pid()) :: :ok | {:error, atom()}
  def transfer_owner(%__MODULE__{} = snapshot, owner) when is_pid(owner),
    do: call(snapshot, {:transfer_owner, owner})

  def transfer_owner(_snapshot, _owner), do: {:error, :invalid_snapshot}

  @spec stop(term()) :: :ok
  def stop(%__MODULE__{} = snapshot) do
    case call(snapshot, :stop) do
      :ok -> :ok
      {:error, :snapshot_unavailable} -> :ok
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
        {capture_source, source, source_kind, selected_run_ref, owner, registrar, token,
         max_source_bytes, max_retained_bytes, max_result_bytes, max_directory_entries,
         max_trace_files, capture_heap_words, capture_deadline_ms, capture_hook, listing_hook}
      ) do
    owner_ref = Process.monitor(owner)

    capture_config = %{
      source: source,
      source_kind: source_kind,
      selected_run_ref: selected_run_ref,
      max_source_bytes: max_source_bytes,
      max_retained_bytes: max_retained_bytes,
      max_directory_entries: max_directory_entries,
      max_trace_files: max_trace_files
    }

    capture = fn ->
      capture(capture_source, capture_config, capture_hook, listing_hook)
    end

    with :ok <- ResourceRegistrar.register_root(registrar),
         {:ok, capture, retained_bytes} <-
           capture_for_owner(capture, owner, owner_ref, capture_heap_words, capture_deadline_ms) do
      {:ok, snapshot_state(capture, source, retained_bytes, token, owner_ref, max_result_bytes)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({token, :info}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.info}, state}

  def handle_call({token, :source}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.info.source}, state}

  def handle_call({token, :result_limit}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.max_result_bytes}, state}

  def handle_call({token, {:run_exists, run_id}}, _from, %{token: token} = state) do
    result =
      if valid_run_id?(run_id),
        do: {:ok, Map.has_key?(state.analysis.runs_by_id, run_id)},
        else: {:error, :invalid_query}

    {:reply, result, state}
  end

  def handle_call({token, {:query, operation, arguments}}, _from, %{token: token} = state) do
    {:reply, query_with_snapshot_hash(state, operation, arguments), state}
  end

  def handle_call({token, {:analysis_facts, run_ids}}, _from, %{token: token} = state) do
    result =
      if length(run_ids) <= @default_trace_files and run_ids == Enum.uniq(run_ids) and
           Enum.all?(run_ids, &valid_run_id?/1) do
        {:ok,
         %{
           "trace_snapshot_hash" => state.info.snapshot_hash,
           "runs" => Map.take(state.analysis.facts_by_run_id, run_ids)
         }}
      else
        {:error, :invalid_query}
      end

    {:reply, result, state}
  end

  def handle_call(
        {token,
         {:validate_inspection, [%{"run_id" => run_id, "trace_id" => trace_id} | _] = records}},
        _from,
        %{token: token} = state
      ) do
    matching_identity? =
      Enum.any?(
        state.events,
        &(&1["run_id"] == run_id and &1["trace_id"] == trace_id)
      )

    result =
      if matching_identity?,
        do: InspectionArtifact.validate_correlations(records, state.events),
        else: {:error, :inspection_correlation_missing}

    {:reply, result, state}
  end

  def handle_call({token, {:validate_inspection, _records}}, _from, %{token: token} = state),
    do: {:reply, {:error, :inspection_correlation_missing}, state}

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

  defp capture({:directory, directory}, config, capture_hook, listing_hook) do
    case TraceLog.capture_directory(directory,
           max_source_bytes: config.max_source_bytes,
           max_directory_entries: config.max_directory_entries,
           max_trace_files: config.max_trace_files,
           source_kind: config.source_kind,
           capture_hook: capture_hook,
           listing_hook: listing_hook
         ) do
      {:ok, capture} ->
        retain_capture(capture, config)

      {:error, :invalid_trace_log} ->
        {:error, :invalid_snapshot}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}
    end
  end

  defp capture({:file, path}, config, capture_hook, _listing_hook) do
    capture_file_source(path, config, capture_hook, fn -> :ok end)
  end

  defp capture({:selected_file, path, directory}, config, capture_hook, _listing_hook) do
    capture_file_source(path, config, capture_hook, fn ->
      prove_selected_trace(directory, path, config)
    end)
  end

  defp capture_file_source(path, config, capture_hook, after_capture) do
    case TraceLog.capture_file(path,
           max_source_bytes: config.max_source_bytes,
           source_kind: config.source_kind,
           capture_hook: capture_hook
         ) do
      {:ok, capture} ->
        with :ok <- after_capture.(),
             {:ok, source_id} <- selected_source_id(config, capture) do
          capture
          |> Map.put(:source_id, source_id)
          |> retain_capture(config)
        end

      {:error, :invalid_trace_log} ->
        {:error, :invalid_snapshot}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}
    end
  end

  defp prove_selected_trace(directory, path, config) do
    case SelectedCanonicalSource.resolve_trace(directory, config.selected_run_ref) do
      {:ok, {:file, ^path, _run_ref}} when config.source_kind == :sanitized ->
        :ok

      {:ok, {:private_authorized_file, ^path, _run_ref}} when config.source_kind == :private ->
        :ok

      {:ok, _resolved} ->
        {:error, :source_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp selected_source_id(config, capture) do
    with {:ok, trace_id} <-
           SelectedCanonicalSource.prove_trace_events(capture.events, config.selected_run_ref) do
      {:ok,
       SelectedCanonicalSource.trace_source_id(
         config.selected_run_ref,
         config.source,
         config.source_kind,
         capture.source_id,
         trace_id
       )}
    end
  end

  defp retain_capture(capture, config) do
    analysis = TraceLog.compile_analysis(capture.events, capture.run_sources)

    retained_bytes =
      RetainedSize.bytes({capture.events, capture.run_sources, analysis})

    cond do
      is_integer(retained_bytes) and retained_bytes <= config.max_retained_bytes ->
        retained_capture =
          capture
          |> Map.put(:events, RetainedSize.detach_binaries(capture.events))
          |> Map.put(:run_sources, RetainedSize.detach_binaries(capture.run_sources))
          |> Map.put(:analysis, RetainedSize.detach_binaries(analysis))

        {:ok, retained_capture, retained_bytes}

      is_integer(retained_bytes) ->
        {:error,
         {:source_retained_limit_exceeded,
          %{
            source: config.source,
            measured_bytes: retained_bytes,
            limit_bytes: config.max_retained_bytes
          }}}

      retained_bytes == :oversized ->
        {:error, :source_retained_limit_exceeded}

      true ->
        {:error, :source_unavailable}
    end
  end

  defp capture_for_owner(capture, owner, owner_ref, capture_heap_words, capture_deadline_ms) do
    reply_alias = Process.alias()
    reply_ref = make_ref()

    {worker, worker_ref} =
      Process.spawn(
        fn -> send(reply_alias, {reply_ref, capture.()}) end,
        [
          {:max_heap_size,
           %{
             size: capture_heap_words,
             kill: true,
             error_logger: false,
             include_shared_binaries: true
           }},
          :monitor
        ]
      )

    timeout = max(capture_deadline_ms - System.monotonic_time(:millisecond), 0)

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

      {:DOWN, ^worker_ref, :process, ^worker, :killed} ->
        Process.unalias(reply_alias)
        {:error, :source_retained_limit_exceeded}

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        Process.unalias(reply_alias)
        {:error, :source_unavailable}
    after
      timeout ->
        terminate_capture(worker, worker_ref, reply_alias)
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

  defp snapshot_state(capture, source, retained_bytes, token, owner_ref, max_result_bytes) do
    %{
      token: token,
      owner_ref: owner_ref,
      events: capture.events,
      run_sources: capture.run_sources,
      analysis: capture.analysis,
      source_id: capture.source_id,
      max_result_bytes: max_result_bytes,
      info: %{
        capture_id: capture.source_id,
        captured_at: DateTime.utc_now(),
        file_count: capture.file_count,
        excluded_trace_files: capture.excluded_trace_files,
        source: source,
        run_count: capture.events |> MapSet.new(& &1["run_id"]) |> MapSet.size(),
        snapshot_hash: SafeMetadata.fingerprint(capture.source_id),
        source_bytes: capture.source_bytes,
        retained_bytes: retained_bytes
      }
    }
  end

  defp query_with_snapshot_hash(state, operation, arguments) do
    metadata =
      %{"snapshot_hash" => state.info.snapshot_hash}
      |> Map.merge(TraceLog.source_presence_metadata(operation, state.info.excluded_trace_files))

    snapshot_query(state, operation, arguments, state.max_result_bytes, metadata)
  end

  defp snapshot_query(
         state,
         :get_run,
         %{"run_id" => run_id} = arguments,
         max_bytes,
         metadata
       )
       when map_size(arguments) == 1 and is_binary(run_id) do
    case Map.fetch(state.analysis.runs_by_id, run_id) do
      {:ok, run} ->
        result = Map.merge(run, metadata)

        with :ok <- ResultLimit.validate(result, max_bytes), do: {:ok, result}

      :error ->
        {:error, :not_found}
    end
  end

  defp snapshot_query(state, operation, arguments, max_bytes, metadata) do
    TraceLog.query_loaded(
      state.events,
      state.source_id,
      operation,
      arguments,
      max_bytes,
      state.run_sources,
      metadata
    )
  end

  defp valid_run_id?(run_id),
    do: is_binary(run_id) and byte_size(run_id) in 1..4_096 and String.valid?(run_id)

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
