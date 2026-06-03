defmodule PtcRunner.ToolExecutionErrorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.ToolExecutionError

  describe "exception/1 — map arm" do
    test "carries message, eval_ctx and tool_name from a map" do
      ctx = %{tool_calls: [%{name: "search", error: "boom"}]}

      err =
        ToolExecutionError.exception(%{
          message: "tool blew up",
          eval_ctx: ctx,
          tool_name: "search"
        })

      assert %ToolExecutionError{} = err
      assert err.message == "tool blew up"
      assert err.eval_ctx == ctx
      assert err.tool_name == "search"
    end

    test "falls back to default message when map omits :message" do
      err = ToolExecutionError.exception(%{tool_name: "fetch", eval_ctx: nil})

      assert err.message == "Tool execution failed"
      assert err.tool_name == "fetch"
      assert err.eval_ctx == nil
    end
  end

  describe "exception/1 — keyword arm" do
    test "carries message, eval_ctx and tool_name from a keyword list" do
      ctx = %{tool_calls: []}

      err =
        ToolExecutionError.exception(
          message: "kw failure",
          eval_ctx: ctx,
          tool_name: "list_emails"
        )

      assert err.message == "kw failure"
      assert err.eval_ctx == ctx
      assert err.tool_name == "list_emails"
    end

    test "falls back to default message when keyword list omits :message" do
      err = ToolExecutionError.exception(tool_name: "noop")

      assert err.message == "Tool execution failed"
      assert err.tool_name == "noop"
      assert err.eval_ctx == nil
    end
  end

  describe "exception/1 — binary arm" do
    test "wraps a bare string with nil eval_ctx and tool_name" do
      err = ToolExecutionError.exception("plain string failure")

      assert err.message == "plain string failure"
      assert err.eval_ctx == nil
      assert err.tool_name == nil
    end
  end

  describe "raise/rescue round-trip" do
    test "Exception.message/1 reflects the raised message and eval_ctx survives" do
      ctx = %{tool_calls: [%{name: "billing", error: "402"}], prints: ["log"]}

      err =
        try do
          raise ToolExecutionError,
            message: "payment declined",
            eval_ctx: ctx,
            tool_name: "billing"
        rescue
          e in ToolExecutionError -> e
        end

      assert Exception.message(err) == "payment declined"
      # The whole point of this exception: the eval context (recorded tool_calls)
      # is carried across the raise boundary so traces are not lost.
      assert err.eval_ctx == ctx
      assert err.eval_ctx.tool_calls == [%{name: "billing", error: "402"}]
      assert err.tool_name == "billing"
    end

    test "raising with a bare string message round-trips" do
      err =
        try do
          raise ToolExecutionError, "bare message"
        rescue
          e in ToolExecutionError -> e
        end

      assert Exception.message(err) == "bare message"
      assert err.eval_ctx == nil
      assert err.tool_name == nil
    end
  end

  describe "real PTC-Lisp path — a failing tool surfaces the carried eval_ctx" do
    test "tool that raises produces a :tool_error Step whose tool_calls are preserved" do
      # Drives lib/ptc_runner/lisp/eval.ex record_tool_call_execute -> raise
      # PtcRunner.ToolExecutionError, which lisp.ex rescues into a Step carrying
      # the failed call. This exercises the exception end-to-end through the
      # production evaluator, not just the constructor.
      tools = %{
        "explode" => fn _args -> raise "kaboom from tool" end
      }

      {:error, step} = PtcRunner.Lisp.run(~S|(tool/explode {:x 1})|, tools: tools)

      assert step.fail.reason == :tool_error
      assert step.fail.message =~ "explode"
      assert step.fail.message =~ "kaboom from tool"

      # eval_ctx carried through the exception means the failed call was recorded.
      assert [%{name: "explode"} = call] = step.tool_calls
      assert call.args == %{"x" => 1}
      assert call.error =~ "kaboom from tool"
      assert call.result == nil
    end
  end
end
