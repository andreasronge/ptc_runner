defmodule PtcRunner.ViewerFrontendTest do
  # Every Viewer listens on an OS-chosen port. The OS-environment and exact-stderr cases live in
  # ViewerFrontendGlobalStateTest.
  use ExUnit.Case, async: true
  @moduletag :operator

  import ExUnit.CaptureIO

  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Kernel.ViewerBinding
  alias PtcRunner.TestSupport.PrivateInspectionFixture
  alias PtcRunner.ViewerFrontend
  import PtcRunner.TestSupport.ViewerFrontendFixtures

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
  test "the private-data grant and public analysis REPL can be enabled together", %{
    tmp_dir: directory
  } do
    project_path = viewer_project(directory, %{"private" => true, "repl" => true})

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    origin = "http://#{:inet.ntoa(address)}:#{port}"
    page_config = viewer_page_config(origin)

    assert page_config["repl_enabled"] == true

    bootstrap =
      Req.get!(origin <> "/api/repl",
        headers: [
          {"sec-fetch-site", "same-origin"},
          {"x-ptc-viewer-page-nonce", page_config["page_bootstrap_nonce"]}
        ]
      )

    assert bootstrap.status == 200
    assert bootstrap.body["session"]["profile_id"] == "run-analysis-v1"
    assert bootstrap.body["session"]["namespaces"] == ["analysis", "cap"]
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "an absent inspection grant names viewer.private, not the artifact it already records", %{
    tmp_dir: directory
  } do
    # `artifacts.inspection` is on and the artifact is on disk; the private
    # grant is the only thing withholding it. Reporting "not configured" sent a
    # reader to change the field that was already correct.
    project_path =
      viewer_project(directory, %{"private" => false}, %{"trace" => true, "inspection" => true})

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    response =
      Req.get!("http://#{:inet.ntoa(address)}:#{port}/api/analysis/runs/run-1/conversation",
        retry: false
      )

    assert response.status == 404
    assert response.body == "inspection_not_private"
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "a project that records no inspection artifact keeps naming its own cause", %{
    tmp_dir: directory
  } do
    project_path =
      viewer_project(directory, %{"private" => true}, %{"trace" => true, "inspection" => false})

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    response =
      Req.get!("http://#{:inet.ntoa(address)}:#{port}/api/analysis/runs/run-1/conversation",
        retry: false
      )

    assert response.status == 404
    assert response.body == "inspection_not_configured"
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "revoking viewer.private takes effect on the next analysis request", %{
    tmp_dir: directory
  } do
    project_path =
      viewer_project(directory, %{"private" => true}, %{"trace" => true, "inspection" => true})

    {:ok, project} = ProjectConfig.load(project_path)
    fixture = PrivateInspectionFixture.create!(project.artifact_root, "granted-run")
    File.rm_rf!(Path.join(project.artifact_root, "analysis-traces"))

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    url =
      "http://#{:inet.ntoa(address)}:#{port}/api/analysis/runs/#{fixture.run_id}/conversation"

    first = Req.get!(url, retry: false)
    assert first.status == 200
    refute first.body == "inspection_not_private"

    document = Jason.decode!(File.read!(project_path))
    File.write!(project_path, Jason.encode!(put_in(document, ["viewer", "private"], false)))

    second = Req.get!(url, retry: false)
    assert second.status == 404
    assert second.body == "inspection_not_private"
    refute first.body == second.body
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "widening viewer.private serves inspection only after an explicit refresh", %{
    tmp_dir: directory
  } do
    project_path =
      viewer_project(directory, %{"private" => false}, %{"trace" => true, "inspection" => true})

    {:ok, project} = ProjectConfig.load(project_path)
    fixture = PrivateInspectionFixture.create!(project.artifact_root, "granted-run")
    File.rm_rf!(Path.join(project.artifact_root, "analysis-traces"))

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    origin = "http://#{:inet.ntoa(address)}:#{port}"
    url = origin <> "/api/analysis/runs/#{fixture.run_id}/conversation"

    withheld = Req.get!(url, retry: false)
    assert withheld.status == 404
    assert withheld.body == "inspection_not_private"

    document = Jason.decode!(File.read!(project_path))
    File.write!(project_path, Jason.encode!(put_in(document, ["viewer", "private"], true)))

    still_withheld = Req.get!(url, retry: false)
    assert still_withheld.status == 404
    assert still_withheld.body == "inspection_not_private"

    refresh = Req.post!(origin <> "/api/kernel/refresh", retry: false)
    assert refresh.status == 200

    granted = Req.get!(url, retry: false)
    assert granted.status == 200
    refute granted.body == "inspection_not_private"
    assert :ok = PtcViewer.stop(viewer)
  end

  @tag :tmp_dir
  test "a run finished after Viewer start appears after an explicit refresh", %{
    tmp_dir: directory
  } do
    project_path = viewer_project(directory)

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    origin = "http://#{:inet.ntoa(address)}:#{port}"
    first = Req.get!(origin <> "/api/kernel/runs", retry: false)
    assert first.status == 200
    assert length(first.body["items"]) == 1

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])

    stale = Req.get!(origin <> "/api/kernel/runs", retry: false)
    assert stale.status == 200
    assert length(stale.body["items"]) == 1

    refresh = Req.post!(origin <> "/api/kernel/refresh", retry: false)
    assert refresh.status == 200
    assert refresh.body == %{"status" => "ok"}

    fresh = Req.get!(origin <> "/api/kernel/runs", retry: false)
    assert fresh.status == 200
    assert length(fresh.body["items"]) == 2
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
    assert project["project"] == project_path
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

  # The code is interpolated into `viewer/<code>`, so a tagged refusal has to
  # reach the frontend as its tag; a tuple there raised and reported an
  # expected refusal as an internal error.
  @tag :tmp_dir
  test "a tagged capture refusal is reported under its own code", %{tmp_dir: directory} do
    project_path = viewer_project(directory)
    capture = fn _project, _trace, _deadline -> {:error, {:injected_refusal, %{detail: 1}}} end

    assert {:error, :injected_refusal, "could not start PTC Viewer"} =
             ViewerFrontend.run(
               viewer_arguments(project_path, 0),
               CommandRuntime.standalone(),
               capture_inspection: capture
             )
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
  test "a fixed-port collision names the project already served there", %{tmp_dir: directory} do
    first_directory = Path.join(directory, "first")
    second_directory = Path.join(directory, "second")
    File.mkdir!(first_directory)
    File.mkdir!(second_directory)

    first_project = viewer_project(first_directory)
    second_project = viewer_project(second_directory)

    assert {:ok, first_viewer, _address, port} = ViewerFrontend.start(first_project)
    on_exit(fn -> if Process.alive?(first_viewer), do: PtcViewer.stop(first_viewer) end)

    arguments = viewer_arguments(second_project, port)

    assert {:error, :viewer_port_in_use, message} =
             ViewerFrontend.run(arguments, CommandRuntime.standalone())

    assert message ==
             "port #{port} is already serving a PTC Viewer for #{first_project}; " <>
               "stop it, pass --port 0, or choose another port"

    assert :ok = PtcViewer.stop(first_viewer)
  end

  @tag :tmp_dir
  test "a fixed-port collision distinguishes another service from a Viewer", %{
    tmp_dir: directory
  } do
    project_path = viewer_project(directory)

    assert {:ok, listener} =
             :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    assert {:ok, {_address, port}} = :inet.sockname(listener)

    responder =
      Task.async(fn ->
        {:ok, probe_socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.close(probe_socket)
        {:ok, request_socket} = :gen_tcp.accept(listener)

        :ok =
          :gen_tcp.send(
            request_socket,
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )

        :ok = :gen_tcp.close(request_socket)
      end)

    assert {:error, :viewer_port_in_use, message} =
             ViewerFrontend.run(
               viewer_arguments(project_path, port),
               CommandRuntime.standalone()
             )

    assert message ==
             "port #{port} is already in use; stop that service, pass --port 0, or choose another port"

    assert :ok = Task.await(responder, 1_000)
  end

  @tag :tmp_dir
  test "browser opening follows the classified terminal attachment", %{tmp_dir: directory} do
    project_path = viewer_project(directory, %{"open" => true})

    for {terminal_attached, expected_open} <- [{false, false}, {true, true}] do
      assert {:ok, options} = captured_viewer_options(project_path, terminal_attached)
      assert Keyword.fetch!(options, :open) == expected_open
    end
  end

  @tag :tmp_dir
  test "browser opening classifies the real terminal lazily when no override is supplied", %{
    tmp_dir: directory
  } do
    project_path = viewer_project(directory, %{"open" => true})

    assert {:ok, options} = captured_viewer_options(project_path)
    assert Keyword.fetch!(options, :open) == AnalysisTerminal.attached?()
  end

  @tag :tmp_dir
  test "invalid classified terminal attachment is rejected", %{tmp_dir: directory} do
    project_path = viewer_project(directory)

    for invalid <- [nil, :yes, 1, "true"] do
      assert {:error, :invalid_viewer_config} =
               ViewerFrontend.start(project_path, %{}, terminal_attached: invalid)
    end
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

  @tag :tmp_dir
  test "a schema-invalid Viewer project retains the atomic frontend error contract", %{
    tmp_dir: directory
  } do
    project_path = Path.join(directory, "ptc-project.json")

    File.write!(
      project_path,
      Jason.encode!(%{
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => "ptc.json"},
        "viewer" => %{"port" => 65_536}
      })
    )

    assert {:error, :project_invalid} = ViewerFrontend.start(project_path)

    arguments = %CommandArguments{
      command: :viewer,
      application: project_path,
      directory: nil,
      options: %{},
      ordered_options: [],
      frontend: :standalone,
      frontend_options: []
    }

    assert {:error, :project_invalid, "could not start PTC Viewer"} =
             ViewerFrontend.run(arguments, CommandRuntime.standalone())
  end

  test "unavailable project validation retains the atomic Viewer error contract" do
    project_path = "ptc-project.json"
    project_loader = fn ^project_path -> {:error, {:schema_validation_unavailable, :timeout}} end

    assert {:error, :schema_validation_unavailable} =
             ViewerFrontend.start(project_path, %{}, project_loader: project_loader)

    arguments = %CommandArguments{
      command: :viewer,
      application: project_path,
      directory: nil,
      options: %{},
      ordered_options: [],
      frontend: :standalone,
      frontend_options: []
    }

    assert {:error, :schema_validation_unavailable, "could not start PTC Viewer"} =
             ViewerFrontend.run(arguments, CommandRuntime.standalone(),
               project_loader: project_loader
             )
  end

  defp announce(address, port) do
    ViewerFrontend.announce(address, port, :stdio)
  end

  defp captured_viewer_options(project_path, terminal_attached \\ :default) do
    parent = self()

    before_viewer_start = fn options ->
      send(parent, {:viewer_options, options})
      {:error, :viewer_options_captured}
    end

    options = [before_viewer_start: before_viewer_start]

    options =
      if terminal_attached == :default,
        do: options,
        else: Keyword.put(options, :terminal_attached, terminal_attached)

    assert {:error, :viewer_options_captured} = ViewerFrontend.start(project_path, %{}, options)
    assert_receive {:viewer_options, viewer_options}
    {:ok, viewer_options}
  end

  defp viewer_arguments(project_path, port) do
    %CommandArguments{
      command: :viewer,
      application: project_path,
      directory: nil,
      options: %{port: Integer.to_string(port)},
      ordered_options: [],
      frontend: :standalone,
      frontend_options: []
    }
  end
end
