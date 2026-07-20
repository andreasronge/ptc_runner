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

  test "the signature tutorial renders retryable model feedback without a provider" do
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok, result} = RunBuilder.run(path("05-signature-feedback"), registry)

    assert %{
             "invalid_evaluation" => %{
               kind: :prelude_contract_error,
               outcome: :evaluation_error,
               retryable?: true,
               details: %{
                 ref: "tutorial.signatures/double",
                 phase: :input,
                 path: ["value"]
               }
             },
             "model_feedback" => feedback,
             "corrected_evaluation" => %{outcome: :returned, value: 42}
           } = result.value

    assert feedback =~ "tutorial.signatures/double input value: expected int, got string"
    assert feedback =~ "Send one corrected run_ptc_lisp call"
    assert result.usage.subordinate_evaluations == 2
    assert result.usage.capability_calls.workflow == %{}
    assert result.usage.capability_calls.mission == %{}
  end

  defp path(example), do: Path.join([@examples, example, "ptc.json"])
end
