defmodule PtcRunner.SubAgent.MissionLogTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.SystemPrompt

  describe "render_mission_log/1" do
    test "renders journal entries" do
      journal = %{"fetch-user" => %{"id" => 1, "name" => "Alice"}, "check-auth" => true}
      result = SystemPrompt.render_mission_log(journal)

      assert result =~ "## Mission Log (Completed Tasks)"
      assert result =~ "[done] fetch-user:"
      assert result =~ "[done] check-auth: true"
    end

    test "returns empty string for empty map" do
      assert SystemPrompt.render_mission_log(%{}) == ""
    end

    test "returns empty string for nil" do
      assert SystemPrompt.render_mission_log(nil) == ""
    end

    test "truncates long values" do
      journal = %{"big" => String.duplicate("x", 500)}
      result = SystemPrompt.render_mission_log(journal)

      assert result =~ "[done] big:"
      assert String.length(result) < 600
    end
  end
end
