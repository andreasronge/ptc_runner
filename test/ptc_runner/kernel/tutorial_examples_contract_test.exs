defmodule PtcRunner.Kernel.TutorialExamplesContractTest do
  use ExUnit.Case, async: true

  @examples Path.expand("../../../examples/kernel-tutorial", __DIR__)
  @host Path.join(@examples, "ptc-host.json")
  @viewer_examples Path.expand("../../../examples/viewer-demo", __DIR__)
  @named_missions Path.expand("../../../examples/named-mission-reader-writer", __DIR__)
  @support_triage Path.expand("../../../examples/support-triage", __DIR__)

  test "models in shipped runnable examples belong to ReqLLM's catalog" do
    installations = [
      {@host, "deepseek"},
      {Path.join(@viewer_examples, "ptc-host.json"), "deepseek"},
      {Path.join(@named_missions, "ptc-host.json"), "agent_model"},
      {Path.join(@support_triage, "ptc-host.json"), "deepseek"}
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

  test "the multi-turn tutorial declares both Kernel run clocks" do
    manifest = decode!(Path.join([@examples, "04-multi-turn-agent", "ptc.json"]))

    assert manifest["limits"] == %{
             "run_duration_ms" => 120_000,
             "workflow_timeout_ms" => 120_000
           }
  end

  test "support-triage labels report the model installed by the host" do
    model =
      @support_triage
      |> Path.join("ptc-host.json")
      |> decode!()
      |> get_in(["install", "deepseek", "model"])

    for step <- ~w(01-one-question 02-domain-api 03-specialists) do
      manifest = decode!(Path.join([@support_triage, step, "ptc.json"]))
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

  test "the viewer memory journey preserves feedback and forces a terminal demo error" do
    manifest = decode!(Path.join(@viewer_examples, "05-memory.json"))

    assert manifest["input"]["value"]["max_turns"] == 2
    assert manifest["workflow"]["entry"] == "demo.agent/run-terminal-error"
  end

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()
end
