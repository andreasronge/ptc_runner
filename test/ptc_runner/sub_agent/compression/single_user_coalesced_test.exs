defmodule PtcRunner.SubAgent.Compression.SingleUserCoalescedTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Compression.SingleUserCoalesced
  alias PtcRunner.Turn

  defp make_tool(name, signature) do
    %PtcRunner.Tool{name: name, signature: signature, type: :native}
  end

  defp base_opts do
    [
      prompt: "Test mission",
      system_prompt: "Test system prompt",
      tools: %{},
      data: %{},
      println_limit: 15,
      tool_call_limit: 20,
      turns_left: 5
    ]
  end

  describe "name/0" do
    test "returns strategy name" do
      assert SingleUserCoalesced.name() == "single-user-coalesced"
    end
  end

  describe "to_messages/3 structure" do
    test "returns [system, user] message array" do
      messages = SingleUserCoalesced.to_messages([], %{}, base_opts())

      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :system
      assert Enum.at(messages, 1).role == :user
    end

    test "system message contains system_prompt" do
      opts = Keyword.put(base_opts(), :system_prompt, "Custom system prompt")
      [system, _user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert system.content == "Custom system prompt"
    end

    test "handles missing system_prompt" do
      opts = Keyword.delete(base_opts(), :system_prompt)
      [system, _user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert system.content == ""
    end
  end

  describe "mission handling (MSG-003, MSG-007)" do
    test "mission appears first in USER message" do
      [_system, user] = SingleUserCoalesced.to_messages([], %{}, base_opts())

      assert String.starts_with?(user.content, "Test mission")
    end

    test "mission is never removed even with errors" do
      failed_turn =
        Turn.failure(
          1,
          "raw",
          "(bad-code)",
          %{message: "error"},
          [],
          [],
          %{}
        )

      [_system, user] = SingleUserCoalesced.to_messages([failed_turn], %{}, base_opts())

      assert String.contains?(user.content, "Test mission")
    end
  end

  describe "namespace rendering" do
    test "renders tool/ namespace when tools provided" do
      opts =
        base_opts()
        |> Keyword.put(:tools, %{"search" => make_tool("search", "(q :string) -> :string")})

      [_system, user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert String.contains?(user.content, ";; === tool/ ===")
      assert String.contains?(user.content, "tool/search")
    end

    test "renders data/ namespace when data provided" do
      opts = Keyword.put(base_opts(), :data, %{count: 42})
      [_system, user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert String.contains?(user.content, ";; === data/ ===")
      assert String.contains?(user.content, "data/count")
    end

    test "renders user/ namespace from accumulated memory" do
      memory = %{total: 100}
      [_system, user] = SingleUserCoalesced.to_messages([], memory, base_opts())

      assert String.contains?(user.content, ";; === user/ (your prelude) ===")
      assert String.contains?(user.content, "total")
    end
  end

  describe "execution history accumulation (CMP-001)" do
    test "accumulates tool_calls from successful turns" do
      turn1 =
        Turn.success(
          1,
          "raw",
          "(code)",
          :ok,
          [],
          [%{name: "search", args: %{q: "a"}, result: 1}],
          %{}
        )

      turn2 =
        Turn.success(
          2,
          "raw",
          "(code)",
          :ok,
          [],
          [%{name: "fetch", args: %{url: "b"}, result: 2}],
          %{}
        )

      [_system, user] = SingleUserCoalesced.to_messages([turn1, turn2], %{}, base_opts())

      assert String.contains?(user.content, ";; Tool calls made:")
      assert String.contains?(user.content, "search")
      assert String.contains?(user.content, "fetch")
    end

    test "shows no tool calls message when empty" do
      [_system, user] = SingleUserCoalesced.to_messages([], %{}, base_opts())

      assert String.contains?(user.content, ";; No tool calls made")
    end

    test "accumulates prints from successful turns when println tool exists" do
      opts =
        base_opts()
        |> Keyword.put(:tools, %{"println" => make_tool("println", "(msg :string) -> :nil")})

      turn1 = Turn.success(1, "raw", "(code)", :ok, ["line1"], [], %{})
      turn2 = Turn.success(2, "raw", "(code)", :ok, ["line2", "line3"], [], %{})

      [_system, user] = SingleUserCoalesced.to_messages([turn1, turn2], %{}, opts)

      assert String.contains?(user.content, ";; Output:")
      assert String.contains?(user.content, "line1")
      assert String.contains?(user.content, "line2")
      assert String.contains?(user.content, "line3")
    end

    test "skips output section when no println tool" do
      turn = Turn.success(1, "raw", "(code)", :ok, ["line1"], [], %{})
      [_system, user] = SingleUserCoalesced.to_messages([turn], %{}, base_opts())

      refute String.contains?(user.content, ";; Output:")
    end

    test "excludes tool_calls from failed turns" do
      success =
        Turn.success(1, "raw", "(code)", :ok, [], [%{name: "good", args: %{}, result: 1}], %{})

      failure =
        Turn.failure(
          2,
          "raw",
          "(bad)",
          %{message: "err"},
          [],
          [%{name: "bad", args: %{}, result: 2}],
          %{}
        )

      [_system, user] = SingleUserCoalesced.to_messages([success, failure], %{}, base_opts())

      assert String.contains?(user.content, "good")
      refute String.contains?(user.content, "bad(")
    end
  end

  describe "error conditional display (ERR-001 to ERR-005)" do
    test "shows error when last turn failed (ERR-002)" do
      failed = Turn.failure(1, "raw", "(/ 1 0)", %{message: "division by zero"}, [], [], %{})
      [_system, user] = SingleUserCoalesced.to_messages([failed], %{}, base_opts())

      assert String.contains?(user.content, "Your previous attempt:")
      assert String.contains?(user.content, "(/ 1 0)")
      assert String.contains?(user.content, "Error: division by zero")
    end

    test "collapses errors when recovered (ERR-003)" do
      failed = Turn.failure(1, "raw", "(bad)", %{message: "error"}, [], [], %{})
      success = Turn.success(2, "raw", "(good)", :ok, [], [], %{})

      [_system, user] = SingleUserCoalesced.to_messages([failed, success], %{}, base_opts())

      refute String.contains?(user.content, "Your previous attempt:")
      refute String.contains?(user.content, "Error:")
    end

    test "shows only most recent error when multiple failures" do
      fail1 = Turn.failure(1, "raw", "(first-bad)", %{message: "first error"}, [], [], %{})
      fail2 = Turn.failure(2, "raw", "(second-bad)", %{message: "second error"}, [], [], %{})

      [_system, user] = SingleUserCoalesced.to_messages([fail1, fail2], %{}, base_opts())

      refute String.contains?(user.content, "first-bad")
      refute String.contains?(user.content, "first error")
      assert String.contains?(user.content, "second-bad")
      assert String.contains?(user.content, "second error")
    end

    test "preserves successful turn data after failed turns (ERR-005)" do
      success =
        Turn.success(1, "raw", "(code)", :ok, [], [%{name: "tool1", args: %{}, result: 1}], %{})

      failed = Turn.failure(2, "raw", "(bad)", %{message: "error"}, [], [], %{})

      [_system, user] = SingleUserCoalesced.to_messages([success, failed], %{}, base_opts())

      # Tool call from success should be present
      assert String.contains?(user.content, "tool1")
      # Error from failure should be present
      assert String.contains?(user.content, "Error: error")
    end

    test "handles error with only reason" do
      failed = Turn.failure(1, "raw", "(bad)", %{reason: :timeout}, [], [], %{})
      [_system, user] = SingleUserCoalesced.to_messages([failed], %{}, base_opts())

      assert String.contains?(user.content, "Error: timeout")
    end

    test "handles string error" do
      failed = Turn.failure(1, "raw", "(bad)", "plain string error", [], [], %{})
      [_system, user] = SingleUserCoalesced.to_messages([failed], %{}, base_opts())

      assert String.contains?(user.content, "Error: plain string error")
    end

    test "handles nil program in error display" do
      failed = Turn.failure(1, "raw", nil, %{message: "parse error"}, [], [], %{})
      [_system, user] = SingleUserCoalesced.to_messages([failed], %{}, base_opts())

      assert String.contains?(user.content, "(unknown program)")
      assert String.contains?(user.content, "Error: parse error")
    end
  end

  describe "turns indicator (MSG-005)" do
    test "shows turns left when > 0" do
      opts = Keyword.put(base_opts(), :turns_left, 3)
      [_system, user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert String.contains?(user.content, "Turns left: 3")
    end

    test "shows final turn message when turns_left is 0" do
      opts = Keyword.put(base_opts(), :turns_left, 0)
      [_system, user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert String.contains?(
               user.content,
               "FINAL TURN - you must call (return result) or (fail reason) now."
             )
    end

    test "turns indicator appears at end of message" do
      opts = Keyword.put(base_opts(), :turns_left, 2)
      [_system, user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert String.ends_with?(user.content, "Turns left: 2")
    end
  end

  describe "FIFO limits (API-004, API-005)" do
    test "respects tool_call_limit" do
      tool_calls = for i <- 1..25, do: %{name: "tool#{i}", args: %{}, result: i}
      turn = Turn.success(1, "raw", "(code)", :ok, [], tool_calls, %{})

      opts = Keyword.put(base_opts(), :tool_call_limit, 5)
      [_system, user] = SingleUserCoalesced.to_messages([turn], %{}, opts)

      # Should only show last 5 (tools 21-25)
      refute String.contains?(user.content, "tool1(")
      refute String.contains?(user.content, "tool20(")
      assert String.contains?(user.content, "tool21")
      assert String.contains?(user.content, "tool25")
    end

    test "respects println_limit" do
      prints = for i <- 1..20, do: "line#{i}"
      turn = Turn.success(1, "raw", "(code)", :ok, prints, [], %{})

      opts =
        base_opts()
        |> Keyword.put(:println_limit, 5)
        |> Keyword.put(:tools, %{"println" => make_tool("println", "(msg :string) -> :nil")})

      [_system, user] = SingleUserCoalesced.to_messages([turn], %{}, opts)

      # Should only show last 5 (lines 16-20)
      refute String.contains?(user.content, "line1\n")
      refute String.contains?(user.content, "line15\n")
      assert String.contains?(user.content, "line16")
      assert String.contains?(user.content, "line20")
    end
  end

  describe "empty turns handling" do
    test "renders mission and namespaces with empty turns" do
      opts =
        base_opts()
        |> Keyword.put(:tools, %{"search" => make_tool("search", "-> :string")})
        |> Keyword.put(:data, %{val: 1})

      [_system, user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert String.contains?(user.content, "Test mission")
      assert String.contains?(user.content, ";; === tool/ ===")
      assert String.contains?(user.content, ";; === data/ ===")
    end
  end

  describe "expected output section" do
    test "includes Expected Output when signature is provided" do
      opts =
        base_opts()
        |> Keyword.put(:signature, "() -> {total :float}")

      [_system, user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert String.contains?(user.content, "# Expected Output")
      assert String.contains?(user.content, "{total :float}")
      assert String.contains?(user.content, "(return {:total 3.14})")
    end

    test "omits Expected Output when signature is nil" do
      opts = Keyword.put(base_opts(), :signature, nil)
      [_system, user] = SingleUserCoalesced.to_messages([], %{}, opts)

      refute String.contains?(user.content, "# Expected Output")
    end

    test "omits Expected Output when signature is missing from opts" do
      [_system, user] = SingleUserCoalesced.to_messages([], %{}, base_opts())

      refute String.contains?(user.content, "# Expected Output")
    end

    test "includes field descriptions in Expected Output when provided" do
      opts =
        base_opts()
        |> Keyword.put(:signature, "() -> {total :float}")
        |> Keyword.put(:field_descriptions, %{total: "The calculated total amount"})

      [_system, user] = SingleUserCoalesced.to_messages([], %{}, opts)

      assert String.contains?(user.content, "# Expected Output")
      assert String.contains?(user.content, "The calculated total amount")
    end
  end
end
