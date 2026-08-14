defmodule PtcRunner.Kernel.TutorialExamplesContractTest do
  use ExUnit.Case, async: true

  @examples Path.expand("../../../examples/kernel-tutorial", __DIR__)
  @host Path.join(@examples, "ptc-host.json")

  test "the shipped tutorial model belongs to ReqLLM's catalog" do
    model = @host |> decode!() |> get_in(["install", "deepseek", "model"])

    assert {:ok, _catalog_model} = ReqLLM.model(model)
  end

  test "live tutorial labels report the model installed by the host" do
    model = @host |> decode!() |> get_in(["install", "deepseek", "model"])

    for example <- ~w(02-deepseek-extract 03-file-agent 04-multi-turn-agent) do
      manifest = decode!(Path.join([@examples, example, "ptc.json"]))
      assert manifest["labels"]["model"] == model
    end
  end

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()
end
