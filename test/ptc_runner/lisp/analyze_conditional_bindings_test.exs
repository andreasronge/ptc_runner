defmodule PtcRunner.Lisp.AnalyzeConditionalBindingsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "if-let special form" do
    test "if-let desugars to let wrapping if" do
      raw = {:list, [{:symbol, :"if-let"}, {:vector, [{:symbol, :x}, 42]}, {:symbol, :x}, 0]}

      assert {:ok, {:let, [{:binding, {:var, :x}, 42}], {:if, {:var, :x}, {:var, :x}, 0}}} =
               Analyze.analyze(raw)
    end

    test "if-let with expression condition" do
      raw =
        {:list,
         [
           {:symbol, :"if-let"},
           {:vector, [{:symbol, :user}, {:list, [{:symbol, :call}, {:string, "find"}]}]},
           {:symbol, :user},
           {:string, "not found"}
         ]}

      assert {:ok,
              {:let, [{:binding, {:var, :user}, {:call_tool, "find", {:map, []}}}],
               {:if, {:var, :user}, {:var, :user}, {:string, "not found"}}}} =
               Analyze.analyze(raw)
    end

    test "error: if-let with wrong arity (missing else)" do
      raw = {:list, [{:symbol, :"if-let"}, {:vector, [{:symbol, :x}, 1]}, {:symbol, :x}]}
      assert {:error, {:invalid_arity, :"if-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error: if-let with multiple bindings" do
      raw =
        {:list,
         [{:symbol, :"if-let"}, {:vector, [{:symbol, :x}, 1, {:symbol, :y}, 2]}, :ok, :err]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "one binding"
    end

    test "error: if-let with destructuring pattern" do
      raw =
        {:list,
         [
           {:symbol, :"if-let"},
           {:vector, [{:map, [{{:keyword, :keys}, {:vector, [{:symbol, :a}]}}]}, {:map, []}]},
           :ok,
           :err
         ]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "simple symbol"
    end

    test "error: if-let with non-vector binding" do
      raw = {:list, [{:symbol, :"if-let"}, {:symbol, :x}, {:symbol, :x}, 0]}
      assert {:error, {:invalid_arity, :"if-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error: if-let with empty vector" do
      raw = {:list, [{:symbol, :"if-let"}, {:vector, []}, {:symbol, :x}, 0]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "one binding"
    end
  end

  describe "when-let special form" do
    test "when-let desugars to let wrapping if with nil else" do
      raw = {:list, [{:symbol, :"when-let"}, {:vector, [{:symbol, :x}, 42]}, {:symbol, :x}]}

      assert {:ok, {:let, [{:binding, {:var, :x}, 42}], {:if, {:var, :x}, {:var, :x}, nil}}} =
               Analyze.analyze(raw)
    end

    test "when-let with expression condition" do
      raw =
        {:list,
         [
           {:symbol, :"when-let"},
           {:vector, [{:symbol, :user}, {:list, [{:symbol, :call}, {:string, "find"}]}]},
           {:list, [{:symbol, :upper}, {:symbol, :user}]}
         ]}

      assert {:ok,
              {:let, [{:binding, {:var, :user}, {:call_tool, "find", {:map, []}}}],
               {:if, {:var, :user}, {:call, {:var, :upper}, [{:var, :user}]}, nil}}} =
               Analyze.analyze(raw)
    end

    test "error: when-let with wrong arity (missing body)" do
      raw = {:list, [{:symbol, :"when-let"}, {:vector, [{:symbol, :x}, 1]}]}
      assert {:error, {:invalid_arity, :"when-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error: when-let with multiple bindings" do
      raw =
        {:list, [{:symbol, :"when-let"}, {:vector, [{:symbol, :x}, 1, {:symbol, :y}, 2]}, :ok]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "one binding"
    end

    test "error: when-let with destructuring pattern" do
      raw =
        {:list,
         [
           {:symbol, :"when-let"},
           {:vector, [{:vector, [{:symbol, :a}]}, {:vector, []}]},
           :ok
         ]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "simple symbol"
    end

    test "error: when-let with non-vector binding" do
      raw = {:list, [{:symbol, :"when-let"}, {:symbol, :x}, {:symbol, :x}]}
      assert {:error, {:invalid_arity, :"when-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error: when-let with empty vector" do
      raw = {:list, [{:symbol, :"when-let"}, {:vector, []}, {:symbol, :x}]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "one binding"
    end

    test "implicit do with multiple body expressions" do
      # (when-let [x 42] (println x) x)
      raw =
        {:list,
         [
           {:symbol, :"when-let"},
           {:vector, [{:symbol, :x}, 42]},
           {:list, [{:symbol, :println}, {:symbol, :x}]},
           {:symbol, :x}
         ]}

      assert {:ok, {:let, [{:binding, {:var, :x}, 42}], {:if, {:var, :x}, {:do, [_, _]}, nil}}} =
               Analyze.analyze(raw)
    end

    test "implicit do with three body expressions" do
      # (when-let [x 42] (def a x) (def b x) x)
      raw =
        {:list,
         [
           {:symbol, :"when-let"},
           {:vector, [{:symbol, :x}, 42]},
           {:list, [{:symbol, :def}, {:symbol, :a}, {:symbol, :x}]},
           {:list, [{:symbol, :def}, {:symbol, :b}, {:symbol, :x}]},
           {:symbol, :x}
         ]}

      assert {:ok, {:let, _, {:if, _, {:do, [_, _, _]}, nil}}} = Analyze.analyze(raw)
    end
  end
end
