defmodule PtcRunner.Kernel.LogAnalysisSessionBuilder do
  @moduledoc """
  Host boundary for the fixed local log-analysis profile.

  The builder accepts only a host-selected normal trace directory and a
  host-selected normal output directory. It captures the source immutably,
  compiles the shipped `log.core` closure, grants the four snapshot-bound read
  capabilities, creates fresh bounded owners, and starts one attested
  `PtcRunner.Kernel.LogAnalysisSession`. No caller can supply a profile,
  component, capability set, mission data, label, or limit.

  The calling process remains the completed session's stable lifecycle owner.
  Long-lived hosts must therefore invoke the builder in their connected backend
  owner rather than in a disposable request task.
  """

  alias PtcRunner.Kernel.LogAnalysisAssembly
  alias PtcRunner.Kernel.LogAnalysisProfile
  alias PtcRunner.Kernel.LogAnalysisSession
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SessionTrace
  alias PtcRunner.Kernel.TraceSnapshot

  @type source :: {:directory, binary()}
  @type destination :: {:directory, binary()}

  @doc """
  Starts one fixed log-analysis session over an immutable source capture.

  The destination directory receives one atomically published
  `<log-analysis-id>.jsonl` trace on close. Hosts decide whether source and
  destination may be the same: the Viewer intentionally uses one directory so
  refreshed sessions can inspect predecessors, while terminal callers require
  physically separate directories. The builder binds the destination's
  filesystem identity into the session trace. Publication runs relative to a
  helper process whose working directory is verified before bytes are sent, so
  later pathname replacement cannot redirect the write.
  """
  @spec start(source(), destination()) ::
          {:ok, LogAnalysisSession.t(), map()} | {:error, atom()}
  def start(source, destination), do: start(source, destination, [])

  @doc false
  def start({:directory, directory}, {:directory, trace_directory}, opts)
      when is_binary(directory) and is_binary(trace_directory) and is_list(opts) do
    allowed = [
      :persistence_fault_hook,
      :capture_hook,
      :listing_hook,
      :construction_hook,
      :evaluation_hook,
      :builder_fault_hook,
      :resource_cleanup_hook,
      :expected_destination_identity
    ]

    construction_hook = Keyword.get(opts, :construction_hook)
    evaluation_hook = Keyword.get(opts, :evaluation_hook)
    builder_fault_hook = Keyword.get(opts, :builder_fault_hook)
    resource_cleanup_hook = Keyword.get(opts, :resource_cleanup_hook)

    with true <- Keyword.keys(opts) -- allowed == [],
         true <- is_nil(construction_hook) or is_function(construction_hook, 2),
         true <- is_nil(evaluation_hook) or is_function(evaluation_hook, 1),
         true <- is_nil(builder_fault_hook) or is_function(builder_fault_hook, 2),
         true <- is_nil(resource_cleanup_hook) or is_function(resource_cleanup_hook, 0),
         true <- String.valid?(directory),
         true <- String.valid?(trace_directory),
         expanded = Path.expand(directory),
         expanded_trace_directory = Path.expand(trace_directory),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded_trace_directory),
         {:ok, destination_identity} <- directory_identity(expanded_trace_directory),
         true <-
           destination_identity ==
             Keyword.get(opts, :expected_destination_identity, destination_identity),
         {:ok, snapshot} <-
           TraceSnapshot.start({:directory, expanded},
             owner: self(),
             capture_hook: Keyword.get(opts, :capture_hook),
             listing_hook: Keyword.get(opts, :listing_hook)
           ) do
      build_owned_snapshot(snapshot, expanded_trace_directory, destination_identity, opts)
    else
      false -> {:error, :invalid_log_analysis_source}
      {:ok, %File.Stat{}} -> {:error, :invalid_log_analysis_source}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  rescue
    _exception -> {:error, :invalid_log_analysis_source}
  end

  def start(_source, _destination, _opts), do: {:error, :invalid_log_analysis_source}

  defp build_owned_snapshot(snapshot, directory, destination_identity, opts) do
    result =
      try do
        with :ok <-
               builder_fault(
                 Keyword.get(opts, :builder_fault_hook),
                 :after_snapshot,
                 %{snapshot: snapshot}
               ) do
          build(snapshot, directory, destination_identity, opts)
        end
      rescue
        _exception -> {:error, :log_analysis_session_failed}
      catch
        _kind, _reason -> {:error, :log_analysis_session_failed}
      end

    case result do
      {:ok, _session, _info} = success ->
        success

      {:error, reason} ->
        TraceSnapshot.stop(snapshot)
        {:error, normalize_error(reason)}
    end
  end

  defp build(snapshot, trace_directory, destination_identity, opts) do
    limits = LogAnalysisProfile.limits()
    run_id = "log-analysis-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    destination = Path.join(trace_directory, run_id <> ".jsonl")
    terminal_reserve = %{count: 2, bytes: limits.event_payload_bytes * 2}

    case RunState.start_with_event_sink(
           limits,
           [
             run_id: run_id,
             trace_id: run_id,
             fail_closed: true,
             terminal_reserve: terminal_reserve
           ],
           owner: self()
         ) do
      {:ok, run_state, sink} ->
        start_session(
          snapshot,
          run_state,
          sink,
          limits,
          destination,
          destination_identity,
          run_id,
          opts
        )

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp start_session(
         snapshot,
         run_state,
         sink,
         limits,
         destination,
         destination_identity,
         run_id,
         opts
       ) do
    case SessionTrace.start(limits, destination, run_id,
           owner: self(),
           persistence_fault_hook: Keyword.get(opts, :persistence_fault_hook),
           resource_cleanup_hook: Keyword.get(opts, :resource_cleanup_hook),
           destination_directory_identity: destination_identity,
           run_state: run_state,
           event_sink: sink
         ) do
      {:ok, session_trace} ->
        result =
          try do
            resources = %{
              snapshot: snapshot,
              session_trace: session_trace,
              run_state: run_state,
              event_sink: sink
            }

            with :ok <-
                   builder_fault(
                     Keyword.get(opts, :builder_fault_hook),
                     :before_run_state_transfer,
                     resources
                   ),
                 :ok <- RunState.transfer_owner(run_state, session_trace.pid),
                 :ok <-
                   builder_fault(
                     Keyword.get(opts, :builder_fault_hook),
                     :after_session_trace,
                     resources
                   ) do
              build_session(snapshot, session_trace, run_state, sink, opts)
            end
          rescue
            _exception -> {:error, :log_analysis_session_failed}
          catch
            _kind, _reason -> {:error, :log_analysis_session_failed}
          end

        case result do
          {:ok, _session, _info} = success ->
            success

          {:error, reason} ->
            SessionTrace.stop(session_trace)
            cleanup_run_state(run_state)
            TraceSnapshot.stop(snapshot)
            {:error, normalize_error(reason)}
        end

      {:error, reason} ->
        cleanup_run_state(run_state)
        TraceSnapshot.stop(snapshot)
        {:error, normalize_error(reason)}
    end
  end

  defp directory_identity(directory) do
    case File.stat(directory) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: major,
         minor_device: minor,
         inode: inode
       }}
      when is_integer(major) and is_integer(minor) and is_integer(inode) ->
        {:ok, {major, minor, inode}}

      _ ->
        {:error, :invalid_log_analysis_source}
    end
  end

  defp build_session(snapshot, session_trace, run_state, sink, opts) do
    with {:ok, ^sink} <- SessionTrace.sink(session_trace),
         {:ok, %{config: config, profile: profile}} <-
           LogAnalysisProfile.assemble(snapshot, sink),
         assembly =
           LogAnalysisAssembly.seal(config, profile, snapshot, session_trace, run_state),
         {:ok, session} <-
           LogAnalysisSession.start(assembly,
             evaluation_hook: Keyword.get(opts, :evaluation_hook),
             initialization_hook: Keyword.get(opts, :builder_fault_hook)
           ) do
      finish_session_start(session, snapshot, session_trace, run_state, sink, opts)
    end
  end

  defp finish_session_start(session, snapshot, session_trace, run_state, sink, opts) do
    resources = %{
      session: session,
      session_trace: session_trace,
      snapshot: snapshot,
      run_state: run_state,
      event_sink: sink
    }

    result =
      try do
        with :ok <- construction_hook(Keyword.get(opts, :construction_hook), resources),
             :ok <- TraceSnapshot.transfer_owner(snapshot, session.pid),
             {:ok, info} <- LogAnalysisSession.info(session),
             :ok <-
               builder_fault(
                 Keyword.get(opts, :builder_fault_hook),
                 :before_builder_release,
                 resources
               ),
             :ok <- SessionTrace.complete_construction(session_trace) do
          {:ok, session, info}
        end
      rescue
        _exception -> {:error, :log_analysis_session_failed}
      catch
        _kind, _reason -> {:error, :log_analysis_session_failed}
      end

    case result do
      {:ok, _session, _info} = success ->
        success

      {:error, _reason} = error ->
        cancel_construction(session_trace)
        LogAnalysisSession.stop(session)
        TraceSnapshot.stop(snapshot)
        error
    end
  end

  defp cancel_construction(session_trace) do
    SessionTrace.cancel_construction(session_trace)
  catch
    :exit, _reason -> :ok
  end

  defp cleanup_run_state(run_state) do
    RunState.close(run_state)
    RunState.stop(run_state)
  catch
    :exit, _reason -> :ok
  end

  defp construction_hook(nil, _resources), do: :ok

  defp construction_hook(hook, resources) do
    case hook.(:session_started, resources) do
      :ok -> :ok
      _ -> {:error, :log_analysis_session_failed}
    end
  rescue
    _exception -> {:error, :log_analysis_session_failed}
  catch
    _kind, _reason -> {:error, :log_analysis_session_failed}
  end

  defp builder_fault(nil, _stage, _resources), do: :ok

  defp builder_fault(hook, stage, resources) do
    case hook.(stage, resources) do
      :ok -> :ok
      _other -> {:error, :log_analysis_session_failed}
    end
  end

  defp normalize_error(reason) when is_atom(reason), do: reason
  defp normalize_error(_reason), do: :log_analysis_session_failed
end
