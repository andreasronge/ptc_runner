defmodule PtcRunner.Kernel.DabstepReviewerRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :nightly
  @moduletag timeout: 600_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.TestSupport.RunLifecycle

  @example Path.expand("../../../examples/dabstep-fraud", __DIR__)
  @application Path.join(@example, "reviewer.ptc.json")
  @host Path.join(@example, "ptc-host.reviewer-replay.json")
  @workflow_application Path.join(@example, "ptc.json")
  @workflow_host Path.join(@example, "ptc-host.replay.json")

  test "the reviewer's own measurement contradicts the captured wrong-metric answer" do
    assert {:ok, result} = run("reviewer-wrong-metric.json")
    assert result.value["caught"]
    assert result.value["case_id"] == "wrong-metric"
    assert result.value["reviewer_answer"] == "B. BE"
    assert result.value["measurements_agree"]
    assert result.value["problems"] != []
  end

  test "the reviewer's own measurement contradicts the seeded off-by-one totals" do
    assert {:ok, result} = run("reviewer-off-by-one.json")
    assert result.value["caught"]
    assert result.value["case_id"] == "off-by-one"
    assert result.value["reviewer_answer"] == "B. BE"
    refute result.value["measurements_agree"]
    assert result.value["problems"] != []
  end

  test "the full workflow replays three retained programs and agrees in workflow code" do
    assert {:ok, result} = run("luna.json", @workflow_application, @workflow_host)

    assert result.value == %{
             "ok" => true,
             "value" => "B. BE",
             "agreed" => true,
             "top_country" => %{"analysis" => "BE", "recheck" => "BE", "review" => "BE"},
             "problems" => []
           }
  end

  defp run(input_name, application \\ @application, host_path \\ @host) do
    {:ok, host} = HostConfig.load(host_path)

    {:ok, registry} =
      host
      |> HostInstallation.catalog()
      |> then(fn {:ok, catalog} -> HostInstallation.runtime_registry(host, catalog) end)

    application
    |> ApplicationPackage.request_directory(
      installed_limits: registry.installed_limits,
      input: Path.join([@example, "inputs", input_name])
    )
    |> RunLifecycle.build(registry)
    |> RunLifecycle.execute()
  end
end
