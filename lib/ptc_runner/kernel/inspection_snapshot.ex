defmodule PtcRunner.Kernel.InspectionSnapshot do
  @moduledoc """
  Owner-bound admitted view of sealed private inspection evidence.

  Admission pins each selected `.ptcins` file, validates every frame and its
  paired trace semantics, confirms the complete evidence seal, and publishes
  a capability only after bounded ETS indexes are complete. The owner retains
  one reader handle per admitted artifact plus derived metadata; evidence
  payload bytes stay on disk and are read lazily for returned query items.
  """

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionArtifact.Admission
  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.InspectionArtifact.Handle
  alias PtcRunner.Kernel.InspectionArtifact.Indexes
  alias PtcRunner.Kernel.InspectionArtifact.Limits
  alias PtcRunner.Kernel.InspectionQuery
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.SelectedCanonicalSource
  alias PtcRunner.Kernel.TraceSnapshot

  @default_result_bytes 1_000_000
  @max_source_bytes 536_871_120
  @max_retained_bytes 134_217_728
  @default_directory_entries 4_096
  @default_files 1_024
  @listing_timeout_ms 5_000
  @listing_heap_words 1_000_000
  @operations InspectionQuery.operations()

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(term(), TraceSnapshot.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(source, trace_snapshot, opts \\ [])

  def start({:directory, directory}, trace_snapshot, opts)
      when is_binary(directory) and is_list(opts),
      do: start_with_valid_trace({:directory, Path.expand(directory)}, trace_snapshot, opts)

  def start({:file, path, run_ref}, trace_snapshot, opts)
      when is_binary(path) and is_binary(run_ref) and is_list(opts),
      do: start_with_valid_trace({:file, Path.expand(path), run_ref}, trace_snapshot, opts)

  @doc false
  def start({:viewer_file, path, run_ref}, trace_snapshot, opts)
      when is_binary(path) and is_binary(run_ref) and is_list(opts),
      do: start_with_valid_trace({:viewer_file, Path.expand(path), run_ref}, trace_snapshot, opts)

  def start({:selected_canonical, directory, run_ref}, trace_snapshot, opts)
      when is_binary(directory) and is_binary(run_ref) and is_list(opts) do
    with true <- TraceSnapshot.valid?(trace_snapshot),
         {:ok, path} <- SelectedCanonicalSource.resolve_inspection(directory, run_ref) do
      start({:file, path, run_ref}, trace_snapshot, opts)
    else
      false -> {:error, :invalid_snapshot}
      {:error, _reason} = error -> error
    end
  end

  def start({:selected_canonical_set, directory, run_refs}, trace_snapshot, opts)
      when is_binary(directory) and is_list(run_refs) and is_list(opts) do
    with true <- TraceSnapshot.valid?(trace_snapshot),
         {:ok, selected} <- SelectedCanonicalSource.resolve_inspections(directory, run_refs) do
      start_with_valid_trace(
        {:selected_set, Path.expand(directory), selected},
        trace_snapshot,
        opts
      )
    else
      false -> {:error, :invalid_snapshot}
      {:error, _reason} = error -> error
    end
  end

  def start(_source, _trace_snapshot, _opts), do: {:error, :invalid_snapshot}

  defp start_with_valid_trace(source, trace_snapshot, opts) do
    if TraceSnapshot.valid?(trace_snapshot),
      do: start_capture(source, trace_snapshot, opts),
      else: {:error, :invalid_snapshot}
  end

  defp start_capture(source, trace_snapshot, opts) do
    allowed = [
      :owner,
      :resource_registrar,
      :max_source_bytes,
      :max_retained_bytes,
      :max_result_bytes,
      :max_directory_entries,
      :max_files,
      :capture_deadline_ms,
      :capture_hook,
      :open_hook,
      :listing_hook,
      :artifact_verification_hook,
      :admission_hook,
      :query_hook,
      :limits
    ]

    with true <- Keyword.keys(opts) -- allowed == [],
         owner when is_pid(owner) <- Keyword.get(opts, :owner, self()),
         max_source_bytes when max_source_bytes in 1..@max_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @max_source_bytes),
         max_retained_bytes when max_retained_bytes in 1..@max_retained_bytes <-
           Keyword.get(opts, :max_retained_bytes, @max_retained_bytes),
         max_result_bytes when max_result_bytes in 1..1_048_576 <-
           Keyword.get(opts, :max_result_bytes, @default_result_bytes),
         max_directory_entries when max_directory_entries in 1..@default_directory_entries <-
           Keyword.get(opts, :max_directory_entries, @default_directory_entries),
         max_files when max_files in 1..@default_files <-
           Keyword.get(opts, :max_files, @default_files),
         {:ok, limits} <- Limits.merge(Keyword.get(opts, :limits, [])),
         limits <- %{
           limits
           | max_retained_bytes: min(limits.max_retained_bytes, max_retained_bytes)
         },
         token <- make_ref(),
         {:ok, pid} <-
           GenServer.start(
             __MODULE__,
             {source, trace_snapshot, owner, token, limits,
              %{
                max_source_bytes: max_source_bytes,
                max_result_bytes: max_result_bytes,
                max_directory_entries: max_directory_entries,
                max_files: max_files,
                resource_registrar: Keyword.get(opts, :resource_registrar),
                deadline_ms: deadline(opts, limits),
                capture_hook: Keyword.get(opts, :capture_hook),
                open_hook: Keyword.get(opts, :open_hook),
                listing_hook: Keyword.get(opts, :listing_hook),
                admission_hook:
                  Keyword.get(opts, :admission_hook) ||
                    Keyword.get(opts, :artifact_verification_hook),
                query_hook: Keyword.get(opts, :query_hook)
              }}
           ) do
      {:ok, %__MODULE__{pid: pid, token: token}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, {:source_retained_limit_exceeded, _details} = reason} -> {:error, reason}
      {:error, _reason} -> {:error, :source_unavailable}
      _invalid -> {:error, :invalid_snapshot}
    end
  end

  @spec query(t(), InspectionQuery.operation(), map()) :: {:ok, map()} | {:error, atom()}
  def query(%__MODULE__{} = snapshot, operation, arguments)
      when operation in @operations and is_map(arguments),
      do: call(snapshot, {:query, operation, arguments})

  def query(_snapshot, _operation, _arguments), do: {:error, :invalid_query}

  @spec info(t()) :: {:ok, map()} | {:error, atom()}
  def info(%__MODULE__{} = snapshot), do: call(snapshot, :info)
  def info(_snapshot), do: {:error, :invalid_snapshot}

  @doc false
  @spec result_limit(t()) :: {:ok, pos_integer()} | {:error, atom()}
  def result_limit(%__MODULE__{} = snapshot), do: call(snapshot, :result_limit)
  def result_limit(_snapshot), do: {:error, :invalid_snapshot}

  @doc false
  @spec transfer_owner(t(), pid()) :: :ok | {:error, atom()}
  def transfer_owner(%__MODULE__{} = snapshot, owner) when is_pid(owner),
    do: call(snapshot, {:transfer_owner, owner})

  def transfer_owner(_snapshot, _owner), do: {:error, :invalid_snapshot}

  @spec stop(term()) :: :ok
  def stop(%__MODULE__{} = snapshot) do
    case call(snapshot, :stop) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  def stop(_snapshot), do: :ok

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{pid: pid, token: token}), do: is_pid(pid) and is_reference(token)
  def valid?(_snapshot), do: false

  @doc false
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{pid: pid}), do: Process.alive?(pid)

  @impl GenServer
  def init({source, trace_snapshot, owner, token, limits, config}) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)
    trace_ref = Process.monitor(trace_snapshot.pid)

    with :ok <- ResourceRegistrar.register_root(config.resource_registrar),
         {:ok, trace_info} <- TraceSnapshot.info(trace_snapshot),
         {:ok, inventory} <- inventory(source, config),
         true <- inventory.source_bytes <= config.max_source_bytes,
         :ok <- validate_selected_versions(inventory.files, source),
         :ok <- capture_hook(config.open_hook),
         {:ok, admitted} <-
           open_and_admit(inventory.files, source, trace_snapshot, limits, config, owner) do
      finalize_admitted(
        admitted,
        source,
        inventory,
        %{
          trace_info: trace_info,
          token: token,
          owner_ref: owner_ref,
          trace_ref: trace_ref,
          limits: limits,
          config: config
        }
      )
    else
      false -> {:stop, :source_limit_exceeded}
      {:error, reason} -> {:stop, normalize_error(reason)}
    end
  end

  @impl GenServer
  def handle_call({token, :info}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.info}, state}

  def handle_call({token, :result_limit}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.max_result_bytes}, state}

  def handle_call(
        {token, {:query, operation, arguments}},
        {caller, _tag},
        %{token: token} = state
      ) do
    snapshot =
      Map.take(state, [
        :indexes,
        :handles,
        :snapshot_digest,
        :trace_snapshot_hash,
        :limits,
        :query_hook
      ])

    metadata = %{"snapshot_hash" => state.info.snapshot_hash}

    result =
      BoundedWorker.run(
        fn ->
          InspectionQuery.run(snapshot, operation, arguments, state.max_result_bytes, metadata)
        end,
        timeout_ms: state.limits.query_deadline_ms,
        max_heap_words: Limits.heap_words(state.limits.query_heap_bytes),
        cancel_with: caller
      )
      |> query_result()

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

  def handle_call(_request, _from, state), do: {:reply, {:error, :invalid_snapshot}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{trace_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cleanup_owned(
      Map.get(state, :indexes),
      Map.get(state, :handles, %{}),
      get_in(state, [:limits, :cleanup_deadline_ms]) || 5_000
    )

    :ok
  end

  defp inventory({:file, path, _run_ref}, _config) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size} = stat} ->
        {:ok, %{files: [{path, stat}], source_bytes: size}}

      {:ok, %File.Stat{}} ->
        {:error, :selected_inspection_not_regular}

      {:error, :enoent} ->
        {:error, :selected_inspection_missing}

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp inventory({:viewer_file, path, run_ref}, config),
    do: inventory({:file, path, run_ref}, config)

  defp inventory({:selected_set, _directory, selected}, config) do
    if length(selected) <= config.max_files do
      Enum.reduce_while(selected, {:ok, [], 0}, fn %{path: path}, {:ok, files, bytes} ->
        case File.lstat(path, time: :posix) do
          {:ok, %File.Stat{type: :regular, size: size} = stat} ->
            {:cont, {:ok, [{path, stat} | files], bytes + size}}

          {:ok, %File.Stat{}} ->
            {:halt, {:error, :selected_inspection_not_regular}}

          {:error, :enoent} ->
            {:halt, {:error, :selected_inspection_missing}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, files, bytes} -> {:ok, %{files: Enum.reverse(files), source_bytes: bytes}}
        {:error, _reason} = error -> error
      end
    else
      {:error, :source_limit_exceeded}
    end
  end

  defp inventory({:directory, directory}, config) do
    case BoundedWorker.run(
           fn -> inventory_directory(directory, config) end,
           timeout_ms: @listing_timeout_ms,
           max_heap_words: @listing_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, result} -> result
      {:error, :heap_exceeded} -> {:error, :source_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp inventory_directory(directory, config) do
    if is_function(config.listing_hook, 0), do: config.listing_hook.()

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:ok, names} <- File.ls(directory),
         true <- length(names) <= config.max_directory_entries,
         names <- Enum.filter(names, &String.ends_with?(&1, InspectionArtifact.suffix())),
         true <- length(names) <= config.max_files do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, [], 0}, fn name, {:ok, files, bytes} ->
        path = Path.join(directory, name)

        case File.lstat(path, time: :posix) do
          {:ok, %File.Stat{type: :regular, size: size} = stat} ->
            {:cont, {:ok, [{path, stat} | files], bytes + size}}

          _other ->
            {:halt, {:error, :malformed_source}}
        end
      end)
      |> case do
        {:ok, files, bytes} -> {:ok, %{files: Enum.reverse(files), source_bytes: bytes}}
        error -> error
      end
    else
      false -> {:error, :source_limit_exceeded}
      _other -> {:error, :source_unavailable}
    end
  end

  defp admit_all(opened, source, trace_snapshot, indexes, limits, config) do
    result =
      Enum.reduce_while(opened, {:ok, empty_admission(indexes)}, fn {path, handle}, {:ok, acc} ->
        opts = [
          during_admission_hook: config.admission_hook,
          expected_identity: inspection_identity(handle, source, trace_snapshot, path)
        ]

        case opts[:expected_identity] do
          {:isolated, identity} ->
            opts = Keyword.put(opts, :expected_identity, identity)
            admit_isolated(handle, acc, source, limits, opts)

          {:error, reason} ->
            {:halt, {:error, reason, admission_handles(acc)}}

          {:ok, identity} ->
            opts = Keyword.put(opts, :expected_identity, identity)
            facts = fn run_id, trace_id -> paired_facts(trace_snapshot, run_id, trace_id) end
            admit_one(handle, acc, source, path, facts, limits, opts)
        end
      end)

    case result do
      {:ok, admitted} ->
        {:ok, retain_admission_metadata(admitted)}

      {:error, reason, handles} ->
        cleanup_failed(indexes, handles)
        {:error, reason}
    end
  end

  defp admit_one(handle, acc, source, path, facts, limits, opts) do
    case Admission.run(handle, acc.indexes, facts, limits, opts) do
      {:ok, admitted} ->
        case add_admitted(acc, admitted, handle, source, path) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason, admission_handles(acc)}}
        end

      {:error, reason} ->
        {:halt, {:error, reason, admission_handles(acc)}}
    end
  end

  defp admit_isolated(handle, acc, {:directory, _directory}, limits, opts) do
    isolated_indexes = Indexes.create(self())
    isolated_facts = fn _run_id, _trace_id -> {:error, :run_isolated} end

    result = Admission.run(handle, isolated_indexes, isolated_facts, limits, opts)
    Indexes.delete_all(isolated_indexes)

    case result do
      {:isolated, isolated} ->
        case add_isolated(acc, isolated, handle) do
          {:ok, next} ->
            {:cont, {:ok, next}}

          {:error, reason} ->
            {:halt, {:error, reason, admission_handles(acc)}}
        end

      {:error, reason} ->
        {:halt, {:error, reason, admission_handles(acc)}}
    end
  end

  defp admit_isolated(_handle, acc, _source, _limits, _opts),
    do: {:halt, {:error, :inspection_correlation_missing, admission_handles(acc)}}

  defp open_and_admit(files, source, trace_snapshot, limits, config, owner) do
    with {:ok, opened} <- open_all(files) do
      result =
        with :ok <- validate_selected_claims(opened, source) do
          admit_bounded(opened, source, trace_snapshot, limits, config, owner)
        end

      case result do
        {:ok, admitted} ->
          {:ok, admitted}

        {:error, reason} ->
          Enum.each(opened, fn {_path, handle} -> Handle.close(handle) end)
          {:error, reason}
      end
    end
  end

  defp open_all(files) do
    Enum.reduce_while(files, {:ok, []}, fn {path, expected}, {:ok, opened} ->
      case Handle.open(path, expected) do
        {:ok, handle} ->
          {:cont, {:ok, [{path, handle} | opened]}}

        {:error, reason} ->
          Enum.each(opened, fn {_path, handle} -> Handle.close(handle) end)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, opened} -> {:ok, Enum.reverse(opened)}
      error -> error
    end
  end

  defp admit_bounded(opened, source, trace_snapshot, limits, config, owner) do
    snapshot_owner = self()

    BoundedWorker.run(
      fn ->
        indexes = Indexes.create(snapshot_owner)

        case admit_all(opened, source, trace_snapshot, indexes, limits, config) do
          {:ok, admitted} ->
            accounting = Indexes.accounting(admitted.indexes)

            if accounting.charged_retained_bytes <= limits.max_retained_bytes do
              {:ok, admitted}
            else
              cleanup_failed(admitted.indexes, admission_handles(admitted))

              {:error,
               {:source_retained_limit_exceeded,
                %{
                  source: :ptc_inspection_snapshot,
                  measured_bytes: accounting.charged_retained_bytes,
                  limit_bytes: limits.max_retained_bytes
                }}}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end,
      timeout_ms: remaining(config.deadline_ms),
      max_heap_words: Limits.heap_words(limits.admission_heap_bytes),
      cancel_with: owner
    )
    |> admission_result()
  end

  defp admission_result({:ok, result}), do: result
  defp admission_result({:error, :timeout}), do: {:error, :deadline_exceeded}
  defp admission_result({:error, :cancelled}), do: {:error, :cancelled}
  defp admission_result({:error, :heap_exceeded}), do: {:error, :heap_exceeded}
  defp admission_result({:error, _reason}), do: {:error, :source_unavailable}

  defp verify_all_handles(handles) do
    Enum.reduce_while(handles, :ok, fn {_run_id, handle}, :ok ->
      case Handle.assert_stable(handle) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp retain_admission_metadata(admitted) do
    indexes =
      admitted.indexes
      |> Indexes.put_trace_facts(admitted.trace_facts)
      |> Indexes.put_turn_evidence(admitted.turn_evidence)
      |> Indexes.put_owner_metadata(%{
        run_ids: admitted.handles |> Map.keys() |> Enum.sort(),
        digests: admitted.digests
      })

    admitted
    |> Map.put(:indexes, indexes)
    |> Map.drop([:trace_facts, :turn_evidence])
  end

  defp empty_admission(indexes) do
    %{
      indexes: indexes,
      handles: %{},
      isolated_handles: %{},
      trace_facts: %{},
      turn_evidence: %{},
      digests: %{}
    }
  end

  defp add_isolated(acc, isolated, handle) do
    run_id = isolated.run_id

    if Map.has_key?(acc.digests, run_id) do
      {:error, :duplicate_inspection_run}
    else
      {:ok,
       %{
         acc
         | isolated_handles: Map.put(acc.isolated_handles, run_id, handle),
           digests: Map.put(acc.digests, run_id, handle.digest)
       }}
    end
  end

  defp add_admitted(acc, admitted, handle, source, path) do
    run_id = admitted.run_id
    requested = requested_run(source, path)

    cond do
      Map.has_key?(acc.digests, run_id) ->
        {:error, :duplicate_inspection_run}

      is_binary(requested) and requested != run_id ->
        {:error, :selected_run_mismatch}

      true ->
        {:ok,
         %{
           acc
           | indexes: admitted.indexes,
             handles: Map.put(acc.handles, run_id, handle),
             trace_facts: Map.put(acc.trace_facts, run_id, admitted.trace_facts),
             turn_evidence: Map.put(acc.turn_evidence, run_id, admitted.turn_evidence),
             digests: Map.put(acc.digests, run_id, handle.digest)
         }}
    end
  end

  defp paired_facts(trace_snapshot, run_id, trace_id) do
    with {:ok, facts} <- TraceSnapshot.analysis_facts(trace_snapshot, [run_id]),
         %{"trace_id" => ^trace_id} = run_facts <- get_in(facts, ["runs", run_id]) do
      {:ok, run_facts}
    else
      _missing -> {:error, :inspection_correlation_missing}
    end
  end

  defp inspection_identity(%{footer: footer}, {:directory, _directory}, trace_snapshot, _path) do
    TraceSnapshot.resolve_directory_inspection_identity(
      trace_snapshot,
      footer.run_id_sha256,
      footer.trace_id_sha256
    )
  end

  defp inspection_identity(%{footer: footer}, _source, trace_snapshot, _path) do
    TraceSnapshot.resolve_inspection_identity(
      trace_snapshot,
      footer.run_id_sha256,
      footer.trace_id_sha256
    )
  end

  defp selected_source_id({:file, _path, run_ref}, digest, admitted) do
    case Map.fetch(admitted.indexes.trace_facts, run_ref) do
      {:ok, %{"trace_id" => trace_id}} ->
        {:ok, SelectedCanonicalSource.inspection_source_id(run_ref, digest, trace_id)}

      _missing ->
        {:error, :inspection_correlation_missing}
    end
  end

  defp selected_source_id({:selected_set, _directory, selected}, digest, admitted) do
    Enum.reduce_while(selected, {:ok, []}, fn %{run_ref: run_ref}, {:ok, commitments} ->
      with {:ok, evidence_digest} <- Map.fetch(admitted.digests, run_ref),
           {:ok, %{"trace_id" => trace_id}} <-
             Map.fetch(admitted.indexes.trace_facts, run_ref) do
        commitment = %{
          run_ref: run_ref,
          evidence_digest: evidence_digest,
          trace_id: trace_id
        }

        {:cont, {:ok, [commitment | commitments]}}
      else
        _missing -> {:halt, {:error, :inspection_correlation_missing}}
      end
    end)
    |> case do
      {:ok, commitments} ->
        {:ok, SelectedCanonicalSource.inspection_set_source_id(digest, Enum.reverse(commitments))}

      {:error, _reason} = error ->
        error
    end
  end

  defp selected_source_id(_source, digest, _admitted), do: {:ok, digest}

  defp finalize_admitted(admitted, source, inventory, context) do
    %{trace_info: trace_info, limits: limits, config: config} = context

    result =
      with :ok <- capture_hook(config.capture_hook),
           :ok <- verify_all_handles(admission_handles(admitted)),
           :ok <- verify_selected_source(source, inventory.files),
           :ok <- close_isolated_handles(admitted),
           true <- Indexes.within_retained?(admitted.indexes, limits),
           digest = snapshot_digest(trace_info.snapshot_hash, admitted.digests),
           {:ok, source_id} <- selected_source_id(source, digest, admitted) do
        {:ok,
         %{
           token: context.token,
           owner_ref: context.owner_ref,
           trace_ref: context.trace_ref,
           limits: limits,
           indexes: admitted.indexes,
           handles: admitted.handles,
           snapshot_digest: source_id,
           trace_snapshot_hash: trace_info.snapshot_hash,
           max_result_bytes: config.max_result_bytes,
           query_hook: config.query_hook,
           info: %{
             capture_id: source_id,
             captured_at: DateTime.utc_now(),
             file_count: length(inventory.files),
             run_count: map_size(admitted.handles),
             snapshot_hash: SafeMetadata.fingerprint(source_id),
             source_bytes: inventory.source_bytes,
             retained_bytes: Indexes.accounting(admitted.indexes).charged_retained_bytes,
             trace_capture_id: trace_info.capture_id
           }
         }}
      else
        false -> {:error, :max_retained_bytes}
        {:error, _reason} = error -> error
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        cleanup_failed(admitted.indexes, admission_handles(admitted))
        {:stop, normalize_error(reason)}
    end
  end

  defp validate_selected_claims(opened, {:selected_set, _directory, _selected} = source) do
    requests = selected_requests(source)
    claims = Enum.map(opened, fn {_path, handle} -> handle.footer.run_id_sha256 end)

    cond do
      length(claims) != MapSet.size(MapSet.new(claims)) ->
        {:error, :duplicate_inspection_run}

      Enum.any?(opened, fn {path, handle} ->
        case Map.fetch(requests, path) do
          {:ok, run_ref} -> Format.identity_sha256(run_ref) != handle.footer.run_id_sha256
          :error -> true
        end
      end) ->
        {:error, :selected_run_mismatch}

      true ->
        :ok
    end
  end

  defp validate_selected_claims(_opened, _source), do: :ok

  defp selected_requests({:file, path, run_ref}), do: %{path => run_ref}
  defp selected_requests({:viewer_file, path, run_ref}), do: %{path => run_ref}

  defp selected_requests({:selected_set, _directory, selected}),
    do: Map.new(selected, &{&1.path, &1.run_ref})

  defp selected_requests(_source), do: %{}

  defp requested_run(source, path), do: source |> selected_requests() |> Map.get(path)

  defp verify_selected_source({:selected_set, _directory, _selected} = source, files) do
    requests = selected_requests(source)

    with :ok <- verify_selected_paths(source, requests),
         true <- Enum.all?(files, fn {path, expected} -> current_file?(path, expected) end) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :source_changed}
    end
  end

  defp verify_selected_source(_source, _files), do: :ok

  defp verify_selected_paths({:selected_set, directory, selected}, requests) do
    run_refs = Enum.map(selected, & &1.run_ref)

    case SelectedCanonicalSource.resolve_inspections(directory, run_refs) do
      {:ok, current} ->
        if Map.new(current, &{&1.path, &1.run_ref}) == requests,
          do: :ok,
          else: {:error, :source_changed}

      {:error, _reason} ->
        {:error, :source_changed}
    end
  end

  defp current_file?(path, expected) do
    case File.lstat(path, time: :posix) do
      {:ok, current} -> file_identity(current) == file_identity(expected)
      {:error, _reason} -> false
    end
  end

  defp file_identity(%File.Stat{} = stat) do
    {stat.type, stat.size, stat.major_device, stat.minor_device, stat.inode}
  end

  defp selected_inspection_version(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result =
          case :file.pread(io, 0, Format.header_size()) do
            {:ok, header} -> selected_header_version(io, header)
            _malformed_or_unreadable -> :ok
          end

        :file.close(io)
        result

      {:error, :enoent} ->
        {:error, :selected_inspection_missing}

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp selected_header_version(io, header) do
    case Format.decode_header_versions(header) do
      {:ok, versions} ->
        if current_versions?(versions),
          do: validate_current_footer_version(io),
          else: {:error, :unsupported_schema}

      {:error, :malformed_source} ->
        :ok
    end
  end

  defp validate_current_footer_version(io) do
    with {:ok, size} <- :file.position(io, :eof),
         true <- size >= Format.header_size() + Format.footer_size(),
         {:ok, footer} <- :file.pread(io, size - Format.footer_size(), Format.footer_size()),
         {:ok, versions} <- Format.decode_footer_versions(footer),
         true <- current_versions?(versions) do
      :ok
    else
      _malformed_or_foreign_footer -> :ok
    end
  end

  defp validate_selected_versions(files, {:selected_set, _directory, _selected}) do
    Enum.reduce_while(files, :ok, fn {path, _stat}, :ok ->
      case selected_inspection_version(path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_selected_versions(_files, _source), do: :ok

  defp current_versions?(%{format_version: format_version, schema_version: schema_version}),
    do: format_version == Format.format_version() and schema_version == Format.schema_version()

  defp snapshot_digest(trace_capture_id, digests) do
    pairs =
      digests
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {run_id, digest} -> [<<byte_size(run_id)::64>>, run_id, digest] end)

    :crypto.hash(:sha256, [
      "ptc-inspection-snapshot-v1\0",
      trace_capture_id,
      <<map_size(digests)::64>>,
      pairs
    ])
    |> Base.url_encode64(padding: false)
  end

  defp query_result({:ok, {:ok, page, _metrics}}), do: {:ok, page}
  defp query_result({:ok, {:error, reason}}), do: {:error, reason}
  defp query_result({:error, :timeout}), do: {:error, :source_unavailable}
  defp query_result({:error, :cancelled}), do: {:error, :snapshot_unavailable}
  defp query_result({:error, :heap_exceeded}), do: {:error, :result_limit_exceeded}
  defp query_result(_other), do: {:error, :source_unavailable}

  defp deadline(opts, limits) do
    Keyword.get(
      opts,
      :capture_deadline_ms,
      System.monotonic_time(:millisecond) + limits.admission_deadline_ms
    )
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp capture_hook(nil), do: :ok

  defp capture_hook(hook) when is_function(hook, 0),
    do: if(hook.() == :ok, do: :ok, else: {:error, :source_unavailable})

  defp cleanup_failed(nil, _handles), do: :ok

  defp cleanup_failed(indexes, handles) do
    Indexes.delete_all(indexes)
    handles |> Map.values() |> Enum.each(&Handle.close/1)
    :ok
  end

  defp cleanup_owned(nil, handles, _deadline_ms) do
    handles |> Map.values() |> Enum.each(&Handle.close/1)
    :ok
  end

  defp cleanup_owned(indexes, handles, deadline_ms) do
    parent = self()

    {cleaner, monitor} =
      spawn_monitor(fn ->
        receive do
          {:cleanup, ^parent} ->
            handles |> Map.values() |> Enum.each(&Handle.close/1)
            Indexes.delete_all(indexes)
        end
      end)

    :ok = Indexes.give_away(indexes, cleaner)
    send(cleaner, {:cleanup, parent})

    receive do
      {:DOWN, ^monitor, :process, ^cleaner, _reason} -> :ok
    after
      deadline_ms ->
        Process.exit(cleaner, :kill)
        :ok
    end
  end

  defp admission_handles(admitted),
    do: Map.merge(admitted.handles, admitted.isolated_handles)

  defp close_isolated_handles(admitted) do
    admitted.isolated_handles |> Map.values() |> Enum.each(&Handle.close/1)
    :ok
  end

  defp normalize_error(reason)
       when reason in [
              :source_limit_exceeded,
              :source_changed,
              :source_unavailable,
              :malformed_source,
              :inspection_correlation_missing,
              :incomplete_inspection_correlation,
              :duplicate_inspection_run,
              :selected_run_mismatch,
              :selected_inspection_missing,
              :selected_inspection_not_regular,
              :unsupported_schema,
              :max_records,
              :max_index_entries,
              :max_logical_index_bytes,
              :max_retained_bytes
            ],
       do: reason

  defp normalize_error(:deadline_exceeded), do: :source_unavailable
  defp normalize_error(:cancelled), do: :snapshot_unavailable

  defp normalize_error({:source_retained_limit_exceeded, _details} = reason), do: reason

  defp normalize_error(_reason), do: :invalid_snapshot

  defp call(%__MODULE__{pid: pid, token: token}, request) do
    GenServer.call(pid, {token, request}, :infinity)
  catch
    :exit, _reason -> {:error, :snapshot_unavailable}
  end
end
