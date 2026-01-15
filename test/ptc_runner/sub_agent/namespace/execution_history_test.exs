defmodule PtcRunner.SubAgent.Namespace.ExecutionHistoryTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.SubAgent.Namespace.ExecutionHistory

  alias PtcRunner.SubAgent.Namespace.ExecutionHistory

  describe "render_tool_calls/2" do
    test "returns no tool calls message for empty list" do
      assert ExecutionHistory.render_tool_calls([], 20) == ";; No tool calls made"
    end

    test "renders single tool call" do
      calls = [%{name: "search", args: %{query: "hello"}}]
      result = ExecutionHistory.render_tool_calls(calls, 20)

      assert result == ";; Tool calls made:\n;   search({:query \"hello\"})"
    end

    test "renders multiple tool calls in order" do
      calls = [
        %{name: "first", args: %{a: 1}},
        %{name: "second", args: %{b: 2}},
        %{name: "third", args: %{c: 3}}
      ]

      result = ExecutionHistory.render_tool_calls(calls, 20)
      lines = String.split(result, "\n")

      assert Enum.at(lines, 0) == ";; Tool calls made:"
      assert Enum.at(lines, 1) == ";   first({:a 1})"
      assert Enum.at(lines, 2) == ";   second({:b 2})"
      assert Enum.at(lines, 3) == ";   third({:c 3})"
    end

    test "FIFO keeps most recent when limit exceeded" do
      calls = [
        %{name: "oldest", args: %{}},
        %{name: "middle", args: %{}},
        %{name: "newest", args: %{}}
      ]

      result = ExecutionHistory.render_tool_calls(calls, 2)
      lines = String.split(result, "\n")

      assert length(lines) == 3
      assert Enum.at(lines, 0) == ";; Tool calls made:"
      # oldest is dropped, middle and newest kept
      assert Enum.at(lines, 1) == ";   middle({})"
      assert Enum.at(lines, 2) == ";   newest({})"
    end

    test "truncates complex args using Format.to_clojure" do
      calls = [
        %{name: "analyze", args: %{data: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]}}
      ]

      result = ExecutionHistory.render_tool_calls(calls, 20)

      # Should show truncation indicator from Format.to_clojure
      assert result =~ ";   analyze"
      assert result =~ "..."
      assert result =~ "10 items"
    end

    test "ignores extra fields in tool call maps" do
      calls = [
        %{
          name: "search",
          args: %{q: "test"},
          result: "ignored",
          error: nil,
          timestamp: ~U[2024-01-01 00:00:00Z],
          duration_ms: 100
        }
      ]

      result = ExecutionHistory.render_tool_calls(calls, 20)

      # Only name and args used in rendering
      assert result == ";; Tool calls made:\n;   search({:q \"test\"})"
    end

    test "hides values for underscore-prefixed arg keys" do
      calls = [%{name: "api_call", args: %{_token: "secret123", query: "data"}}]
      result = ExecutionHistory.render_tool_calls(calls, 20)

      # Hidden value should be replaced with "[Hidden]" (quoted string in Clojure format)
      assert result =~ ":_token \"[Hidden]\""
      # Non-hidden value should be shown
      assert result =~ ":query \"data\""
      # Secret value should NOT appear
      refute result =~ "secret123"
    end

    test "hides multiple underscore-prefixed args" do
      # Use only 2 args to avoid truncation (limit: 3 in format, but maps may show less)
      calls = [%{name: "auth", args: %{_key: "key123", user: "alice"}}]
      result = ExecutionHistory.render_tool_calls(calls, 20)

      assert result =~ ":_key \"[Hidden]\""
      assert result =~ ":user \"alice\""
      refute result =~ "key123"
    end

    test "handles all hidden args" do
      calls = [%{name: "secret_call", args: %{_a: 1, _b: 2}}]
      result = ExecutionHistory.render_tool_calls(calls, 20)

      assert result =~ ":_a \"[Hidden]\""
      assert result =~ ":_b \"[Hidden]\""
      refute result =~ ":_a 1"
      refute result =~ ":_b 2"
    end
  end

  describe "render_output/3" do
    test "returns nil when has_println is false" do
      assert ExecutionHistory.render_output([], 15, false) == nil
      assert ExecutionHistory.render_output(["hello"], 15, false) == nil
    end

    test "returns header only for empty prints with has_println true" do
      result = ExecutionHistory.render_output([], 15, true)
      assert result == ";; Output:"
    end

    test "renders single print line" do
      result = ExecutionHistory.render_output(["hello"], 15, true)
      assert result == ";; Output:\nhello"
    end

    test "renders multiple print lines without prefix" do
      result = ExecutionHistory.render_output(["hello", "world", "test"], 15, true)

      assert result == ";; Output:\nhello\nworld\ntest"
    end

    test "FIFO keeps most recent when limit exceeded" do
      prints = ["oldest", "middle", "newest"]
      result = ExecutionHistory.render_output(prints, 2, true)

      # oldest is dropped, middle and newest kept
      assert result == ";; Output:\nmiddle\nnewest"
    end

    test "preserves original formatting in output lines" do
      prints = ["  indented", "UPPERCASE", "with:special:chars"]
      result = ExecutionHistory.render_output(prints, 15, true)

      lines = String.split(result, "\n")
      assert Enum.at(lines, 1) == "  indented"
      assert Enum.at(lines, 2) == "UPPERCASE"
      assert Enum.at(lines, 3) == "with:special:chars"
    end
  end
end
