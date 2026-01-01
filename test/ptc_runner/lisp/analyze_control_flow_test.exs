defmodule PtcRunner.Lisp.AnalyzeControlFlowTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "(return value) syntactic sugar" do
    test "desugars to call_tool for return" do
      raw = {:list, [{:symbol, :return}, {:map, [{{:keyword, :result}, 42}]}]}

      assert {:ok, {:call_tool, "return", {:map, [{{:keyword, :result}, 42}]}}} =
               Analyze.analyze(raw)
    end

    test "return with expression value" do
      raw = {:list, [{:symbol, :return}, {:list, [{:symbol, :+}, 1, 2]}]}
      assert {:ok, {:call_tool, "return", {:call, {:var, :+}, [1, 2]}}} = Analyze.analyze(raw)
    end

    test "return with variable" do
      raw = {:list, [{:symbol, :return}, {:symbol, :x}]}
      assert {:ok, {:call_tool, "return", {:var, :x}}} = Analyze.analyze(raw)
    end

    test "return without argument fails" do
      raw = {:list, [{:symbol, :return}]}
      assert {:error, {:invalid_arity, :return, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (return value)"
    end

    test "return with too many arguments fails" do
      raw = {:list, [{:symbol, :return}, 1, 2]}
      assert {:error, {:invalid_arity, :return, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (return value)"
    end
  end

  describe "(fail error) syntactic sugar" do
    test "desugars to call_tool for fail" do
      raw = {:list, [{:symbol, :fail}, {:map, [{{:keyword, :reason}, {:keyword, :bad}}]}]}

      assert {:ok, {:call_tool, "fail", {:map, [{{:keyword, :reason}, {:keyword, :bad}}]}}} =
               Analyze.analyze(raw)
    end

    test "fail with expression value" do
      raw =
        {:list,
         [{:symbol, :fail}, {:list, [{:symbol, :str}, {:string, "error: "}, {:symbol, :x}]}]}

      assert {:ok,
              {:call_tool, "fail", {:call, {:var, :str}, [{:string, "error: "}, {:var, :x}]}}} =
               Analyze.analyze(raw)
    end

    test "fail with variable" do
      raw = {:list, [{:symbol, :fail}, {:symbol, :err}]}
      assert {:ok, {:call_tool, "fail", {:var, :err}}} = Analyze.analyze(raw)
    end

    test "fail without argument fails" do
      raw = {:list, [{:symbol, :fail}]}
      assert {:error, {:invalid_arity, :fail, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (fail error)"
    end

    test "fail with too many arguments fails" do
      raw = {:list, [{:symbol, :fail}, 1, 2]}
      assert {:error, {:invalid_arity, :fail, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (fail error)"
    end
  end
end
