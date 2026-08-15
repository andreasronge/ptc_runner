defmodule Mix.Tasks.Ptc.Viewer do
  @moduledoc """
  Launches the local PTC Viewer from one project configuration.

      mix ptc.viewer ptc-project.json

  The project must enable trace artifacts. Viewer settings and its explicit
  private-data grant come from the named project document; there is no
  implicit project discovery or separate Viewer path grammar.
  """
  @shortdoc "Launch PTC Viewer from a project configuration"

  use Mix.Task

  alias PtcRunner.Kernel.ProjectArtifactRoot
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.TraceSnapshot

  @impl Mix.Task
  def run([project_path]) do
    Mix.Task.run("app.start")

    case start(project_path) do
      {:ok, pid, port} ->
        Mix.shell().info("PTC Viewer running at http://localhost:#{port}")
        Mix.shell().info("Press Ctrl+C to stop")

        case await(pid) do
          :ok -> :ok
          {:error, reason} -> Mix.raise("PTC Viewer stopped: #{safe_reason(reason)}")
        end

      {:error, reason} ->
        Mix.raise("could not start PTC Viewer: #{safe_reason(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix ptc.viewer PROJECT.json")

  @doc false
  @spec await(pid()) :: :ok | {:error, :viewer_stopped}
  def await(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      :stop ->
        Process.demonitor(ref, [:flush])
        stop_viewer(pid)

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :viewer_stopped}
    end
  end

  def await(_pid), do: {:error, :viewer_stopped}

  @doc false
  @spec start(binary()) :: {:ok, pid(), non_neg_integer()} | {:error, atom() | term()}
  def start(project_path), do: start(project_path, [])

  @doc false
  @spec start(binary(), keyword()) :: {:ok, pid(), non_neg_integer()} | {:error, atom() | term()}
  def start(project_path, opts) when is_binary(project_path) and is_list(opts) do
    with {:ok, callbacks} <- callbacks(opts),
         {:ok, project} <- ProjectConfig.load(project_path),
         :ok <- require_trace(project),
         :ok <- ProjectArtifactRoot.ensure(project.artifact_root) do
      capture_deadline_ms = System.monotonic_time(:millisecond) + 15_000
      start_captured(project, capture_deadline_ms, callbacks)
    end
  end

  def start(_project_path, _opts), do: {:error, :project_invalid}

  defp require_trace(%{artifact_root: root, artifacts: %{trace: true}}) when is_binary(root),
    do: :ok

  defp require_trace(_project), do: {:error, :project_traces_disabled}

  defp capture_trace(project, capture_deadline_ms) do
    source =
      if project.viewer.private,
        do: {:private_authorized_directory, Path.join(project.artifact_root, "traces")},
        else: {:directory, Path.join(project.artifact_root, "traces")}

    TraceSnapshot.start(source, capture_deadline_ms: capture_deadline_ms)
  end

  defp capture_inspection(
         %{artifacts: %{inspection: true}, viewer: %{private: true}, artifact_root: root},
         trace,
         capture_deadline_ms
       ) do
    InspectionSnapshot.start(
      {:directory, Path.join(root, "inspection")},
      trace,
      capture_deadline_ms: capture_deadline_ms
    )
  end

  defp capture_inspection(_project, _trace, _capture_deadline_ms), do: {:ok, nil}

  defp start_captured(project, capture_deadline_ms, callbacks) do
    case capture_trace(project, capture_deadline_ms) do
      {:ok, trace} -> capture_inspection_and_start(project, trace, capture_deadline_ms, callbacks)
      {:error, _reason} = error -> error
    end
  end

  defp capture_inspection_and_start(project, trace, capture_deadline_ms, callbacks) do
    case invoke_capture(callbacks.capture_inspection, project, trace, capture_deadline_ms) do
      {:ok, inspection} ->
        start_viewer(project, trace, inspection, callbacks)

      {:error, _reason} = error ->
        TraceSnapshot.stop(trace)
        error
    end
  end

  defp start_viewer(project, trace, inspection, callbacks) do
    case PtcViewer.start(viewer_options(project, trace, inspection)) do
      {:ok, pid} ->
        finish_start(pid, trace, inspection, callbacks)

      {:error, _reason} = error ->
        cleanup_snapshots(trace, inspection)
        error
    end
  end

  defp finish_start(pid, trace, inspection, callbacks) do
    result =
      with :ok <- TraceSnapshot.transfer_owner(trace, pid),
           :ok <- transfer_inspection(inspection, pid),
           {:ok, {_address, port}} <- invoke_listener_info(callbacks.listener_info, pid) do
        {:ok, pid, port}
      end

    case result do
      {:ok, _pid, _port} = success ->
        success

      {:error, _reason} = error ->
        stop_viewer(pid)
        cleanup_snapshots(trace, inspection)
        error
    end
  end

  defp callbacks(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      capture = Keyword.get(opts, :capture_inspection, &capture_inspection/3)
      listener = Keyword.get(opts, :listener_info, &PtcViewer.listener_info/1)

      if keys -- [:capture_inspection, :listener_info] == [] and
           length(keys) == MapSet.size(MapSet.new(keys)) and is_function(capture, 3) and
           is_function(listener, 1),
         do: {:ok, %{capture_inspection: capture, listener_info: listener}},
         else: {:error, :invalid_viewer_config}
    else
      {:error, :invalid_viewer_config}
    end
  end

  defp invoke_capture(callback, project, trace, capture_deadline_ms) do
    case callback.(project, trace, capture_deadline_ms) do
      {:ok, _inspection} = success -> success
      {:error, _reason} = error -> error
      _invalid -> {:error, :viewer_start_failed}
    end
  rescue
    _exception -> {:error, :viewer_start_failed}
  catch
    _kind, _reason -> {:error, :viewer_start_failed}
  end

  defp invoke_listener_info(callback, pid) do
    case callback.(pid) do
      {:ok, {{127, 0, 0, 1}, port}} = success when port in 1..65_535 -> success
      {:error, _reason} = error -> error
      _invalid -> {:error, :viewer_start_failed}
    end
  rescue
    _exception -> {:error, :viewer_start_failed}
  catch
    _kind, _reason -> {:error, :viewer_start_failed}
  end

  defp cleanup_snapshots(trace, inspection) do
    InspectionSnapshot.stop(inspection)
    TraceSnapshot.stop(trace)
    :ok
  end

  defp stop_viewer(pid) do
    if Process.alive?(pid), do: PtcViewer.stop(pid)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp viewer_options(project, trace, inspection) do
    private? = project.viewer.private

    [
      port: project.viewer.port,
      trace_dir: Path.join(project.artifact_root, "traces"),
      private_traces: private?,
      open: project.viewer.open,
      trace_source: {:trace_snapshot, trace},
      inspection_source: if(inspection, do: {:inspection_snapshot, inspection}),
      kernel_trace_adapter: PtcRunner.Kernel.ProjectViewerAdapter,
      inspection_adapter: if(inspection, do: PtcRunner.Kernel.ProjectViewerAdapter),
      repl_adapter: repl_adapter(project, private?),
      repl_config: repl_config(project, private?)
    ]
  end

  defp repl_adapter(%{viewer: %{repl: true}}, false),
    do: PtcRunner.Kernel.ViewerReplAdapter

  defp repl_adapter(_project, _private?), do: nil

  defp repl_config(%{viewer: %{repl: true}, artifact_root: root}, false),
    do: %{trace_dir: Path.join(root, "traces"), profile_id: "run-analysis-v1"}

  defp repl_config(_project, _private?), do: %{}

  defp transfer_inspection(nil, _pid), do: :ok

  defp transfer_inspection(inspection, pid),
    do: InspectionSnapshot.transfer_owner(inspection, pid)

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "viewer_start_failed"
end
