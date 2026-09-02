defmodule PtcRunner.Kernel.DabstepReviewerRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :nightly
  @moduletag timeout: 240_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.TestSupport.RunLifecycle

  @example Path.expand("../../../examples/dabstep-fraud", __DIR__)
  @application Path.join(@example, "reviewer.ptc.json")
  @host Path.join(@example, "ptc-host.reviewer-replay.json")

  test "Luna catches the captured DeepSeek wrong-metric decision" do
    assert {:ok, result} = run("reviewer-wrong-metric.json")
    assert result.value["caught"]
    assert result.value["case_id"] == "wrong-metric"

    finding = result.value["problems"] |> Enum.join(" ") |> String.downcase()
    assert finding =~ "ratio"
    assert finding =~ "a. nl"
    assert finding =~ "b. be"
  end

  test "Luna catches the seeded off-by-one pagination program" do
    assert {:ok, result} = run("reviewer-off-by-one.json")
    assert result.value["caught"]
    assert result.value["case_id"] == "off-by-one"

    finding = result.value["problems"] |> Enum.join(" ") |> String.downcase()
    assert finding =~ "first"
    assert finding =~ "row"
    assert finding =~ "page"
    assert finding =~ "rest"
  end

  defp run(input_name) do
    {:ok, host} = HostConfig.load(@host)

    {:ok, registry} =
      host
      |> HostInstallation.catalog()
      |> then(fn {:ok, catalog} -> HostInstallation.runtime_registry(host, catalog) end)

    @application
    |> ApplicationPackage.request_directory(
      installed_limits: registry.installed_limits,
      input: Path.join([@example, "inputs", input_name])
    )
    |> RunLifecycle.build(registry)
    |> RunLifecycle.execute()
  end
end
