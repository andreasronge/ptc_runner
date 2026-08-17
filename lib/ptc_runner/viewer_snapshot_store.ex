defmodule PtcRunner.ViewerSnapshotStore do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.ProjectViewerAdapter
  alias PtcRunner.Kernel.TraceSnapshot

  @capture_timeout_ms 15_000
  @call_timeout_ms @capture_timeout_ms + 5_000
  @operations [:list_runs, :get_run, :list_turns, :counters]

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(
          {:directory | :private_authorized_directory, binary()},
          (TraceSnapshot.t(), integer() ->
             {:ok, InspectionSnapshot.t() | nil} | {:error, term()}),
          keyword()
        ) :: {:ok, t()} | {:error, term()}
  def start(trace_source, capture_inspection, opts \\ [])

  def start({kind, directory} = trace_source, capture_inspection, opts)
      when kind in [:directory, :private_authorized_directory] and is_binary(directory) and
             is_function(capture_inspection, 2) and is_list(opts) do
    with [] <- Keyword.keys(opts) -- [:owner],
         owner when is_pid(owner) <- Keyword.get(opts, :owner, self()) do
      token = make_ref()

      case GenServer.start(__MODULE__, {trace_source, capture_inspection, owner, token}) do
        {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
        {:error, reason} -> {:error, reason}
      end
    else
      _invalid -> {:error, :invalid_snapshot_store}
    end
  end

  def start(_trace_source, _capture_inspection, _opts),
    do: {:error, :invalid_snapshot_store}

  @spec query(t(), atom(), map()) :: {:ok, map()} | {:error, atom()}
  # ex_dna:disable-for-next-line -- this capability facade intentionally mirrors snapshot validation
  def query(%__MODULE__{} = store, operation, arguments)
      when operation in @operations and is_map(arguments),
      do: call(store, {:query, operation, arguments})

  def query(_store, _operation, _arguments), do: {:error, :invalid_query}

  @spec conversation(t(), binary()) :: {:ok, map()} | {:error, atom()}
  def conversation(%__MODULE__{} = store, run_id) when is_binary(run_id),
    do: call(store, {:conversation, run_id})

  def conversation(_store, _run_id), do: {:error, :invalid_inspection_query}

  @spec preludes(t(), binary()) :: {:ok, map()} | {:error, atom()}
  def preludes(%__MODULE__{} = store, run_id) when is_binary(run_id),
    do: call(store, {:preludes, run_id})

  def preludes(_store, _run_id), do: {:error, :invalid_inspection_query}

  @spec refresh(t(), binary()) :: :ok | {:error, atom()}
  def refresh(%__MODULE__{} = store, run_id)
      when is_binary(run_id) and byte_size(run_id) in 1..256,
      do: call(store, {:refresh, run_id})

  def refresh(_store, _run_id), do: {:error, :invalid_query}

  @spec inspection?(t()) :: boolean()
  def inspection?(%__MODULE__{} = store) do
    case call(store, :inspection?) do
      value when is_boolean(value) -> value
      _error -> false
    end
  end

  def inspection?(_store), do: false

  @spec transfer_owner(t(), pid()) :: :ok | {:error, atom()}
  def transfer_owner(%__MODULE__{} = store, owner) when is_pid(owner),
    do: call(store, {:transfer_owner, owner})

  def transfer_owner(_store, _owner), do: {:error, :invalid_snapshot_store}

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = store) do
    case call(store, :stop) do
      :ok -> :ok
      _error -> :ok
    end
  end

  def stop(_store), do: :ok

  @impl GenServer
  def init({trace_source, capture_inspection, owner, token}) do
    owner_ref = Process.monitor(owner)

    case capture(trace_source, capture_inspection) do
      {:ok, trace, inspection} ->
        {:ok,
         %{
           capture_inspection: capture_inspection,
           inspection: inspection,
           owner_ref: owner_ref,
           token: token,
           trace: trace,
           trace_source: trace_source
         }}

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({token, {:query, operation, arguments}}, _from, %{token: token} = state) do
    {:reply, TraceSnapshot.query(state.trace, operation, arguments), state}
  end

  def handle_call({token, {:conversation, run_id}}, _from, %{token: token} = state) do
    {:reply, inspect_snapshot(state.inspection, :conversation, run_id), state}
  end

  def handle_call({token, {:preludes, run_id}}, _from, %{token: token} = state) do
    {:reply, inspect_snapshot(state.inspection, :preludes, run_id), state}
  end

  def handle_call({token, {:refresh, run_id}}, _from, %{token: token} = state) do
    case capture(state.trace_source, state.capture_inspection) do
      {:ok, trace, inspection} ->
        case TraceSnapshot.run_exists?(trace, run_id) do
          {:ok, true} ->
            cleanup(state.trace, state.inspection)
            {:reply, :ok, %{state | trace: trace, inspection: inspection}}

          {:ok, false} ->
            cleanup(trace, inspection)
            {:reply, {:error, :not_found}, state}

          {:error, reason} ->
            cleanup(trace, inspection)
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, normalize_error(reason)}, state}
    end
  end

  def handle_call({token, :inspection?}, _from, %{token: token} = state),
    do: {:reply, not is_nil(state.inspection), state}

  def handle_call({token, {:transfer_owner, owner}}, _from, %{token: token} = state) do
    if Process.alive?(owner) do
      Process.demonitor(state.owner_ref, [:flush])
      {:reply, :ok, %{state | owner_ref: Process.monitor(owner)}}
    else
      {:reply, {:error, :snapshot_unavailable}, state}
    end
  end

  def handle_call({token, :stop}, _from, %{token: token} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :invalid_snapshot_store}, state}

  @impl GenServer
  # ex_dna:disable-for-next-line -- owner-monitor shutdown is the common resource-owner contract
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cleanup(state.trace, state.inspection)
    :ok
  end

  defp capture(trace_source, capture_inspection) do
    deadline = System.monotonic_time(:millisecond) + @capture_timeout_ms

    with {:ok, trace} <-
           TraceSnapshot.start(trace_source, owner: self(), capture_deadline_ms: deadline) do
      case invoke_inspection(capture_inspection, trace, deadline) do
        {:ok, inspection} ->
          {:ok, trace, inspection}

        {:error, reason} ->
          TraceSnapshot.stop(trace)
          {:error, reason}
      end
    end
  end

  defp invoke_inspection(callback, trace, deadline) do
    case callback.(trace, deadline) do
      {:ok, %InspectionSnapshot{} = inspection} -> {:ok, inspection}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :snapshot_unavailable}
    end
  rescue
    _exception -> {:error, :snapshot_unavailable}
  catch
    _kind, _reason -> {:error, :snapshot_unavailable}
  end

  defp inspect_snapshot(nil, _operation, _run_id), do: {:error, :unavailable}

  defp inspect_snapshot(snapshot, :conversation, run_id),
    do: ProjectViewerAdapter.conversation({:inspection_snapshot, snapshot}, run_id)

  defp inspect_snapshot(snapshot, :preludes, run_id),
    do: ProjectViewerAdapter.preludes({:inspection_snapshot, snapshot}, run_id)

  defp cleanup(trace, inspection) do
    InspectionSnapshot.stop(inspection)
    TraceSnapshot.stop(trace)
  end

  defp normalize_error(reason) when is_atom(reason), do: reason
  defp normalize_error(_reason), do: :snapshot_unavailable

  defp call(%__MODULE__{pid: pid, token: token}, request) do
    GenServer.call(pid, {token, request}, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :snapshot_unavailable}
  end
end
