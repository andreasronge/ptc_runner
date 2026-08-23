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
  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

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
  test "project environment values are restored between Live launches", %{tmp_dir: directory} do
    project_path = viewer_project(directory)
    project = Jason.decode!(File.read!(project_path))
    project_directory = Path.dirname(project_path)
    host_path = Path.join(project_directory, "ptc-host.json")
    env_path = Path.join(project_directory, "viewer.env")
    environment_name = "PTC_VIEWER_SCOPED_PROJECT_ENV"
    previous = System.get_env(environment_name)

    on_exit(fn ->
      if previous,
        do: System.put_env(environment_name, previous),
        else: System.delete_env(environment_name)
    end)

    System.delete_env(environment_name)

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{"unused" => %{"env" => "PTC_VIEWER_UNUSED_CREDENTIAL"}},
        "install" => %{
          "unused" => %{
            "source" => "llm",
            "installation_revision" => "viewer-test-v1",
            "model" => "openrouter:deepseek/deepseek-v4-flash",
            "credential" => "unused",
            "cache" => false
          }
        }
      })
    )

    project =
      Map.put(project, "host", %{
        "path" => Path.basename(host_path),
        "env_file" => %{"path" => Path.basename(env_path)}
      })

    File.write!(project_path, Jason.encode!(project))
    File.write!(env_path, "#{environment_name}=first\n")

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    base_url = "http://#{:inet.ntoa(address)}:#{port}"
    nonce = live_nonce(base_url)

    launch_workflow(base_url, nonce, %{"launch" => 1})
    assert_launch_finished(base_url)
    assert System.get_env(environment_name) == nil

    File.write!(env_path, "#{environment_name}=second\n")
    launch_workflow(base_url, nonce, %{"launch" => 2})
    assert_launch_finished(base_url)
    assert System.get_env(environment_name) == nil

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

  defp live_nonce(base_url) do
    base_url
    |> viewer_page_config()
    |> Map.fetch!("live_mutation_nonce")
  end

  defp viewer_page_config(base_url) do
    assert {:ok, %{status: 200, body: body}} = Req.get(base_url <> "/")

    [encoded] =
      Regex.run(~r/<meta name="ptc-viewer-config" content="([^"]+)">/, body,
        capture: :all_but_first
      )

    encoded
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end

  defp launch_workflow(base_url, nonce, input) do
    assert {:ok, %{status: 202}} =
             Req.post(base_url <> "/api/live/launch",
               json: %{"input" => input},
               headers: [
                 {"origin", base_url},
                 {"x-ptc-viewer-live-nonce", nonce}
               ]
             )
  end

  defp assert_launch_finished(base_url) do
    assert_eventually(fn ->
      case Req.get(base_url <> "/api/live/launch") do
        {:ok, %{status: 200, body: %{"launch" => %{"status" => status}}}}
        when status in ["ok", "error"] ->
          true

        _other ->
          false
      end
    end)
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

  defp viewer_project(directory, viewer_overrides \\ %{}, artifact_overrides \\ %{}) do
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

    artifacts = Map.merge(project["artifacts"] || %{}, artifact_overrides)

    document =
      project
      |> put_in(["viewer"], viewer)
      |> put_in(["artifacts"], artifacts)

    File.write!(project_path, Jason.encode!(document))
    project_path
  end
end
