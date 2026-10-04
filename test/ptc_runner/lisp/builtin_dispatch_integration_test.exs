defmodule PtcRunner.Lisp.BuiltinDispatchIntegrationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  test "direct and higher-order invocation agree for every builtin binding shape" do
    for {direct, higher_order, expected} <- [
          {"(inc 2)", "(first (map inc [2]))", 3},
          {"(+ 2 3 4)", "(first (map + [2] [3] [4]))", 9},
          {"(- 2 3)", "(first (map - [2] [3]))", -1},
          {"(range 2 5)", "(first (map range [2] [5]))", [2, 3, 4]},
          {"(merge {:x 1} {:y 2})", "(first (map merge [{:x 1}] [{:y 2}]))",
           %{"x" => 1, "y" => 2}}
        ] do
      assert {:ok, direct_step} = Lisp.run(direct)
      assert {:ok, higher_order_step} = Lisp.run(higher_order)
      assert direct_step.return == expected
      assert higher_order_step.return == expected
    end
  end

  test "arithmetic and type faults retain their classification through callbacks" do
    for {direct, higher_order, reason} <- [
          {"(/ 1 0)", "(map / [1] [0])", :arithmetic_error},
          {"(+ 1 nil)", "(map + [1] [nil])", :type_error},
          {"(inc nil)", "(map inc [nil])", :arithmetic_error}
        ] do
      assert {:error, direct_step} = Lisp.run(direct)
      assert {:error, higher_order_step} = Lisp.run(higher_order)
      assert direct_step.fail.reason == reason
      assert higher_order_step.fail.reason == reason
    end
  end
end
