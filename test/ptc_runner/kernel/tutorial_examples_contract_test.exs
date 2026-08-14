defmodule PtcRunner.Kernel.TutorialExamplesContractTest do
  use ExUnit.Case, async: true

  @examples Path.expand("../../../examples/kernel-tutorial", __DIR__)
  @host Path.join(@examples, "ptc-host.json")
  @viewer_examples Path.expand("../../../examples/viewer-demo", __DIR__)
  @named_missions Path.expand("../../../examples/named-mission-reader-writer", __DIR__)

  test "models in shipped runnable examples belong to ReqLLM's catalog" do
    installations = [
      {@host, "deepseek"},
      {Path.join(@viewer_examples, "ptc-host.json"), "deepseek"},
      {Path.join(@named_missions, "ptc-host.json"), "agent_model"}
    ]

    for {host, alias_name} <- installations do
      model = host |> decode!() |> get_in(["install", alias_name, "model"])
      assert {:ok, _catalog_model} = LLMDB.model(model), host
    end
  end

  test "live tutorial labels report the model installed by the host" do
    model = @host |> decode!() |> get_in(["install", "deepseek", "model"])

    for example <- ~w(02-deepseek-extract 03-file-agent 04-multi-turn-agent) do
      manifest = decode!(Path.join([@examples, example, "ptc.json"]))
      assert manifest["labels"]["model"] == model
    end
  end

  test "viewer example labels report the model installed by the host" do
    model =
      @viewer_examples
      |> Path.join("ptc-host.json")
      |> decode!()
      |> get_in(["install", "deepseek", "model"])

    for journey <- ~w(01-recovery 02-bulk 03-limits 04-loop-limit 05-memory) do
      manifest = decode!(Path.join(@viewer_examples, "#{journey}.json"))
      assert manifest["labels"]["model"] == model
    end
  end

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()
end
