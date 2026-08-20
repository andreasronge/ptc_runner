defmodule PtcRunner.Kernel.SupportTriageE2ETest do
  use ExUnit.Case, async: false

  @moduletag :scheduled_e2e
  @moduletag timeout: 300_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.RunLifecycle

  @examples Path.expand("../../../examples/support-triage", __DIR__)

  # The scores the deterministic triage policy computes for the four breached
  # tickets; the model composes the policy, so a run that disagrees either
  # broke the example or stopped using the mission API.
  @policy_scores %{"T-1001" => 75, "T-1004" => 81, "T-1005" => 52, "T-1006" => 58}

  setup_all do
    :ok = LLMSupport.load_dotenv()
    :ok = LLMSupport.admit_provider_application!()

    if System.get_env("OPENROUTER_API_KEY") do
      {:ok, host} = HostConfig.load(Path.join(@examples, "ptc-host.json"))
      {:ok, catalog} = HostInstallation.catalog(host)
      {:ok, registry} = HostInstallation.runtime_registry(host, catalog)
      {:ok, registry: registry}
    else
      {:skip, "OPENROUTER_API_KEY is not configured"}
    end
  end

  test "the one-question step returns exactly the refund ticket ids", %{registry: registry} do
    assert {:ok, result} = run("01-one-question", registry)
    assert %{"ok" => true, "value" => ids} = result.value
    assert Enum.sort(ids) == ["T-1001", "T-1004"]
  end

  test "the domain-api step returns the breached tickets in policy order", %{
    registry: registry
  } do
    assert {:ok, result} = run("02-domain-api", registry)
    assert %{"ok" => true, "value" => ranked} = result.value

    assert Enum.map(ranked, &{&1["id"], &1["priority"]}) ==
             [{"T-1004", 81}, {"T-1001", 75}, {"T-1006", 58}, {"T-1005", 52}]
  end

  test "the specialist step escalates every breached ticket with policy scores", %{
    registry: registry
  } do
    assert {:ok, result} = run("03-specialists", registry)
    assert %{"escalations" => escalations, "summary" => summary} = result.value
    assert is_binary(summary)

    scores = Map.new(escalations, &{&1["id"], &1["priority"]})
    assert scores == @policy_scores

    priorities = Enum.map(escalations, & &1["priority"])
    assert priorities == Enum.sort(priorities, :desc)
  end

  defp run(step, registry) do
    [@examples, step, "ptc.json"]
    |> Path.join()
    |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
    |> RunLifecycle.build(registry)
    |> RunLifecycle.execute()
  end
end
