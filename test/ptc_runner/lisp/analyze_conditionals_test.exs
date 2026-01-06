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

    test "implicit do with multiple body expressions" do
      # (when true (println x) 42)
      raw =
        {:list,
         [
           {:symbol, :when},
           true,
           {:list, [{:symbol, :println}, {:symbol, :x}]},
           42
         ]}

      assert {:ok, {:if, true, {:do, [_, _]}, nil}} = Analyze.analyze(raw)
    end

    test "implicit do with three body expressions" do
      # (when true (def a 1) (def b 2) 42)
      raw =
        {:list,
         [
           {:symbol, :when},
           true,
           {:list, [{:symbol, :def}, {:symbol, :a}, 1]},
           {:list, [{:symbol, :def}, {:symbol, :b}, 2]},
           42
         ]}

      assert {:ok, {:if, true, {:do, [_, _, _]}, nil}} = Analyze.analyze(raw)
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

  describe "if-not special form" do
    test "if-not with then and else" do
      # (if-not true 1 2) -> (if true 2 1)
      raw = {:list, [{:symbol, :"if-not"}, true, 1, 2]}
      assert {:ok, {:if, true, 2, 1}} = Analyze.analyze(raw)
    end

    test "if-not with only then" do
      # (if-not true 1) -> (if true nil 1)
      raw = {:list, [{:symbol, :"if-not"}, true, 1]}
      assert {:ok, {:if, true, nil, 1}} = Analyze.analyze(raw)
    end

    test "if-not with expression" do
      # (if-not (= 1 1) "no" "yes") -> (if (= 1 1) "yes" "no")
      raw =
        {:list,
         [{:symbol, :"if-not"}, {:list, [{:symbol, :=}, 1, 1]}, {:string, "no"}, {:string, "yes"}]}

      assert {:ok, {:if, {:call, {:var, :=}, [1, 1]}, {:string, "yes"}, {:string, "no"}}} =
               Analyze.analyze(raw)
    end

    test "error case: if-not too many args" do
      raw = {:list, [{:symbol, :"if-not"}, true, 1, 2, 3]}
      assert {:error, {:invalid_arity, :"if-not", _}} = Analyze.analyze(raw)
    end

    test "error case: if-not too few args" do
      raw = {:list, [{:symbol, :"if-not"}, true]}
      assert {:error, {:invalid_arity, :"if-not", _}} = Analyze.analyze(raw)
    end
  end

  describe "when-not special form" do
    test "when-not with truthy condition" do
      # (when-not true 1) -> (if true nil 1)
      raw = {:list, [{:symbol, :"when-not"}, true, 1]}
      assert {:ok, {:if, true, nil, 1}} = Analyze.analyze(raw)
    end

    test "when-not with falsy condition" do
      # (when-not false 1) -> (if false nil 1)
      raw = {:list, [{:symbol, :"when-not"}, false, 1]}
      assert {:ok, {:if, false, nil, 1}} = Analyze.analyze(raw)
    end

    test "when-not with multiple body expressions" do
      # (when-not false (println 1) 2) -> (if false nil (do (println 1) 2))
      raw = {:list, [{:symbol, :"when-not"}, false, {:list, [{:symbol, :println}, 1]}, 2]}
      assert {:ok, {:if, false, nil, {:do, [_, _]}}} = Analyze.analyze(raw)
    end

    test "error case: when-not too few args" do
      raw = {:list, [{:symbol, :"when-not"}, true]}
      assert {:error, {:invalid_arity, :"when-not", _}} = Analyze.analyze(raw)
    end
  end
end
