defmodule PtcRunner.Lisp.EffectOutcomeRegressionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "effects retained by expected exits" do
    test "a sequential error retains effects from an earlier form" do
      tools = %{
        "cached" => {fn args -> args end, signature: "(x :int) -> :map", cache: true}
      }

      source = ~S"""
      (do
        (println "before error")
        (tool/cached {:x 1})
        (inc "bad"))
      """

      assert {:error, step} = Lisp.run(source, tools: tools)
      assert step.fail.reason == :arithmetic_error
      assert step.prints == ["before error"]
      assert [%{name: "cached", args: %{"x" => 1}}] = step.tool_calls
    end

    test "an ordinary HOF error retains effects from earlier and failing callbacks" do
      tools = %{"touch" => fn args -> args end}

      source = ~S"""
      (map
        (fn [x]
          (do
            (println x)
            (tool/touch {:x x})
            (if (= x 2) (inc "bad") x)))
        [1 2])
      """

      assert {:error, step} = Lisp.run(source, tools: tools)
      assert step.fail.reason == :type_error
      assert step.prints == ["1", "2"]
      assert Enum.map(step.tool_calls, & &1.args["x"]) == [1, 2]
    end

    test "a raised evaluator error retains earlier audit effects" do
      tools = %{"touch" => fn args -> args end}

      source = ~S"""
      (do
        (println "before strict error")
        (tool/touch {:x 1})
        data/missing)
      """

      assert {:error, step} = Lisp.run(source, tools: tools, strict_data: true)
      assert step.fail.reason == :runtime_error
      assert step.prints == ["before strict error"]
      assert [%{name: "touch", args: %{"x" => 1}}] = step.tool_calls
    end

    test "tail recur has the same result directly and through an ordinary HOF" do
      direct =
        ~S"((fn countdown [x] (do (println x) (if (= x 0) x (recur (- x 1))))) 3)"

      through_hof =
        ~S"(map (fn countdown [x] (do (println x) (if (= x 0) x (recur (- x 1))))) [3])"

      assert {:ok, direct_step} = Lisp.run(direct)
      assert {:ok, hof_step} = Lisp.run(through_hof)
      assert direct_step.return == 0
      assert hof_step.return == [0]
      assert direct_step.prints == ["3", "2", "1", "0"]
      assert hof_step.prints == direct_step.prints
    end

    @tag timeout: 15_000
    test "large effectful HOFs stay within the default evaluator heap" do
      source = ~S|(map (fn [x] (println x)) (range 0 20000))|

      assert {:ok, step} = Lisp.run(source, timeout: 10_000)
      assert length(step.prints) == 20_000
    end

    test "an ordinary HOF tool error retains earlier and failing callback ledgers" do
      tools = %{
        "sometimes" => fn %{"x" => x} = args ->
          if x == 2, do: raise("provider failed"), else: args
        end
      }

      source = ~S|(map (fn [x] (tool/sometimes {:x x})) [1 2])|

      assert {:error, step} = Lisp.run(source, tools: tools)
      assert step.fail.reason == :tool_error
      assert Enum.map(step.tool_calls, & &1.args["x"]) == [1, 2]
      assert Enum.at(step.tool_calls, 1).error == "provider failed"
    end

    test "an ordinary HOF return retains effects from every executed callback" do
      tools = %{"touch" => fn args -> args end}

      source = ~S"""
      (map
        (fn [x]
          (do
            (println x)
            (tool/touch {:x x})
            (if (= x 2) (return x) x)))
        [1 2])
      """

      assert {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == {:__ptc_return__, 2}
      assert step.prints == ["1", "2"]
      assert Enum.map(step.tool_calls, & &1.args["x"]) == [1, 2]
    end

    test "an ordinary HOF fail retains effects from every executed callback" do
      tools = %{"touch" => fn args -> args end}

      source = ~S"""
      (map
        (fn [x]
          (do
            (println x)
            (tool/touch {:x x})
            (if (= x 2) (fail "stop") x)))
        [1 2])
      """

      assert {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == {:__ptc_fail__, "stop"}
      assert step.prints == ["1", "2"]
      assert Enum.map(step.tool_calls, & &1.args["x"]) == [1, 2]
    end
  end
end
