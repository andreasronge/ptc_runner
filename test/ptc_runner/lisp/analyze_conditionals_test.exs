defmodule PtcRunner.Lisp.AnalyzeConditionalsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "when desugars to if" do
    test "when becomes if with nil else" do
      raw = {:list, [{:symbol, :when}, true, 42]}
      assert {:ok, {:if, true, 42, nil}} = Analyze.analyze(raw)
    end

    test "when with symbol condition" do
      raw = {:list, [{:symbol, :when}, {:symbol, :check}, 100]}
      assert {:ok, {:if, {:var, :check}, 100, nil}} = Analyze.analyze(raw)
    end

    test "when with complex body" do
      raw = {:list, [{:symbol, :when}, true, {:list, [{:symbol, :+}, 1, 2]}]}
      assert {:ok, {:if, true, {:call, {:var, :+}, [1, 2]}, nil}} = Analyze.analyze(raw)
    end

    test "when with wrong arity fails" do
      raw = {:list, [{:symbol, :when}, true]}
      assert {:error, {:invalid_arity, :when, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end
  end

  describe "cond desugars to nested if" do
    test "simple cond" do
      raw =
        {:list,
         [
           {:symbol, :cond},
           {:symbol, :a},
           1,
           {:symbol, :b},
           2,
           {:keyword, :else},
           3
         ]}

      assert {:ok, {:if, {:var, :a}, 1, {:if, {:var, :b}, 2, 3}}} = Analyze.analyze(raw)
    end

    test "cond without else clause defaults to nil" do
      raw =
        {:list,
         [
           {:symbol, :cond},
           true,
           42,
           false,
           99
         ]}

      assert {:ok, {:if, true, 42, {:if, false, 99, nil}}} = Analyze.analyze(raw)
    end

    test "cond with single pair" do
      raw =
        {:list,
         [
           {:symbol, :cond},
           {:symbol, :x},
           100
         ]}

      assert {:ok, {:if, {:var, :x}, 100, nil}} = Analyze.analyze(raw)
    end

    test "cond empty fails" do
      raw = {:list, [{:symbol, :cond}]}
      assert {:error, {:invalid_cond_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "at least one"
    end

    test "cond with odd pairs fails" do
      raw =
        {:list,
         [
           {:symbol, :cond},
           true,
           1,
           false
         ]}

      assert {:error, {:invalid_cond_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "even number"
    end
  end

  describe "if special form" do
    test "basic if-then-else" do
      raw = {:list, [{:symbol, :if}, true, 1, 2]}
      assert {:ok, {:if, true, 1, 2}} = Analyze.analyze(raw)
    end

    test "if with expression condition" do
      raw =
        {:list,
         [
           {:symbol, :if},
           {:list, [{:symbol, :<}, {:symbol, :x}, 10]},
           {:string, "small"},
           {:string, "large"}
         ]}

      assert {:ok,
              {:if, {:call, {:var, :<}, [{:var, :x}, 10]}, {:string, "small"}, {:string, "large"}}} =
               Analyze.analyze(raw)
    end

    test "error case: wrong arity - too few arguments" do
      raw = {:list, [{:symbol, :if}, true]}
      assert {:error, {:invalid_arity, :if, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error case: wrong arity - too many arguments" do
      raw = {:list, [{:symbol, :if}, true, 1, 2, 3]}
      assert {:error, {:invalid_arity, :if, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end
  end
end
