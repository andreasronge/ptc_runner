defmodule PtcRunner.Research.SealedEvidenceLog.Snapshot do
  @moduledoc """
  Owner process for admitted ETS indexes and pinned sealed-log readers.

  The owner creates the tables with itself as heir. Admission inserts through a
  bounded worker that is cancelled with the original caller; after admission
  returns, the owner is the sole mutator of retained state. Owner death deletes
  every table and closes every handle. Query workers cancel with the caller;
  the snapshot stays usable.
  """

  use GenServer

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Research.SealedEvidenceLog.Admission
  alias PtcRunner.Research.SealedEvidenceLog.Handle
  alias PtcRunner.Research.SealedEvidenceLog.Indexes
  alias PtcRunner.Research.SealedEvidenceLog.Limits
  alias PtcRunner.Research.SealedEvidenceLog.Query

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start([map()], map(), keyword()) :: {:ok, t()} | {:error, atom()}
  def start(artifacts, limits, opts \\ [])
      when is_list(artifacts) and is_map(limits) and is_list(opts) do
    owner = Keyword.get(opts, :owner, self())
    token = make_ref()

    case GenServer.start(__MODULE__, {artifacts, limits, owner, token, opts}) do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec query(t(), atom(), map(), keyword()) ::
          {:ok, map(), Query.metrics()} | {:error, atom()}
  def query(snapshot, operation, arguments, opts \\ [])

  def query(%__MODULE__{} = snapshot, operation, arguments, opts)
      when is_atom(operation) and is_map(arguments) and is_list(opts) do
    call(snapshot, {:query, snapshot.token, operation, arguments, opts})
  end

  def query(_snapshot, _operation, _arguments, _opts), do: {:error, :invalid_query}

  @spec info(t()) :: {:ok, map()} | {:error, atom()}
  def info(%__MODULE__{} = snapshot), do: call(snapshot, {:info, snapshot.token})
  def info(_snapshot), do: {:error, :invalid_snapshot}

  @spec close(term()) :: :ok
  def close(%__MODULE__{} = snapshot) do
    case call(snapshot, {:stop, snapshot.token}) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  def close(_snapshot), do: :ok

  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{pid: pid}), do: Process.alive?(pid)

  @spec table_ids(t()) :: [reference()] | {:error, atom()}
  def table_ids(%__MODULE__{} = snapshot), do: call(snapshot, {:table_ids, snapshot.token})

  @spec handles(t()) :: {:ok, [Handle.t()]} | {:error, atom()}
  def handles(%__MODULE__{} = snapshot), do: call(snapshot, {:handles, snapshot.token})

  @impl GenServer
  def init({artifacts, limits, owner, token, opts}) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)
    indexes = Indexes.create(self())
    opts = opts |> Keyword.put_new(:cancel_with, owner) |> Keyword.put_new(:owner, owner)

    case admit_all(artifacts, indexes, limits, opts) do
      {:ok, state} ->
        indexes = Indexes.put_owner_metadata(state.indexes, %{token: token})

        started = %{
          token: token,
          owner_ref: owner_ref,
          limits: limits,
          indexes: indexes,
          query_hook: Keyword.get(opts, :query_hook)
        }

        state = Map.merge(state, started)

        if Indexes.within_retained?(indexes, limits) do
          {:ok, state}
        else
          cleanup_owned(state)
          {:stop, :max_retained_bytes}
        end

      {:error, reason} ->
        Indexes.delete_all(indexes)
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:query, token, operation, arguments, opts}, {caller, _ref} = from, state) do
    if token == state.token do
      run_query(state, operation, arguments, caller, from, opts)
    else
      {:reply, {:error, :invalid_snapshot}, state}
    end
  end

  def handle_call({:info, token}, _from, state) do
    if token == state.token do
      accounting = Indexes.accounting(state.indexes)

      {:reply,
       {:ok,
        %{
          snapshot_digest: state.snapshot_digest,
          run_count: map_size(state.handles),
          accounting: accounting,
          record_count: state.record_count,
          checkpoints: state.checkpoints,
          diagnostic_peaks: state.peaks,
          handle_count: map_size(state.handles)
        }}, state}
    else
      {:reply, {:error, :invalid_snapshot}, state}
    end
  end

  def handle_call({:table_ids, token}, _from, state) do
    if token == state.token,
      do: {:reply, Indexes.table_ids(state.indexes), state},
      else: {:reply, {:error, :invalid_snapshot}, state}
  end

  def handle_call({:handles, token}, _from, state) do
    if token == state.token,
      do: {:reply, {:ok, Map.values(state.handles)}, state},
      else: {:reply, {:error, :invalid_snapshot}, state}
  end

  def handle_call({:stop, token}, _from, state) do
    if token == state.token,
      do: {:stop, :normal, :ok, state},
      else: {:reply, {:error, :invalid_snapshot}, state}
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :invalid_query}, state}

  @impl GenServer
  # ex_dna:disable-for-next-line — GenServer callback, intentionally per-module
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cleanup_owned(state)
    :ok
  end

  @impl GenServer
  def format_status(status), do: redact_status(status)

  defp admit_all(artifacts, indexes, limits, opts) do
    Enum.reduce_while(artifacts, {:ok, empty_state(indexes)}, fn artifact, {:ok, acc} ->
      case admit_one(artifact, acc.indexes, limits, opts) do
        {:ok, admitted} ->
          handles = Map.put(acc.handles, admitted.run_id, admitted.handle)

          {:cont,
           {:ok,
            %{
              acc
              | indexes: admitted.indexes,
                handles: handles,
                trace_facts: Map.put(acc.trace_facts, admitted.run_id, artifact.trace_facts),
                turn_evidence:
                  Map.put(acc.turn_evidence, admitted.run_id, admitted.turn_evidence),
                record_count: acc.record_count + admitted.record_count,
                checkpoints: acc.checkpoints ++ admitted.checkpoints.checkpoints,
                peaks: merge_peaks(acc.peaks, admitted.checkpoints.diagnostic_peaks),
                digests: Map.put(acc.digests, admitted.run_id, admitted.handle.digest)
            }}}

        {:error, reason} ->
          acc.handles |> Map.values() |> Enum.each(&Handle.close/1)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, state} ->
        indexes =
          state.indexes
          |> Indexes.put_trace_facts(state.trace_facts)
          |> Indexes.put_turn_evidence(state.turn_evidence)

        {:ok,
         %{
           state
           | snapshot_digest: snapshot_digest(state, opts),
             trace_snapshot_hash: Keyword.get(opts, :trace_snapshot_hash, "trace-source"),
             indexes: indexes
         }}

      error ->
        error
    end
  end

  defp admit_one(artifact, indexes, limits, opts) do
    path = artifact.path
    trace_facts = artifact.trace_facts

    case Handle.open(path) do
      {:ok, handle} ->
        case Admission.run(handle, indexes, trace_facts, limits, opts) do
          {:ok, admitted} ->
            {:ok,
             %{
               handle: handle,
               indexes: admitted.indexes,
               run_id: admitted.run_id,
               record_count: admitted.record_count,
               checkpoints: admitted.checkpoints,
               turn_evidence: turn_evidence(admitted)
             }}

          {:error, reason} ->
            Handle.close(handle)
            {:error, reason}
        end

      error ->
        error
    end
  end

  defp run_query(state, operation, arguments, caller, from, opts) do
    snapshot = query_state(state)
    max_bytes = installed_result_bytes(state.limits, opts)
    metadata = %{"snapshot_hash" => snapshot_hash(state.snapshot_digest)}
    limits = state.limits

    {:noreply, state,
     {:continue,
      {:dispatch_query, operation, arguments, caller, from, snapshot, max_bytes, metadata, limits}}}
  end

  @impl GenServer
  def handle_continue(
        {:dispatch_query, operation, arguments, caller, from, snapshot, max_bytes, metadata,
         limits},
        state
      ) do
    result =
      BoundedWorker.run(
        fn -> Query.run(snapshot, operation, arguments, max_bytes, metadata) end,
        timeout_ms: limits.query_deadline_ms,
        max_heap_words: Limits.heap_words(limits.query_heap_bytes),
        cancel_with: caller
      )

    GenServer.reply(from, wrap_query(result))
    {:noreply, state}
  end

  defp wrap_query({:ok, {:ok, page, metrics}}), do: {:ok, page, metrics}
  defp wrap_query({:ok, {:error, reason}}) when is_atom(reason), do: {:error, reason}
  defp wrap_query({:error, :timeout}), do: {:error, :deadline_exceeded}
  defp wrap_query({:error, :cancelled}), do: {:error, :cancelled}
  defp wrap_query({:error, :heap_exceeded}), do: {:error, :heap_exceeded}
  defp wrap_query({:error, :worker_failed}), do: {:error, :query_failed}
  defp wrap_query(_other), do: {:error, :query_failed}

  defp query_state(state) do
    %{
      indexes: state.indexes,
      handles: state.handles,
      snapshot_digest: state.snapshot_digest,
      trace_facts: state.trace_facts,
      trace_snapshot_hash: state.trace_snapshot_hash,
      turn_evidence: state.turn_evidence,
      limits: state.limits,
      query_hook: Map.get(state, :query_hook)
    }
  end

  defp empty_state(indexes) do
    %{
      indexes: indexes,
      handles: %{},
      trace_facts: %{},
      turn_evidence: %{},
      record_count: 0,
      checkpoints: [],
      peaks: %{},
      digests: %{},
      snapshot_digest: "",
      trace_snapshot_hash: "trace-source"
    }
  end

  defp snapshot_digest(state, opts) do
    capture =
      opts
      |> Keyword.get(:trace_capture_sha256, :crypto.hash(:sha256, "prototype-trace"))
      |> capture_bytes()

    pairs =
      state.digests
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {run_id, digest} ->
        [<<byte_size(run_id)::unsigned-big-64>>, run_id, digest]
      end)

    :crypto.hash(
      :sha256,
      [
        "ptc-inspection-snapshot-v1\0",
        capture,
        <<map_size(state.digests)::unsigned-big-64>>,
        pairs
      ]
    )
    |> Base.url_encode64(padding: false)
  end

  defp capture_bytes(value) when is_binary(value) and byte_size(value) == 32, do: value
  defp capture_bytes(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  defp merge_peaks(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _name, current, incoming ->
      if incoming.aggregate_memory_bytes > current.aggregate_memory_bytes,
        do: incoming,
        else: current
    end)
  end

  defp snapshot_hash(digest) when is_binary(digest) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, digest), case: :lower)
  end

  defp turn_evidence(admitted), do: admitted.turn_evidence

  defp installed_result_bytes(limits, opts) do
    requested = Keyword.get(opts, :max_result_bytes, limits.max_result_bytes)

    if is_integer(requested) and requested > 0,
      do: min(requested, limits.max_result_bytes),
      else: limits.max_result_bytes
  end

  defp cleanup_owned(state) do
    if Map.has_key?(state, :indexes), do: Indexes.delete_all(state.indexes)
    state |> Map.get(:handles, %{}) |> Map.values() |> Enum.each(&Handle.close/1)
    :ok
  end

  defp call(%__MODULE__{pid: pid}, message) do
    GenServer.call(pid, message, 30_000)
  catch
    :exit, _reason -> {:error, :invalid_snapshot}
  end

  # The token is stored on the handle; calls go to the pid. The struct token is
  # checked by the public functions that pattern-match `%__MODULE__{}`.
  defp redact_status(status) when is_map(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp redact_status(status), do: status
end
