defmodule PtcRunner.Lisp.EvalDescribeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "describe in PTC-Lisp programs" do
    test "summarizes vectors of maps" do
      source = ~S|(describe [{"event" "turn"} {"event" "done" "ok" true}])|

      assert {:ok, %{return: result}} = Lisp.run(source)

      assert result[:type] == "vector"
      assert result[:count] == 2
      assert result[:scanned] == 2
      assert result[:keys]["event"][:present] == 2
      assert result[:keys]["ok"][:pct] == 50.0
    end

    test "accepts path options" do
      source = ~S|(describe [{"data" {"tool_calls" [1]}}] {:paths true :depth 2})|

      assert {:ok, %{return: result}} = Lisp.run(source)

      assert result[:paths]["data.tool_calls"][:types] == %{"vector" => 1}
    end

    test "does not register a desc alias" do
      assert {:error, %{fail: %{message: msg}}} = Lisp.run(~S|(desc [1 2 3])|)

      assert msg =~ "Undefined variable: desc"
      refute msg =~ "desc is"
    end
  end
end
