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

  describe "case desugars to let + nested if" do
    test "basic single-clause case with keyword" do
      # (case :a :a 1)
      raw = {:list, [{:symbol, :case}, {:keyword, :a}, {:keyword, :a}, 1]}

      assert {:ok, {:let, [{:binding, {:var, _}, {:keyword, :a}}], {:if, _, 1, nil}}} =
               Analyze.analyze(raw)
    end

    test "multiple clauses" do
      # (case :b :a 1 :b 2)
      raw = {:list, [{:symbol, :case}, {:keyword, :b}, {:keyword, :a}, 1, {:keyword, :b}, 2]}
      assert {:ok, {:let, _, {:if, _, 1, {:if, _, 2, nil}}}} = Analyze.analyze(raw)
    end

    test "grouped values" do
      # (case :b (:a :b) 1)
      raw =
        {:list,
         [
           {:symbol, :case},
           {:keyword, :b},
           {:list, [{:keyword, :a}, {:keyword, :b}]},
           1
         ]}

      assert {:ok, {:let, _, {:if, {:or, [_, _]}, 1, nil}}} = Analyze.analyze(raw)
    end

    test "trailing default (bare expression)" do
      # (case :z :a 1 "default")
      raw = {:list, [{:symbol, :case}, {:keyword, :z}, {:keyword, :a}, 1, {:string, "default"}]}

      assert {:ok, {:let, _, {:if, _, 1, {:string, "default"}}}} = Analyze.analyze(raw)
    end

    test "no default desugars with nil" do
      # (case :z :a 1 :b 2)
      raw = {:list, [{:symbol, :case}, {:keyword, :z}, {:keyword, :a}, 1, {:keyword, :b}, 2]}
      assert {:ok, {:let, _, {:if, _, 1, {:if, _, 2, nil}}}} = Analyze.analyze(raw)
    end

    test "error: no arguments" do
      raw = {:list, [{:symbol, :case}]}

      assert {:error, {:invalid_form, "case requires at least an expression to test"}} =
               Analyze.analyze(raw)
    end

    test "error: non-literal test value (symbol)" do
      # (case :a x 1)
      raw = {:list, [{:symbol, :case}, {:keyword, :a}, {:symbol, :x}, 1]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "compile-time constants"
    end

    test "error: non-literal test value (function call)" do
      # (case :a (foo) 1)
      raw = {:list, [{:symbol, :case}, {:keyword, :a}, {:list, [{:symbol, :foo}]}, 1]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "compile-time constants"
    end

    test "string and number test values" do
      # (case 42 "x" 1 42 2)
      raw = {:list, [{:symbol, :case}, 42, {:string, "x"}, 1, 42, 2]}
      assert {:ok, {:let, _, {:if, _, 1, {:if, _, 2, nil}}}} = Analyze.analyze(raw)
    end

    test "nil as a valid test value" do
      # (case nil nil "matched")
      raw = {:list, [{:symbol, :case}, nil, nil, {:string, "matched"}]}
      assert {:ok, {:let, _, {:if, _, {:string, "matched"}, nil}}} = Analyze.analyze(raw)
    end

    test "true/false as test values" do
      # (case true true "yes" false "no")
      raw = {:list, [{:symbol, :case}, true, true, {:string, "yes"}, false, {:string, "no"}]}

      assert {:ok, {:let, _, {:if, _, {:string, "yes"}, {:if, _, {:string, "no"}, nil}}}} =
               Analyze.analyze(raw)
    end

    test "expression-only case returns nil" do
      # (case :a) — just the expression, no clauses
      raw = {:list, [{:symbol, :case}, {:keyword, :a}]}
      assert {:ok, {:let, _, nil}} = Analyze.analyze(raw)
    end
  end

  describe "condp desugars to let + nested if with predicate calls" do
    test "basic condp = with keyword tests" do
      # (condp = :a :a 1 :b 2)
      raw =
        {:list,
         [{:symbol, :condp}, {:symbol, :=}, {:keyword, :a}, {:keyword, :a}, 1, {:keyword, :b}, 2]}

      assert {:ok, {:let, [{:binding, _, _}, {:binding, _, _}], {:if, _, 1, {:if, _, 2, nil}}}} =
               Analyze.analyze(raw)
    end

    test "condp > with number tests" do
      # (condp > 5 10 "big" 3 "small")
      raw =
        {:list,
         [
           {:symbol, :condp},
           {:symbol, :>},
           5,
           10,
           {:string, "big"},
           3,
           {:string, "small"}
         ]}

      assert {:ok, {:let, _, {:if, _, {:string, "big"}, {:if, _, {:string, "small"}, nil}}}} =
               Analyze.analyze(raw)
    end

    test "trailing default" do
      # (condp = :z :a 1 "default")
      raw =
        {:list,
         [
           {:symbol, :condp},
           {:symbol, :=},
           {:keyword, :z},
           {:keyword, :a},
           1,
           {:string, "default"}
         ]}

      assert {:ok, {:let, _, {:if, _, 1, {:string, "default"}}}} = Analyze.analyze(raw)
    end

    test "no default desugars with nil" do
      # (condp = :z :a 1 :b 2)
      raw =
        {:list,
         [{:symbol, :condp}, {:symbol, :=}, {:keyword, :z}, {:keyword, :a}, 1, {:keyword, :b}, 2]}

      assert {:ok, {:let, _, {:if, _, 1, {:if, _, 2, nil}}}} = Analyze.analyze(raw)
    end

    test "error: fewer than 3 args" do
      raw = {:list, [{:symbol, :condp}, {:symbol, :=}]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "condp requires a predicate"
    end

    test "error: :>> in clauses" do
      # (condp = :a :a :>> inc)
      arrow_kw = {:keyword, String.to_atom(">>")}

      raw =
        {:list,
         [
           {:symbol, :condp},
           {:symbol, :=},
           {:keyword, :a},
           {:keyword, :a},
           arrow_kw,
           {:symbol, :inc}
         ]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "result-fn form is not supported"
    end

    test "error: 0 clauses (just pred + expr)" do
      # (condp = :a) — no clauses at all
      raw = {:list, [{:symbol, :condp}, {:symbol, :=}, {:keyword, :a}]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "condp requires a predicate"
    end

    test "error: default-only (no clause pairs)" do
      # (condp = :a "default") — 1 clause arg = default only, no test/result pairs
      raw =
        {:list, [{:symbol, :condp}, {:symbol, :=}, {:keyword, :a}, {:string, "default"}]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "at least one test/result clause pair"
    end

    test ":>> keyword as test value (not in result position) is allowed" do
      # (condp = :a :>> 1 :b 2) — :>> is the test value, not result-fn syntax
      arrow_kw = {:keyword, String.to_atom(">>")}

      raw =
        {:list,
         [{:symbol, :condp}, {:symbol, :=}, {:keyword, :a}, arrow_kw, 1, {:keyword, :b}, 2]}

      assert {:ok, {:let, _, _}} = Analyze.analyze(raw)
    end
  end

  describe "case edge cases for grouped matches" do
    test "error: empty group" do
      # (case :a () 1)
      raw = {:list, [{:symbol, :case}, {:keyword, :a}, {:list, []}, 1]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "at least one value"
    end

    test "error: nested group" do
      # (case :a ((:a :b)) 1) — nested list inside group
      raw =
        {:list,
         [
           {:symbol, :case},
           {:keyword, :a},
           {:list, [{:list, [{:keyword, :a}, {:keyword, :b}]}]},
           1
         ]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "compile-time constants"
    end
  end
end
