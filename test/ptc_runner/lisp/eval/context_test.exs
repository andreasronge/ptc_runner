defmodule PtcRunner.Lisp.Eval.ContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval.Context

  doctest PtcRunner.Lisp.Eval.Context

  describe "append_tool_call/2" do
    test "accumulates tool calls in reverse order" do
      ctx = Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [])

      tool_call_1 = %{
        name: "add",
        args: %{a: 1, b: 2},
        result: 3,
        error: nil,
        timestamp: DateTime.utc_now(),
        duration_ms: 5
      }

      tool_call_2 = %{
        name: "multiply",
        args: %{a: 3, b: 4},
        result: 12,
        error: nil,
        timestamp: DateTime.utc_now(),
        duration_ms: 3
      }

      ctx = Context.append_tool_call(ctx, tool_call_1)
      ctx = Context.append_tool_call(ctx, tool_call_2)

      # Tool calls are prepended (most recent first)
      assert [^tool_call_2, ^tool_call_1] = ctx.tool_calls
    end

    test "starts with empty tool_calls list" do
      ctx = Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [])
      assert ctx.tool_calls == []
    end
  end
end
