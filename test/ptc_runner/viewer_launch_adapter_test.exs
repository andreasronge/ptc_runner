defmodule PtcRunner.ViewerLaunchAdapterTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.ViewerLaunchAdapter

  @examples Path.expand("../../examples", __DIR__)

  @tag :tmp_dir
  test "runs a workflow in the Viewer BEAM and reports directly to its sink", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])

    project = Path.join(target, "ptc-project.json")
    input_name = "viewer-input.json"
    File.write!(Path.join(target, input_name), Jason.encode!(%{"hello" => "viewer"}))
    test_process = self()

    report = fn run_id, frame ->
      send(test_process, {:live_frame, run_id, frame})
      :ok
    end

    assert {0, output} =
             ViewerLaunchAdapter.launch(
               %{
                 project: project,
                 frontend: :mix,
                 workflow_label: "hello-ptc · hello.core/run"
               },
               {:workflow, %{input: input_name}},
               report
             )

    assert output =~ "viewer"
    assert_receive {:live_frame, run_id, %{phase: "ok", label: "hello-ptc · hello.core/run"}}
    assert is_binary(run_id)
  end

  @tag :tmp_dir
  test "passes the Viewer's explicit environment file to an in-process workflow", %{
    tmp_dir: directory
  } do
    project = Path.join(directory, "ptc-project.json")
    application_dir = Path.join(directory, "application")
    host = Path.join(directory, "ptc-host.json")
    File.cp_r!(Path.join(@examples, "viewer-live-dashboard"), application_dir)

    @examples
    |> Path.join("viewer-live-dashboard.ptc-project.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("application", %{"path" => "application/ptc.json"})
    |> Map.put("host", %{"path" => "ptc-host.json"})
    |> Map.put("artifacts", %{
      "root" => "application/.test-artifacts",
      "trace" => false,
      "inspection" => false,
      "result" => false,
      "envelope" => false
    })
    |> Jason.encode!()
    |> then(&File.write!(project, &1))

    @examples
    |> Path.join("kernel-tutorial/ptc-host.json")
    |> File.read!()
    |> Jason.decode!()
    |> update_in(["install"], &Map.take(&1, ["deepseek"]))
    |> Jason.encode!()
    |> then(&File.write!(host, &1))

    input = Path.join(application_dir, "input.json")
    missing_env = Path.join(directory, "missing.env")
    File.write!(input, Jason.encode!(%{"topics" => ["one"]}))

    assert {status, output} =
             ViewerLaunchAdapter.launch(
               %{project: project, frontend: :mix, env_file: missing_env},
               {:workflow, %{input: Path.basename(input)}},
               fn _run_id, _frame -> :ok end
             )

    assert status != 0
    assert output =~ "environment_file_not_found"
  end
end
