defmodule PtcRunner.ViewerFrontend do
  @moduledoc """
  Serves one project's captured traces through the local PTC Viewer.

      ptc viewer ptc-project.json
      ptc viewer ptc-project.json --port 4123
      ptc viewer ptc-project.json --listen 0.0.0.0
      ptc viewer ptc-project.json --env-file .env

  The project must enable trace artifacts. The trace root, optional inspection
  root, port, browser-opening preference, analysis-REPL setting, and
  private-data grant all come from the named project document; there is no
  implicit project discovery and no separate Viewer path grammar.

  The command binds loopback unless `--listen 0.0.0.0` is given. That address
  publishes an unauthenticated trace browser — which can display private
  inspection records when the project grants them — to every host that can
  reach the port, so it is never reached by default and never inferred. Inside
  a container it is the only address a published port can forward to; the host
  exposure decision moves to the `docker run -p 127.0.0.1:` prefix, which the
  operator must write.

  The Viewer is an optional companion. It ships in the assembled release and
  the container image, and is absent from the Hex package, where this command
  reports `viewer_unavailable` rather than failing obscurely.

  The command runs in the foreground until the Viewer stops or the process is
  signalled; `SIGINT` and `SIGTERM` both end it cleanly.
  """

  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.ProjectArtifactRoot
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.ViewerBinding
  alias PtcRunner.Kernel.ViewerProjectAdapter
  alias PtcRunner.ViewerLaunchAdapter
  alias PtcRunner.ViewerSnapshotStore

  @collision_probe_body_bytes 8_192
  @collision_probe_timeout_ms 500

  # `scripts/verify_core_package.sh` compiles the packaged Hex source with
  # `--warnings-as-errors` and without this optional companion, where a literal
  # `PtcViewer.start/1` is an undefined-module warning and therefore a gate
  # failure. `PtcRunner.Kernel.DoctorEnvironment` probes the same companion the
  # same way, and never calls it.
  #
  # Every call below goes through `apply/3`, which is the only form that stays
  # opaque: Elixir's type inference resolves `@viewer.start(options)` and even
  # `viewer_module().start(options)` back to the attribute and warns on both.
  # That is why the `Credo.Check.Refactor.Apply` suppressions below are
  # deliberate rather than laziness -- removing them reintroduces the warning
  # and breaks the packaged-source build.
  @viewer PtcViewer
  @spec run(CommandArguments.t(), CommandRuntime.t()) :: :ok | {:error, atom(), binary()}
  def run(arguments, runtime), do: run(arguments, runtime, [])

  @doc false
  @spec run(CommandArguments.t(), CommandRuntime.t(), keyword()) ::
          :ok | {:error, atom(), binary()}
  def run(
        %CommandArguments{command: :viewer, application: project_path, options: options} =
          arguments,
        %CommandRuntime{},
        opts
      )
      when is_binary(project_path) do
    if companion_installed?() do
      case overrides(options) do
        {:ok, overrides} ->
          opts =
            opts
            |> Keyword.put(:frontend, arguments.frontend)
            |> Keyword.put(:env_file, Keyword.get(arguments.frontend_options, :env_file))

          serve(project_path, overrides, opts)

        :error ->
          {:error, :invalid_arguments, "invalid viewer command"}
      end
    else
      {:error, :viewer_unavailable, "the PTC Viewer companion is not installed in this build"}
    end
  rescue
    _exception -> {:error, :internal_error, "viewer command failed"}
  catch
    _kind, _reason -> {:error, :internal_error, "viewer command failed"}
  end

  def run(_arguments, _runtime, _opts),
    do: {:error, :invalid_arguments, "invalid viewer command"}

  @doc false
  @spec start(binary(), map(), keyword()) ::
          {:ok, pid(), ViewerBinding.address(), non_neg_integer()} | {:error, atom()}
  def start(project_path, overrides \\ %{}, opts \\ [])

  def start(project_path, overrides, opts)
      when is_binary(project_path) and is_map(overrides) and is_list(opts) do
    with :ok <- companion_available(),
         {:ok, callbacks} <- callbacks(opts),
         {:ok, project} <- ProjectConfig.load(project_path),
         :ok <- require_trace(project),
         :ok <- ProjectArtifactRoot.ensure(project.artifact_root) do
      start_captured(project, overrides, callbacks)
    end
  end

  def start(_project_path, _overrides, _opts), do: {:error, :project_invalid}

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

  defp serve(project_path, overrides, opts) do
    case start(project_path, overrides, opts) do
      {:ok, pid, address, port} ->
        announce(address, port, Keyword.get(opts, :device, :stdio))

        case await(pid) do
          :ok -> :ok
          {:error, reason} -> {:error, reason, "PTC Viewer stopped"}
        end

      {:error, {:viewer_port_in_use, port, owner}} ->
        {:error, :viewer_port_in_use, port_in_use_message(port, owner)}

      {:error, reason} ->
        {:error, reason, "could not start PTC Viewer"}
    end
  end

  # Both values are already accepted by the parser; re-resolving them here keeps
  # the frontend usable from a test or an embedding host that never parsed argv.
  defp overrides(options) do
    with {:ok, address} <- ViewerBinding.address(Map.get(options, :listen)),
         {:ok, port} <- override_port(Map.get(options, :port)),
         do: {:ok, %{address: address, port: port}}
  end

  defp override_port(nil), do: {:ok, nil}
  defp override_port(port), do: ViewerBinding.port(port)

  @doc false
  @spec announce(ViewerBinding.address(), non_neg_integer(), IO.device()) :: :ok
  def announce(address, port, device) do
    IO.puts(device, "PTC Viewer listening on http://#{:inet.ntoa(address)}:#{port}")

    if ViewerBinding.exposed?(address) do
      IO.puts(
        :stderr,
        "warning: --listen #{:inet.ntoa(address)} serves the Viewer to every host that can " <>
          "reach this port. It is unauthenticated and can display private inspection " <>
          "records when the project grants them."
      )
    end

    IO.puts(device, "Press Ctrl+C to stop")
  end

  defp companion_available do
    if companion_installed?(), do: :ok, else: {:error, :viewer_unavailable}
  end

  defp companion_installed?, do: Code.ensure_loaded?(@viewer)

  defp require_trace(%{artifact_root: root, artifacts: %{trace: true}}) when is_binary(root),
    do: :ok

  defp require_trace(_project), do: {:error, :project_traces_disabled}

  defp trace_source(project) do
    if project.viewer.private,
      do: {:private_authorized_directory, Path.join(project.artifact_root, "traces")},
      else: {:directory, Path.join(project.artifact_root, "traces")}
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

  defp start_captured(project, overrides, callbacks) do
    capture_inspection = fn trace, deadline ->
      invoke_capture(callbacks.capture_inspection, project, trace, deadline)
    end

    case ViewerSnapshotStore.start(trace_source(project), capture_inspection) do
      {:ok, snapshots} -> start_viewer(project, overrides, snapshots, callbacks)
      {:error, _reason} = error -> error
    end
  end

  defp start_viewer(project, overrides, snapshots, callbacks) do
    options = viewer_options(project, overrides, snapshots, callbacks)

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(@viewer, :start, [options]) do
      {:ok, pid} ->
        finish_start(pid, Keyword.fetch!(options, :ip), snapshots, callbacks)

      {:error, _reason} = error ->
        ViewerSnapshotStore.stop(snapshots)
        classify_start_error(error, options)
    end
  end

  defp finish_start(pid, address, snapshots, callbacks) do
    result =
      with :ok <- ViewerSnapshotStore.transfer_owner(snapshots, pid),
           {:ok, {^address, port}} <- invoke_listener_info(callbacks.listener_info, pid) do
        {:ok, pid, address, port}
      end

    case result do
      {:ok, _pid, _address, _port} = success ->
        success

      {:error, _reason} = error ->
        stop_viewer(pid)
        ViewerSnapshotStore.stop(snapshots)
        error

      _unexpected_listener ->
        stop_viewer(pid)
        ViewerSnapshotStore.stop(snapshots)
        {:error, :viewer_start_failed}
    end
  end

  defp callbacks(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      capture = Keyword.get(opts, :capture_inspection, &capture_inspection/3)
      listener = Keyword.get_lazy(opts, :listener_info, &default_listener_info/0)
      frontend = Keyword.get(opts, :frontend, :mix)
      env_file = Keyword.get(opts, :env_file)

      if keys -- [:capture_inspection, :listener_info, :device, :frontend, :env_file] == [] and
           length(keys) == MapSet.size(MapSet.new(keys)) and is_function(capture, 3) and
           is_function(listener, 1) and frontend in [:mix, :standalone] and
           valid_env_file?(env_file),
         do:
           {:ok,
            %{
              capture_inspection: capture,
              listener_info: listener,
              frontend: frontend,
              env_file: env_file
            }},
         else: {:error, :invalid_viewer_config}
    else
      {:error, :invalid_viewer_config}
    end
  end

  defp default_listener_info do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    fn pid -> apply(@viewer, :listener_info, [pid]) end
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
      {:ok, {address, port}} = success when port in 1..65_535 ->
        if ViewerBinding.address?(address), do: success, else: {:error, :viewer_start_failed}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, :viewer_start_failed}
    end
  rescue
    _exception -> {:error, :viewer_start_failed}
  catch
    _kind, _reason -> {:error, :viewer_start_failed}
  end

  defp stop_viewer(pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    if Process.alive?(pid), do: apply(@viewer, :stop, [pid])
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp viewer_options(project, overrides, snapshots, callbacks) do
    private? = project.viewer.private
    source = {:viewer_snapshot_store, snapshots}
    inspection? = ViewerSnapshotStore.inspection?(snapshots)

    [
      ip: Map.get(overrides, :address) || ViewerBinding.loopback(),
      port: Map.get(overrides, :port) || project.viewer.port,
      trace_dir: Path.join(project.artifact_root, "traces"),
      private_traces: private?,
      open: project.viewer.open and AnalysisTerminal.attached?(),
      trace_source: source,
      inspection_source: if(inspection?, do: source),
      kernel_trace_adapter: PtcRunner.Kernel.ProjectViewerAdapter,
      inspection_adapter:
        if(inspection?,
          do: PtcRunner.Kernel.ProjectViewerAdapter
        ),
      inspection_absence: inspection_absence(project, inspection?),
      live_token: System.get_env("PTC_VIEWER_TOKEN"),
      live_trace_refresh: fn run_id -> ViewerSnapshotStore.refresh(snapshots, run_id) end,
      launch: launch_spec(project, callbacks.frontend, callbacks.env_file),
      project_adapter: fn -> describe_project(project) end,
      repl_adapter: repl_adapter(project),
      repl_config: repl_config(project)
    ]
  end

  # `capture_inspection/3` requires both the recorded artifact and the private
  # grant, so an absent store has two possible causes and only the project
  # document distinguishes them. A reader whose `artifacts.inspection` is
  # already true and who is told to set it has been sent to the wrong field.
  defp inspection_absence(_project, true), do: nil

  defp inspection_absence(%{artifacts: %{inspection: true}, viewer: %{private: false}}, false),
    do: :not_private

  defp inspection_absence(_project, false), do: :not_recorded

  defp launch_spec(project, frontend, env_file) do
    label = workflow_label(project)
    input = workflow_input(project)
    effective_env_file = env_file || project.env_file

    config = %{
      project: project.path,
      frontend: frontend,
      env_file: effective_env_file,
      workflow_label: label
    }

    %{
      manifest: project.application,
      cwd: project.directory,
      label: label,
      input: input,
      adapter: fn request, report -> ViewerLaunchAdapter.launch(config, request, report) end
    }
  end

  defp workflow_input(project) do
    case describe_project(project) do
      {:ok, %{input: input}} when is_map(input) -> input
      _unavailable -> %{}
    end
  end

  defp workflow_label(project) do
    case describe_project(project) do
      {:ok, %{name: name, entry: entry}} when is_binary(name) ->
        [name, entry]
        |> Enum.join(" · ")
        |> String.slice(0, 256)

      _unavailable ->
        "workflow"
    end
  end

  defp describe_project(project) do
    opts = if project.host, do: [host_config: project.host], else: []

    with {:ok, description} <- ViewerProjectAdapter.describe(project.application, opts) do
      {:ok, Map.put(description, :project, project.path)}
    end
  end

  defp classify_start_error({:error, :viewer_start_failed} = error, options) do
    case Keyword.fetch!(options, :port) do
      port when port in 1..65_535 -> classify_occupied_port(port, error)
      _operating_system_assigned -> error
    end
  end

  defp classify_start_error(error, _options), do: error

  defp classify_occupied_port(port, fallback) do
    case probe_occupied_port(port) do
      {:viewer, project} -> {:error, {:viewer_port_in_use, port, project}}
      :occupied -> {:error, {:viewer_port_in_use, port, nil}}
      :unreachable -> fallback
    end
  end

  defp probe_occupied_port(port) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             ~c"127.0.0.1",
             port,
             [:binary, active: false],
             @collision_probe_timeout_ms
           ),
         :ok <- :gen_tcp.close(socket) do
      probe_viewer_owner(port)
    else
      {:error, _reason} -> :unreachable
    end
  rescue
    _exception -> :unreachable
  catch
    _kind, _reason -> :unreachable
  end

  defp probe_viewer_owner(port) do
    url = "http://127.0.0.1:#{port}/api/live/project"

    case Req.get(url,
           raw: true,
           redirect: false,
           retry: false,
           connect_options: [timeout: @collision_probe_timeout_ms],
           receive_timeout: @collision_probe_timeout_ms,
           into: &collect_probe_body/2
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> viewer_owner(body)
      {:ok, _response} -> :occupied
      {:error, _reason} -> :occupied
    end
  rescue
    _exception -> :occupied
  catch
    _kind, _reason -> :occupied
  end

  defp collect_probe_body({:data, data}, {request, %{body: body} = response})
       when is_binary(data) and is_binary(body) do
    body = body <> data

    if byte_size(body) <= @collision_probe_body_bytes,
      do: {:cont, {request, %{response | body: body}}},
      else: {:halt, {request, %{response | body: :too_large}}}
  end

  defp collect_probe_body(_chunk, {request, response}),
    do: {:halt, {request, %{response | body: :invalid}}}

  defp viewer_owner(body) do
    case Jason.decode(body) do
      {:ok, %{"enabled" => true, "project" => project}}
      when is_binary(project) and project != "" ->
        {:viewer, project}

      {:ok, _other_viewer_response} ->
        :occupied

      {:error, _reason} ->
        :occupied
    end
  end

  defp port_in_use_message(port, project) when is_binary(project) do
    "port #{port} is already serving a PTC Viewer for #{project}; " <>
      "stop it, pass --port 0, or choose another port"
  end

  defp port_in_use_message(port, nil) do
    "port #{port} is already in use; stop that service, pass --port 0, or choose another port"
  end

  defp repl_adapter(%{viewer: %{repl: true}}),
    do: PtcRunner.Kernel.ViewerReplAdapter

  defp repl_adapter(_project), do: nil

  defp repl_config(%{viewer: %{repl: true}, artifact_root: root}),
    do: %{trace_dir: Path.join(root, "traces"), profile_id: "run-analysis-v1"}

  defp repl_config(_project), do: %{}

  defp valid_env_file?(nil), do: true

  defp valid_env_file?(path),
    do: is_binary(path) and path != "" and String.valid?(path)
end
