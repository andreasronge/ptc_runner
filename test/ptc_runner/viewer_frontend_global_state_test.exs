defmodule PtcRunner.ViewerFrontendGlobalStateTest do
  # async: false — two cases set PTC_VIEWER_TOKEN or a project env var the Viewer reads, and one
  # asserts that global :stderr stays empty (class D).
  use ExUnit.Case, async: false
  @moduletag :operator

  import ExUnit.CaptureIO
  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]
  import PtcRunner.TestSupport.ViewerFrontendFixtures

  alias PtcRunner.ViewerFrontend

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
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
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
  test "loopback start announces its address and warns about nothing", %{tmp_dir: directory} do
    project_path = viewer_project(directory)

    assert {:ok, viewer, address, port} = ViewerFrontend.start(project_path)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    warning =
      capture_io(:stderr, fn ->
        capture_io(fn -> ViewerFrontend.announce(address, port, :stdio) end)
      end)

    assert warning == ""

    announced = capture_io(fn -> ViewerFrontend.announce(address, port, :stdio) end)
    assert announced =~ "http://127.0.0.1:#{port}"
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

  defp live_nonce(base_url) do
    base_url
    |> viewer_page_config()
    |> Map.fetch!("live_mutation_nonce")
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
end
