defmodule Mix.Tasks.PtcViewerTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ptc.Viewer
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.TraceSnapshot

  @tag :tmp_dir
  test "starts from the project document with pre-pinned trace authority", %{tmp_dir: directory} do
    project_path = viewer_project(directory)

    assert {:ok, viewer, port} = Viewer.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)
    assert port > 0
    assert Process.alive?(viewer)
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
             Viewer.start(project_path, capture_inspection: capture)

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
             Viewer.start(project_path, listener_info: listener)

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

    waiting = Task.async(fn -> Viewer.await(viewer) end)

    Process.exit(viewer, :kill)

    assert {:error, :viewer_stopped} = Task.await(waiting, 1_000)
  end

  defp viewer_project(directory) do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])
    project = Jason.decode!(File.read!(project_path))

    project =
      put_in(project, ["viewer"], %{
        "port" => 0,
        "open" => false,
        "repl" => false,
        "private" => false
      })

    File.write!(project_path, Jason.encode!(project))
    project_path
  end
end
