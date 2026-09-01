defmodule PtcRunner.Kernel.TutorialCostBudgetTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.TestSupport.LLMSupport

  @examples Path.expand("../../../examples/kernel-tutorial", __DIR__)

  setup do
    snapshot = LLMSupport.snapshot_provider_applications()
    on_exit(fn -> LLMSupport.restore_provider_applications(snapshot) end)
    LLMSupport.stop_provider_applications()
    :ok
  end

  @tag :tmp_dir
  test "the cost-budget tutorial exits 6 before provider dispatch", %{tmp_dir: tmp_dir} do
    tutorial = Path.join(tmp_dir, "kernel-tutorial")
    File.cp_r!(@examples, tutorial)

    env_file = Path.join(tutorial, ".env")
    File.write!(env_file, "OPENROUTER_API_KEY=sentinel-not-a-real-key\n")
    File.chmod!(env_file, 0o600)

    project = Path.join(tutorial, "06-cost-budget.ptc-project.json")

    assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(["run", project])
    assert outcome.exit_status == 6, inspect(outcome.envelope, pretty: true)
    assert outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert outcome.envelope["error"]["message"] =~ "llm_cost_microusd"
    assert outcome.envelope["error"]["message"] =~ "next call requires"
  end
end
