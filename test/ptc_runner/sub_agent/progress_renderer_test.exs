defmodule PtcRunner.SubAgent.ProgressRendererTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.ProgressRenderer

  describe "render/3" do
    test "returns empty string for empty plan" do
      assert ProgressRenderer.render([], %{}) == ""
    end

    test "renders all pending when no summaries" do
      plan = [{"1", "Gather data"}, {"2", "Analyze results"}]
      result = ProgressRenderer.render(plan, %{})

      assert result =~ "- [ ] **1.** Gather data"
      assert result =~ "- [ ] **2.** Analyze results"
    end

    test "marks step as done when summary exists" do
      plan = [{"1", "Gather data"}, {"2", "Analyze results"}]
      summaries = %{"1" => "Found 42 records"}
      result = ProgressRenderer.render(plan, summaries)

      assert result =~ "- [x] **1.** Gather data — Found 42 records"
      assert result =~ "- [ ] **2.** Analyze results"
    end

    test "journal entries do not affect checklist" do
      plan = [{"1", "Gather data"}, {"2", "Analyze results"}]
      # Even if journal has matching IDs, checklist stays unchecked
      result = ProgressRenderer.render(plan, %{})

      assert result =~ "- [ ] **1.** Gather data"
      assert result =~ "- [ ] **2.** Analyze results"
    end

    test "shows out-of-plan steps for non-plan step-done entries" do
      plan = [{"1", "Gather data"}]
      summaries = %{"1" => "Done", "extra" => "Unexpected finding"}
      result = ProgressRenderer.render(plan, summaries)

      assert result =~ "### Out-of-Plan Steps"
      assert result =~ "- [x] extra: Unexpected finding"
    end

    test "does not truncate summaries (LLM-authored)" do
      plan = [{"1", "Step"}]
      long = String.duplicate("x", 300)
      summaries = %{"1" => long}
      result = ProgressRenderer.render(plan, summaries)

      assert result =~ "- [x] **1.** Step — " <> long
    end
  end

  describe "instruction text" do
    test "shows step-done instruction" do
      plan = [{"1", "Step one"}, {"2", "Step two"}]
      result = ProgressRenderer.render(plan, %{})

      assert result =~ "step-done"
      assert result =~ "one step per turn"
    end
  end
end
