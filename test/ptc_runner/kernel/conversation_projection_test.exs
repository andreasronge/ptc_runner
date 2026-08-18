defmodule PtcRunner.Kernel.ConversationProjectionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ConversationProjection

  @trace_facts %{
    "terminal?" => true,
    "events_dropped?" => false,
    "expected_model_exchange_ids" => []
  }

  describe "system prompts" do
    test "one stream carries its system prompt on the first turn and on every change" do
      first = exchange("llm-1", 1, [user("start")], "instructions v1", "one")

      second =
        exchange(
          "llm-2",
          3,
          [user("start"), assistant("one"), user("again")],
          "instructions v1",
          "two"
        )

      third =
        exchange(
          "llm-3",
          5,
          [user("start"), assistant("one"), user("again"), assistant("two"), user("more")],
          "instructions v2",
          "three"
        )

      assert %{
               "streams" => [
                 %{
                   "turns" => [
                     %{"turn" => 1} = turn_one,
                     %{"turn" => 2} = turn_two,
                     %{"turn" => 3} = turn_three
                   ]
                 }
               ]
             } = present([first, second, third])

      assert turn_one["system"] == "instructions v1"
      refute Map.has_key?(turn_two, "system")
      assert turn_three["system"] == "instructions v2"
    end

    test "every stream carries its own system prompt on its first turn" do
      first = exchange("llm-1", 1, [user("start")], "workflow instructions", "one")
      second = exchange("llm-2", 3, [user("elsewhere")], "mission instructions", "two")

      assert %{
               "streams" => [
                 %{"turns" => [workflow_turn]},
                 %{"turns" => [mission_turn]}
               ]
             } = present([first, second])

      assert workflow_turn["system"] == "workflow instructions"
      assert mission_turn["system"] == "mission instructions"
    end

    test "an exchange sent without a system prompt says so rather than staying silent" do
      assert %{"streams" => [%{"turns" => [turn]}]} =
               present([exchange("llm-1", 1, [user("start")], nil, "one")])

      assert Map.has_key?(turn, "system")
      assert turn["system"] == nil
    end
  end

  defp present(exchanges) do
    projection = ConversationProjection.compile(exchanges, [], @trace_facts)

    ConversationProjection.present_page(%{
      "items" => projection.items,
      "evidence" => projection.evidence
    })
  end

  defp exchange(capability_id, sequence, messages, system, content) do
    %{
      "capability_id" => capability_id,
      "input_sequence" => sequence,
      "output_sequence" => sequence + 1,
      "arguments" => %{"messages" => messages, "system" => system},
      "result" => %{"status" => "ok", "value" => %{"content" => content}}
    }
  end

  defp user(content), do: %{"role" => "user", "content" => content}
  defp assistant(content), do: %{"role" => "assistant", "content" => content}
end
