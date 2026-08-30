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

    test "every compiled turn keeps its own prompt, because turns are filtered downstream" do
      first = exchange("llm-1", 1, [user("start")], "instructions v1", "one")

      second =
        exchange(
          "llm-2",
          3,
          [user("start"), assistant("one"), user("again")],
          "instructions v1",
          "two"
        )

      projection = ConversationProjection.compile([first, second], [], @trace_facts)

      assert Enum.map(projection.items, & &1["system"]) == ["instructions v1", "instructions v1"]
    end

    test "a presented page that starts mid-stream still carries its prompt" do
      first = exchange("llm-1", 1, [user("start")], "instructions v1", "one")

      second =
        exchange(
          "llm-2",
          3,
          [user("start"), assistant("one"), user("again")],
          "instructions v1",
          "two"
        )

      projection = ConversationProjection.compile([first, second], [], @trace_facts)

      # `turns` filters and paginates before presentation, so a caller can be
      # handed the second turn without ever seeing the first. Eliding against a
      # turn the caller did not receive would drop the prompt entirely while
      # still reporting complete evidence.
      later_page = %{
        "items" => Enum.filter(projection.items, &(&1["turn"] == 2)),
        "evidence" => projection.evidence
      }

      assert %{"streams" => [%{"turns" => [turn]}]} =
               ConversationProjection.present_page(later_page)

      assert turn["turn"] == 2
      assert turn["system"] == "instructions v1"
    end

    test "each selected page starts every stream in it with that stream's prompt" do
      items = [
        %{"stream_id" => "stream-1", "turn" => 1, "system" => "a"},
        %{"stream_id" => "stream-1", "turn" => 2, "system" => "a"},
        %{"stream_id" => "stream-2", "turn" => 1, "system" => "b"},
        %{"stream_id" => "stream-2", "turn" => 2, "system" => "b"}
      ]

      compacted = ConversationProjection.compact_turns(items)

      assert Enum.map(compacted, &Map.get(&1, "system", :elided)) == ["a", :elided, "b", :elided]

      # A later page is compacted on its own, so it never elides against a turn
      # the caller was not handed.
      later = ConversationProjection.compact_turns(Enum.drop(items, 1))
      assert Enum.map(later, &Map.get(&1, "system", :elided)) == ["a", "b", :elided]
    end

    test "compaction is idempotent, so a page may be compacted again on presentation" do
      items = [
        %{"stream_id" => "stream-1", "turn" => 1, "system" => "a"},
        %{"stream_id" => "stream-1", "turn" => 2, "system" => "a"},
        %{"stream_id" => "stream-1", "turn" => 3, "system" => "b"}
      ]

      once = ConversationProjection.compact_turns(items)
      assert ConversationProjection.compact_turns(once) == once
      assert Enum.map(once, &Map.get(&1, "system", :elided)) == ["a", :elided, "b"]
    end

    test "an exchange sent without a system prompt says so rather than staying silent" do
      assert %{"streams" => [%{"turns" => [turn]}]} =
               present([exchange("llm-1", 1, [user("start")], nil, "one")])

      assert Map.has_key?(turn, "system")
      assert turn["system"] == nil
    end

    test "turn reconstruction preserves the replay request hash" do
      exchange =
        "llm-1"
        |> exchange(1, [user("start")], "instructions", "one")
        |> Map.put("request_hash", "sha256:private-request")

      assert %{"streams" => [%{"turns" => [turn]}]} = present([exchange])
      assert turn["request_hash"] == "sha256:private-request"
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
