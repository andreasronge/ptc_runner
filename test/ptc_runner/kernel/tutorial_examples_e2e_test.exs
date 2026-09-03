defmodule PtcRunner.Kernel.TutorialExamplesE2ETest do
  use ExUnit.Case, async: false

  @moduletag :scheduled_e2e
  @moduletag timeout: 180_000

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.RunLifecycle

  @examples Path.expand("../../../examples/kernel-tutorial", __DIR__)
  @host Path.join(@examples, "ptc-host.json")

  setup_all do
    :ok = LLMSupport.load_dotenv()
    :ok = LLMSupport.admit_provider_application!()

    if System.get_env("OPENROUTER_API_KEY") do
      :ok
    else
      {:skip, "OPENROUTER_API_KEY is not configured"}
    end
  end

  test "the extraction tutorial returns the schema-shaped object the model filled in" do
    assert {:ok, result} = run("02-deepseek-extract")
    assert %{"project" => project, "owner" => "Priya", "risk" => risk} = result.value
    assert map_size(result.value) == 3

    normalized_project =
      project
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("project ", "")

    assert normalized_project == "atlas"

    risk = String.downcase(risk)
    assert Enum.all?(~w(vendor security approval), &String.contains?(risk, &1))

    assert result.usage.subordinate_evaluations == 0
    assert result.usage.capability_calls.workflow["llm-request"] == 1
  end

  test "the fan-out tutorial answers every topic in parallel, then summarizes them" do
    assert {:ok, result} = run("07-parallel-fan-out")
    assert %{"answers" => answers, "summary" => summary} = result.value
    assert length(answers) == 12

    for %{"topic" => topic, "answer" => answer} <- answers do
      assert is_binary(topic)
      assert is_binary(answer) and answer != ""
    end

    assert is_binary(summary) and summary != ""
    assert result.usage.subordinate_evaluations == 0
    assert result.usage.capability_calls.workflow["llm-request"] == 13
  end

  test "the file-agent tutorial returns the exact granted file content" do
    assert {:ok, result} = run("03-file-agent")
    expected = File.read!(Path.join([@examples, "03-file-agent", "files", "brief.txt"]))

    assert result.value == %{"ok" => true, "value" => expected}
    assert result.usage.subordinate_evaluations in 1..4
    assert result.usage.capability_calls.workflow["llm-request"] in 1..4
    assert result.usage.capability_calls.mission["workspace.read"] >= 1
  end

  defp run(example) do
    {:ok, host} = HostConfig.load(@host)

    {:ok, registry} =
      HostInstallation.catalog(host)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(host, catalog)
      end)

    example
    |> path()
    |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
    |> RunLifecycle.build(registry)
    |> RunLifecycle.execute()
  end

  defp path(example), do: Path.join([@examples, example, "ptc.json"])
end
