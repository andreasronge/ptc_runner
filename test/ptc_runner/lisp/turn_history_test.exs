defmodule PtcRunner.Lisp.TurnHistoryTest do
  @moduledoc """
  Tests for turn history access via *1, *2, *3 symbols.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.{Analyze, AST, Eval}

  import PtcRunner.TestSupport.TestHelpers

  describe "AST parsing" do
    test "*1 parses to turn_history tuple" do
      assert AST.symbol("*1") == {:turn_history, 1}
    end

    test "*2 parses to turn_history tuple" do
      assert AST.symbol("*2") == {:turn_history, 2}
    end

    test "*3 parses to turn_history tuple" do
      assert AST.symbol("*3") == {:turn_history, 3}
    end

    test "other *N symbols parse as regular symbols" do
      assert AST.symbol("*4") == {:symbol, :"*4"}
      assert AST.symbol("*0") == {:symbol, :"*0"}
      assert AST.symbol("*foo") == {:symbol, :"*foo"}
    end
  end

  describe "Analyze" do
    test "turn history symbols analyze correctly" do
      assert {:ok, {:turn_history, 1}} = Analyze.analyze({:turn_history, 1})
      assert {:ok, {:turn_history, 2}} = Analyze.analyze({:turn_history, 2})
      assert {:ok, {:turn_history, 3}} = Analyze.analyze({:turn_history, 3})
    end
  end

  describe "Eval" do
    test "*1 returns most recent turn result" do
      history = ["first", "second", "third"]
      {:ok, result, _} = Eval.eval({:turn_history, 1}, %{}, %{}, %{}, &dummy_tool/2, history)
      assert result == "third"
    end

    test "*2 returns second-most-recent turn result" do
      history = ["first", "second", "third"]
      {:ok, result, _} = Eval.eval({:turn_history, 2}, %{}, %{}, %{}, &dummy_tool/2, history)
      assert result == "second"
    end

    test "*3 returns third-most-recent turn result" do
      history = ["first", "second", "third"]
      {:ok, result, _} = Eval.eval({:turn_history, 3}, %{}, %{}, %{}, &dummy_tool/2, history)
      assert result == "first"
    end

    test "*1 returns nil when history is empty" do
      {:ok, result, _} = Eval.eval({:turn_history, 1}, %{}, %{}, %{}, &dummy_tool/2, [])
      assert result == nil
    end

    test "*2 returns nil when history has only 1 entry" do
      {:ok, result, _} = Eval.eval({:turn_history, 2}, %{}, %{}, %{}, &dummy_tool/2, ["only"])
      assert result == nil
    end

    test "*3 returns nil when history has only 2 entries" do
      history = ["first", "second"]
      {:ok, result, _} = Eval.eval({:turn_history, 3}, %{}, %{}, %{}, &dummy_tool/2, history)
      assert result == nil
    end

    test "turn history works with complex values" do
      history = [%{foo: 1}, [1, 2, 3], %{bar: "baz"}]
      {:ok, result1, _} = Eval.eval({:turn_history, 1}, %{}, %{}, %{}, &dummy_tool/2, history)
      {:ok, result2, _} = Eval.eval({:turn_history, 2}, %{}, %{}, %{}, &dummy_tool/2, history)
      {:ok, result3, _} = Eval.eval({:turn_history, 3}, %{}, %{}, %{}, &dummy_tool/2, history)

      assert result1 == %{bar: "baz"}
      assert result2 == [1, 2, 3]
      assert result3 == %{foo: 1}
    end
  end

  describe "Lisp.run integration" do
    test "turn history accessible via *1" do
      history = [10, 20, 30]
      {:ok, step} = Lisp.run("*1", turn_history: history)
      assert step.return == 30
    end

    test "turn history accessible via *2" do
      history = [10, 20, 30]
      {:ok, step} = Lisp.run("*2", turn_history: history)
      assert step.return == 20
    end

    test "turn history accessible via *3" do
      history = [10, 20, 30]
      {:ok, step} = Lisp.run("*3", turn_history: history)
      assert step.return == 10
    end

    test "turn history is nil when not available" do
      {:ok, step} = Lisp.run("*1", turn_history: [])
      assert step.return == nil
    end

    test "turn history works in expressions" do
      history = [5, 10]
      {:ok, step} = Lisp.run("(+ *1 *2)", turn_history: history)
      assert step.return == 15
    end

    test "turn history works with nil checks" do
      {:ok, step} = Lisp.run("(if *1 *1 42)", turn_history: [])
      assert step.return == 42

      {:ok, step2} = Lisp.run("(if *1 *1 42)", turn_history: [100])
      assert step2.return == 100
    end

    test "defaults to empty history when not provided" do
      {:ok, step} = Lisp.run("*1")
      assert step.return == nil
    end
  end
end
