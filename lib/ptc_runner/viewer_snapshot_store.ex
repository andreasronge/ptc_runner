defmodule PtcRunner.ViewerSnapshotStore do
  @moduledoc """
  Owner-bound captured view of one Viewer's trace and inspection snapshots.

  The store captures both snapshots at start and serves Runs and analysis
  queries from that retained admission. `viewer.private` is not part of that
  immutability: every serving call re-reads the project document and, when
  its digest changed, reloads it. Revocation (`true` to `false`) drops the
  held `InspectionSnapshot` and the private-authorized trace snapshot inside
  the same `handle_call` and never serves from the discarded admission.
  Widening (`false` to `true`) and newly finished runs take effect only on
  `refresh/1` or `refresh/2`, which recapture under the grant current at that
  moment.
  """

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.ProjectViewerAdapter
  alias PtcRunner.Kernel.TraceSnapshot

  @capture_timeout_ms 15_000
  @call_timeout_ms @capture_timeout_ms + 5_000
  @operations [:list_runs, :get_run, :list_turns, :counters]
  @grant_keys [:owner, :project, :project_path, :project_loader]

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @typedoc false
  @type capture_inspection ::
          (term(), integer() ->
             {:ok, InspectionSnapshot.t() | nil} | {:error, term()})
          | (ProjectConfig.t() | nil, term(), integer() ->
               {:ok, InspectionSnapshot.t() | nil} | {:error, term()})

  @spec start(
          {:directory | :private_authorized_directory, binary()},
          capture_inspection(),
          keyword()
        ) :: {:ok, t()} | {:error, term()}
  def start(trace_source, capture_inspection, opts \\ [])

  def start({kind, directory} = trace_source, capture_inspection, opts)
      when kind in [:directory, :private_authorized_directory] and is_binary(directory) and
             is_list(opts) do
    with {:ok, capture} <- normalize_capture(capture_inspection),
         {:ok, grant} <- grant_opts(opts),
         owner when is_pid(owner) <- Keyword.get(opts, :owner, self()) do
      token = make_ref()

      case GenServer.start(__MODULE__, {trace_source, capture, owner, token, grant}) do
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

  @spec result(t(), binary()) :: {:ok, map()} | {:error, atom()}
  def result(%__MODULE__{} = store, run_id) when is_binary(run_id),
    do: call(store, {:result, run_id})

  def result(_store, _run_id), do: {:error, :invalid_inspection_query}

  @spec preludes(t(), binary()) :: {:ok, map()} | {:error, atom()}
  def preludes(%__MODULE__{} = store, run_id) when is_binary(run_id),
    do: call(store, {:preludes, run_id})

  def preludes(_store, _run_id), do: {:error, :invalid_inspection_query}

  @spec execution_errors(t(), binary()) :: {:ok, map()} | {:error, atom()}
  def execution_errors(%__MODULE__{} = store, run_id) when is_binary(run_id),
    do: call(store, {:execution_errors, run_id})

  def execution_errors(_store, _run_id), do: {:error, :invalid_inspection_query}

  @spec explicit_failure_values(t(), binary()) :: {:ok, map()} | {:error, atom()}
  def explicit_failure_values(%__MODULE__{} = store, run_id) when is_binary(run_id),
    do: call(store, {:explicit_failure_values, run_id})

  def explicit_failure_values(_store, _run_id), do: {:error, :invalid_inspection_query}

  @spec refresh(t()) :: :ok | {:error, atom()}
  def refresh(%__MODULE__{} = store), do: call(store, {:refresh, :all})

  def refresh(_store), do: {:error, :invalid_query}

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
  def init({trace_source, capture_inspection, owner, token, grant}) do
    owner_ref = Process.monitor(owner)

    case capture(trace_source, capture_inspection, grant.loaded_project) do
      {:ok, trace, inspection} ->
        {:ok,
         %{
           capture_inspection: capture_inspection,
           document_digest: nil,
           inspection: inspection,
           loaded_project: grant.loaded_project,
           owner_ref: owner_ref,
           private?: private_source?(trace_source),
           project_loader: grant.project_loader,
           project_path: grant.project_path,
           token: token,
           trace: trace,
           trace_directory: source_directory(trace_source),
           trace_source: trace_source
         }}

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])
        {:stop, reason}
    end
  end

  @impl GenServer
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

  def handle_call({token, request}, _from, %{token: token} = state) do
    {state, outcome} = sync_grant(state)
    respond(request, state, outcome)
  end

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

  defp respond({:query, operation, arguments}, state, _outcome) do
    case ensure_trace(state) do
      {:ok, state} ->
        {:reply, TraceSnapshot.query(state.trace, operation, arguments), state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp respond({:conversation, run_id}, state, outcome),
    do: respond_inspection(state, outcome, :conversation, run_id)

  defp respond({:result, run_id}, state, outcome),
    do: respond_inspection(state, outcome, :result, run_id)

  defp respond({:preludes, run_id}, state, outcome),
    do: respond_inspection(state, outcome, :preludes, run_id)

  defp respond({:execution_errors, run_id}, state, outcome),
    do: respond_inspection(state, outcome, :execution_errors, run_id)

  defp respond({:explicit_failure_values, run_id}, state, outcome),
    do: respond_inspection(state, outcome, :explicit_failure_values, run_id)

  defp respond({:refresh, required}, state, :unreadable) do
    if grant_tracked?(state),
      do: {:reply, {:error, :snapshot_unavailable}, state},
      else: commit_refresh(state, required)
  end

  defp respond({:refresh, required}, state, _outcome),
    do: commit_refresh(state, required)

  defp respond(:inspection?, state, :unreadable) do
    {:reply, grant_tracked?(state) == false and not is_nil(state.inspection), state}
  end

  defp respond(:inspection?, state, _outcome),
    do: {:reply, not is_nil(state.inspection), state}

  defp respond(_request, state, _outcome),
    do: {:reply, {:error, :invalid_snapshot_store}, state}

  defp respond_inspection(state, :unreadable, _operation, _run_id),
    do: {:reply, {:error, :inspection_not_private}, state}

  defp respond_inspection(state, _outcome, operation, run_id) do
    if grant_tracked?(state) and (not state.private? or is_nil(state.inspection)) do
      {:reply, {:error, :inspection_not_private}, state}
    else
      {:reply, inspect_snapshot(state.inspection, operation, run_id), state}
    end
  end

  defp sync_grant(state) do
    if grant_tracked?(state), do: sync_tracked_grant(state), else: {state, :ok}
  end

  defp sync_tracked_grant(state) do
    case ProjectConfig.document_digest(state.project_path) do
      {:ok, digest} when digest == state.document_digest ->
        {state, :ok}

      {:ok, digest} ->
        reload_grant(state, digest)

      {:error, _reason} ->
        {state, :unreadable}
    end
  end

  defp reload_grant(state, digest) do
    case invoke_loader(state.project_loader, state.project_path) do
      {:ok, project} -> apply_loaded_project(state, project, digest)
      {:error, _reason} -> {state, :unreadable}
    end
  end

  defp apply_loaded_project(state, project, digest) do
    state = %{
      state
      | document_digest: digest,
        loaded_project: retain_boot_project(state.loaded_project, project)
    }

    if state.private? and not project.viewer.private do
      drop_private(state)
    else
      {state, :ok}
    end
  end

  # Other project fields stay boot-read. Only the private grant is overlaid from
  # the reloaded document, so a combined edit cannot retarget artifact_root or
  # flip artifacts.inspection on a serving or refresh path.
  defp retain_boot_project(%ProjectConfig{} = boot, %ProjectConfig{} = loaded) do
    %{boot | viewer: %{boot.viewer | private: loaded.viewer.private}}
  end

  defp retain_boot_project(_boot, project), do: project

  defp drop_private(state) do
    cleanup(state.trace, state.inspection)

    {%{
       state
       | inspection: nil,
         private?: false,
         trace: nil,
         trace_source: sanitized_source(state.trace_source)
     }, :revoked}
  end

  defp ensure_trace(%{trace: trace} = state) when not is_nil(trace), do: {:ok, state}

  defp ensure_trace(state) do
    case recapture(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp commit_refresh(state, required) do
    case capture_next(state, :current) do
      {:ok, source, trace, inspection} ->
        keep_or_discard(state, required, source, trace, inspection)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp keep_or_discard(state, :all, source, trace, inspection) do
    cleanup(state.trace, state.inspection)
    {:reply, :ok, replace_capture(state, source, trace, inspection)}
  end

  defp keep_or_discard(state, run_id, source, trace, inspection) do
    case TraceSnapshot.run_exists?(trace, run_id) do
      {:ok, true} ->
        cleanup(state.trace, state.inspection)
        {:reply, :ok, replace_capture(state, source, trace, inspection)}

      {:ok, false} ->
        cleanup(trace, inspection)
        {:reply, {:error, :not_found}, state}

      {:error, reason} ->
        cleanup(trace, inspection)
        {:reply, {:error, reason}, state}
    end
  end

  defp recapture(state) do
    case capture_next(state, :held) do
      {:ok, source, trace, inspection} ->
        cleanup(state.trace, state.inspection)
        {:ok, replace_capture(state, source, trace, inspection)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_next(state, grant) do
    source = trace_source_for(state, grant)
    project = project_for_capture(state, grant)

    case capture(source, state.capture_inspection, project) do
      {:ok, trace, inspection} -> {:ok, source, trace, inspection}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp replace_capture(state, source, trace, inspection) do
    %{
      state
      | inspection: inspection,
        private?: private_source?(source),
        trace: trace,
        trace_source: source
    }
  end

  defp trace_source_for(%{private?: true, trace_directory: directory}, :held)
       when is_binary(directory),
       do: {:private_authorized_directory, directory}

  defp trace_source_for(%{trace_directory: directory}, :held) when is_binary(directory),
    do: {:directory, directory}

  defp trace_source_for(%{trace_source: source}, :held), do: source

  defp trace_source_for(state, :current), do: desired_trace_source(state)

  defp desired_trace_source(%{
         loaded_project: %{viewer: %{private: true}},
         trace_directory: directory
       })
       when is_binary(directory),
       do: {:private_authorized_directory, directory}

  defp desired_trace_source(%{loaded_project: %ProjectConfig{}, trace_directory: directory})
       when is_binary(directory),
       do: {:directory, directory}

  defp desired_trace_source(%{trace_source: source}), do: source

  defp project_for_capture(
         %{loaded_project: %ProjectConfig{} = project, private?: private?},
         :held
       ) do
    %{project | viewer: %{project.viewer | private: private?}}
  end

  defp project_for_capture(state, _grant), do: state.loaded_project

  defp capture(trace_source, capture_inspection, project) do
    deadline = System.monotonic_time(:millisecond) + @capture_timeout_ms

    with {:ok, trace} <-
           TraceSnapshot.start(trace_source, owner: self(), capture_deadline_ms: deadline) do
      case invoke_inspection(capture_inspection, project, trace, deadline) do
        {:ok, inspection} ->
          {:ok, trace, inspection}

        {:error, reason} ->
          TraceSnapshot.stop(trace)
          {:error, reason}
      end
    end
  end

  defp invoke_inspection(callback, project, trace, deadline) do
    case callback.(project, trace, deadline) do
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

  defp invoke_loader(loader, path) do
    case loader.(path) do
      {:ok, %ProjectConfig{}} = success -> success
      {:error, :project_unavailable} = error -> error
      {:error, :project_invalid} = error -> error
      {:error, {:schema_validation_unavailable, _reason}} = error -> error
      {:error, {:project_schema_invalid, _violation}} = error -> error
      _invalid -> {:error, :project_invalid}
    end
  rescue
    _exception -> {:error, :project_invalid}
  catch
    _kind, _reason -> {:error, :project_invalid}
  end

  defp inspect_snapshot(nil, _operation, _run_id), do: {:error, :unavailable}

  defp inspect_snapshot(snapshot, :conversation, run_id),
    do: ProjectViewerAdapter.conversation({:inspection_snapshot, snapshot}, run_id)

  defp inspect_snapshot(snapshot, :result, run_id),
    do: ProjectViewerAdapter.result({:inspection_snapshot, snapshot}, run_id)

  defp inspect_snapshot(snapshot, :preludes, run_id),
    do: ProjectViewerAdapter.preludes({:inspection_snapshot, snapshot}, run_id)

  defp inspect_snapshot(snapshot, :execution_errors, run_id),
    do: ProjectViewerAdapter.execution_errors({:inspection_snapshot, snapshot}, run_id)

  defp inspect_snapshot(snapshot, :explicit_failure_values, run_id),
    do: ProjectViewerAdapter.explicit_failure_values({:inspection_snapshot, snapshot}, run_id)

  defp cleanup(trace, inspection) do
    InspectionSnapshot.stop(inspection)
    TraceSnapshot.stop(trace)
  end

  defp normalize_error(reason) when is_atom(reason), do: reason
  defp normalize_error(_reason), do: :snapshot_unavailable

  defp grant_tracked?(%{project_path: path}), do: is_binary(path)

  defp private_source?({:private_authorized_directory, _directory}), do: true
  defp private_source?(_source), do: false

  defp sanitized_source({:private_authorized_directory, directory}), do: {:directory, directory}
  defp sanitized_source(source), do: source

  defp source_directory({_kind, directory}) when is_binary(directory), do: directory

  defp normalize_capture(fun) when is_function(fun, 2),
    do: {:ok, fn _project, trace, deadline -> fun.(trace, deadline) end}

  defp normalize_capture(fun) when is_function(fun, 3), do: {:ok, fun}
  defp normalize_capture(_fun), do: :error

  defp grant_opts(opts) do
    if Keyword.keys(opts) -- @grant_keys == [] do
      decode_grant(
        Keyword.get(opts, :project),
        Keyword.get(opts, :project_path),
        Keyword.get(opts, :project_loader)
      )
    else
      :error
    end
  end

  defp decode_grant(nil, nil, nil),
    do: {:ok, %{loaded_project: nil, project_path: nil, project_loader: nil}}

  defp decode_grant(project, path, loader)
       when is_binary(path) and path != "" and
              (is_nil(project) or is_struct(project, ProjectConfig)) and
              (is_nil(loader) or is_function(loader, 1)) do
    {:ok,
     %{
       loaded_project: project,
       project_path: path,
       project_loader: loader || (&ProjectConfig.load/1)
     }}
  end

  defp decode_grant(_project, _path, _loader), do: :error

  defp call(%__MODULE__{pid: pid, token: token}, request) do
    GenServer.call(pid, {token, request}, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :snapshot_unavailable}
  end
end
