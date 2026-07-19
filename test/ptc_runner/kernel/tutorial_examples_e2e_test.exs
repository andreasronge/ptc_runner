defmodule PtcRunner.Kernel.TutorialExamplesE2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 180_000

  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  @examples Path.expand("../../../examples/kernel-tutorial", __DIR__)

  setup_all do
    :ok = PtcRunner.Dotenv.load()

    if System.get_env("OPENROUTER_API_KEY") do
      :ok
    else
      {:skip, "OPENROUTER_API_KEY is not configured"}
    end
  end

  test "the extraction tutorial returns the requested semantic fields" do
    assert {:ok, result} = run("02-deepseek-extract")
    assert %{"model_output" => model_output} = result.value
    assert {:ok, extracted} = Jason.decode(model_output)
    assert extracted["project"] == "Atlas"
    assert extracted["owner"] == "Priya"
    assert is_binary(extracted["risk"])

    risk = String.downcase(extracted["risk"])
    assert Enum.all?(~w(vendor security approval), &String.contains?(risk, &1))

    assert result.usage.subordinate_evaluations == 0
    assert result.usage.capability_calls.workflow["llm-request"] == 1
  end

  test "the file-agent tutorial returns the exact granted file content" do
    assert {:ok, result} = run("03-file-agent")
    expected = File.read!(Path.join([@examples, "03-file-agent", "files", "brief.txt"]))

    assert result.value == %{"ok" => true, "value" => expected}
    assert result.usage.subordinate_evaluations in 1..4
    assert result.usage.capability_calls.workflow["llm-request"] in 1..4
    assert result.usage.capability_calls.mission["fs-read"] == 1
  end

  test "the multi-turn tutorial commits a helper before explicit completion" do
    assert {:ok, result} = run("04-multi-turn-agent")
    assert result.value == %{"ok" => true, "value" => 42}
    assert result.usage.subordinate_evaluations == 2
    assert result.usage.capability_calls.workflow["llm-request"] == 2
    assert result.evaluation_memory.defined_count == 1
    assert result.evaluation_memory.history_count == 1
  end

  defp run(example) do
    {:ok, registry} = ProviderRegistry.new()
    RunBuilder.run(path(example), registry)
  end

  defp path(example), do: Path.join([@examples, example, "ptc.json"])
end
