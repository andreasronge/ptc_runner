defmodule PtcRunner.ViewerFrontendTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Kernel.ViewerBinding
  alias PtcRunner.ViewerFrontend

  @tag :tmp_dir
  test "starts from the project document with pre-pinned trace authority", %{tmp_dir: directory} do
    project_path = viewer_project(directory)

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)
    assert address == ViewerBinding.loopback()
    assert port > 0
    assert Process.alive?(viewer)
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "project command configures Live project details and its fixed launch target", %{
    tmp_dir: directory
  } do
    project_path = viewer_project(directory)

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    base_url = "http://#{:inet.ntoa(address)}:#{port}"

    assert {:ok, %{status: 200, body: project}} = Req.get(base_url <> "/api/live/project")
    assert project["enabled"] == true
    assert project["manifest"] == Path.join(directory, "demo/ptc.json")

    assert {:ok, %{status: 200, body: launch}} = Req.get(base_url <> "/api/live/launch")
    assert launch["enabled"] == true
    assert launch["manifest"] == Path.join(directory, "demo/ptc.json")
    assert launch["label"] == "ptc.json · main/run"

    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "Live launch materializes a manifest-relative input file", %{tmp_dir: directory} do
    project_path = viewer_project(directory)
    manifest_path = Path.join(directory, "demo/ptc.json")
    input = %{"source" => "file", "items" => [1, 2, 3]}
    File.write!(Path.join(directory, "demo/live-input.json"), Jason.encode!(input))

    manifest = Jason.decode!(File.read!(manifest_path))

    File.write!(
      manifest_path,
      Jason.encode!(Map.put(manifest, "input", %{"path" => "live-input.json"}))
    )

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    assert {:ok, %{status: 200, body: launch}} =
             Req.get("http://#{:inet.ntoa(address)}:#{port}/api/live/launch")

    assert launch["input"] == input
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "inspection-capture failure releases the already captured trace", %{tmp_dir: directory} do
    project_path = viewer_project(directory)
    parent = self()

    capture = fn _project, trace, _deadline ->
      send(parent, {:captured_trace, trace})
      {:error, :injected_inspection_failure}
    end

    assert {:error, :injected_inspection_failure} =
             ViewerFrontend.start(project_path, %{}, capture_inspection: capture)

    assert_receive {:captured_trace, trace}

    if Process.alive?(trace.pid) do
      ref = Process.monitor(trace.pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
    end

    refute TraceSnapshot.alive?(trace)
  end

  @tag :tmp_dir
  test "post-start listener failure stops the Viewer and transferred snapshots", %{
    tmp_dir: directory
  } do
    project_path = viewer_project(directory)
    parent = self()

    listener = fn viewer ->
      send(parent, {:started_viewer, viewer})
      {:error, :injected_listener_failure}
    end

    assert {:error, :injected_listener_failure} =
             ViewerFrontend.start(project_path, %{}, listener_info: listener)

    assert_receive {:started_viewer, viewer}
    refute Process.alive?(viewer)
  end

  test "foreground waiting returns when the Viewer process dies" do
    viewer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    waiting = Task.async(fn -> ViewerFrontend.await(viewer) end)

    Process.exit(viewer, :kill)

    assert {:error, :viewer_stopped} = Task.await(waiting, 1_000)
  end

  @tag :tmp_dir
  test "an explicit wildcard bind is honored and warns about the exposure", %{
    tmp_dir: directory
  } do
    project_path = viewer_project(directory)

    assert {:ok, viewer, {0, 0, 0, 0}, port} =
             ViewerFrontend.start(project_path, %{address: {0, 0, 0, 0}, port: nil})

    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)
    assert port > 0

    warning =
      capture_io(:stderr, fn ->
        capture_io(fn -> announce({0, 0, 0, 0}, port) end)
      end)

    assert warning =~ "--listen 0.0.0.0"
    assert warning =~ "unauthenticated"
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "loopback start announces its address and warns about nothing", %{tmp_dir: directory} do
    project_path = viewer_project(directory)

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    warning = capture_io(:stderr, fn -> capture_io(fn -> announce(address, port) end) end)
    assert warning == ""

    announced = capture_io(fn -> announce(address, port) end)
    assert announced =~ "http://127.0.0.1:#{port}"
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "--port overrides the project's configured port", %{tmp_dir: directory} do
    project_path = viewer_project(directory, %{"port" => 4123})

    assert {:ok, viewer, _address, port} =
             ViewerFrontend.start(project_path, %{address: nil, port: 0})

    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)
    # The project asked for 4123; the override asked the OS to choose.
    assert port != 4123
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "browser opening stays inert without an attached terminal", %{tmp_dir: directory} do
    # The suite never runs with stdin and stdout both on a terminal, so this
    # asserts the gate rather than simulating it: a project that asks to open a
    # browser must still not launch one here.
    refute AnalysisTerminal.attached?()
    project_path = viewer_project(directory, %{"open" => true})

    assert {:ok, viewer, _address, _port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "passes the process live reporter token into the Viewer", %{tmp_dir: directory} do
    previous = System.get_env("PTC_VIEWER_TOKEN")
    project_path = viewer_project(directory)

    on_exit(fn ->
      if previous,
        do: System.put_env("PTC_VIEWER_TOKEN", previous),
        else: System.delete_env("PTC_VIEWER_TOKEN")
    end)

    System.put_env("PTC_VIEWER_TOKEN", "too-short")
    assert {:error, :invalid_viewer_config} = ViewerFrontend.start(project_path)

    System.put_env("PTC_VIEWER_TOKEN", String.duplicate("x", 32))
    assert {:ok, viewer, _address, _port} = ViewerFrontend.start(project_path)
    assert :ok = PtcViewer.stop(viewer)
  end

  test "an invalid listen or port value is refused before anything is captured" do
    for options <- [%{listen: "10.0.0.1"}, %{port: "65536"}, %{port: "abc"}] do
      assert {:error, :invalid_arguments, _message} =
               ViewerFrontend.run(
                 %CommandArguments{
                   command: :viewer,
                   application: "missing-project.json",
                   directory: nil,
                   options: options,
                   ordered_options: [],
                   frontend: :standalone,
                   frontend_options: []
                 },
                 CommandRuntime.standalone()
               )
    end
  end

  defp announce(address, port) do
    ViewerFrontend.announce(address, port, :stdio)
  end

  defp viewer_project(directory, viewer_overrides \\ %{}) do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])
    project = Jason.decode!(File.read!(project_path))

    viewer =
      Map.merge(
        %{"port" => 0, "open" => false, "repl" => false, "private" => false},
        viewer_overrides
      )

    File.write!(project_path, Jason.encode!(put_in(project, ["viewer"], viewer)))
    project_path
  end
end
