defmodule PtcRunner.Kernel.TutorialExamplesTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  @examples Path.expand("../../../examples/kernel-tutorial", __DIR__)

  test "the deterministic tutorial manifest returns the documented value" do
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok,
            %{
              value: %{
                "order_count" => 3,
                "paid_count" => 2,
                "paid_total" => 335.75,
                "pending_ids" => ["A-101"]
              }
            }} = RunBuilder.run(path("01-orders"), registry)
  end

  test "the live-model tutorial manifests compile and assemble without calling a provider" do
    {:ok, registry} = ProviderRegistry.new()

    for example <- ["02-deepseek-extract", "03-file-agent", "04-multi-turn-agent"] do
      assert {:ok, built} = RunBuilder.load_and_build(path(example), registry)
      assert is_binary(built.entry_source)
      EventSink.stop(built.config.event_sink)
    end
  end

  defp path(example), do: Path.join([@examples, example, "ptc.json"])
end
