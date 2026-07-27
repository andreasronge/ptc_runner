defmodule PtcRunner.Kernel.TraceSnapshot do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Lisp.RetainedSize

  @default_source_bytes 8_000_000
  @default_retained_bytes 32_000_000
  @default_result_bytes 1_000_000
  @default_directory_entries 4_096
  @default_trace_files 1_024
  @operations [:list_runs, :get_run, :list_turns, :counters]

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @type retained_limit_error ::
          {:source_retained_limit_exceeded,
           %{
             source: :ptc_trace_snapshot,
             measured_bytes: pos_integer(),
             limit_bytes: pos_integer()
           }}

  @spec start({:directory, binary()}, keyword()) ::
          {:ok, t()} | {:error, atom() | retained_limit_error()}
  def start(source, opts \\ [])

  def start({:directory, directory}, opts) when is_binary(directory) and is_list(opts) do
    allowed = [
      :owner,
      :max_source_bytes,
      :max_retained_bytes,
      :max_result_bytes,
      :max_directory_entries,
      :max_trace_files,
      :capture_hook,
      :listing_hook
    ]

    with true <- Keyword.keys(opts) -- allowed == [],
         true <- String.valid?(directory),
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
         max_trace_files when max_trace_files in 1..@default_trace_files <-
           Keyword.get(opts, :max_trace_files, @default_trace_files),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         listing_hook when is_nil(listing_hook) or is_function(listing_hook, 0) <-
           Keyword.get(opts, :listing_hook) do
      token = make_ref()

      case GenServer.start(
             __MODULE__,
             {directory, owner, token, max_source_bytes, max_retained_bytes, max_result_bytes,
              max_directory_entries, max_trace_files, capture_hook, listing_hook}
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

  def start(_source, _opts), do: {:error, :invalid_snapshot}

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
  @spec validate_inspection(t(), [map()]) :: :ok | {:error, atom()}
  def validate_inspection(%__MODULE__{} = snapshot, records) when is_list(records),
    do: call(snapshot, {:validate_inspection, records})

  def validate_inspection(_snapshot, _records), do: {:error, :invalid_snapshot}

  @doc false
  @spec transfer_owner(t(), pid()) :: :ok | {:error, atom()}
  def transfer_owner(%__MODULE__{} = snapshot, owner) when is_pid(owner),
    do: call(snapshot, {:transfer_owner, owner})

  def transfer_owner(_snapshot, _owner), do: {:error, :invalid_snapshot}

  @spec stop(t()) :: :ok
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
        {directory, owner, token, max_source_bytes, max_retained_bytes, max_result_bytes,
         max_directory_entries, max_trace_files, capture_hook, listing_hook}
      ) do
    owner_ref = Process.monitor(owner)

    capture = fn ->
      capture(
        directory,
        max_source_bytes,
        max_retained_bytes,
        max_directory_entries,
        max_trace_files,
        capture_hook,
        listing_hook
      )
    end

    case capture_for_owner(capture, owner, owner_ref) do
      {:ok, capture, retained_bytes} ->
        {:ok, snapshot_state(capture, retained_bytes, token, owner_ref, max_result_bytes)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({token, :info}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.info}, state}

  def handle_call({token, {:query, operation, arguments}}, _from, %{token: token} = state) do
    result =
      TraceLog.query_loaded(
        state.events,
        state.source_id,
        operation,
        arguments,
        state.max_result_bytes,
        :sanitized
      )

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

  defp capture(
         directory,
         max_source_bytes,
         max_retained_bytes,
         max_directory_entries,
         max_trace_files,
         capture_hook,
         listing_hook
       ) do
    with {:ok, capture} <-
           TraceLog.capture_directory(directory,
             max_source_bytes: max_source_bytes,
             max_directory_entries: max_directory_entries,
             max_trace_files: max_trace_files,
             capture_hook: capture_hook,
             listing_hook: listing_hook
           ),
         retained_bytes when is_integer(retained_bytes) and retained_bytes <= max_retained_bytes <-
           RetainedSize.bytes(capture.events) do
      retained_capture = %{capture | events: RetainedSize.detach_binaries(capture.events)}
      {:ok, retained_capture, retained_bytes}
    else
      retained_bytes when is_integer(retained_bytes) ->
        {:error,
         {:source_retained_limit_exceeded,
          %{
            source: :ptc_trace_snapshot,
            measured_bytes: retained_bytes,
            limit_bytes: max_retained_bytes
          }}}

      :oversized ->
        {:error, :source_retained_limit_exceeded}

      {:error, :invalid_trace_log} ->
        {:error, :invalid_snapshot}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}
    end
  end

  defp capture_for_owner(capture, owner, owner_ref) do
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

  defp snapshot_state(capture, retained_bytes, token, owner_ref, max_result_bytes) do
    %{
      token: token,
      owner_ref: owner_ref,
      events: capture.events,
      source_id: capture.source_id,
      max_result_bytes: max_result_bytes,
      info: %{
        capture_id: capture.source_id,
        captured_at: DateTime.utc_now(),
        run_count: capture.events |> MapSet.new(& &1["run_id"]) |> MapSet.size(),
        source_bytes: capture.source_bytes,
        retained_bytes: retained_bytes
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
