defmodule PtcRunner.Lisp.TerminationTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp

  describe "return/fail termination" do
    test "return should terminate execution immediately" do
      code = """
      (do
        (return {:status "ok"})
        (def should-not-exist 123)
        (println "This should not be printed"))
      """

      {:ok, step} = Lisp.run(code)

      # In the current (broken) implementation:
      # 1. return is called and returns {:__ptc_return__, %{status: "ok"}}
      # 2. (def should-not-exist 123) is executed
      # 3. (println ...) is executed
      # 4. The final result of the `do` block is the result of println (nil)

      # We EXPECT it to return the sentinel from return and NOT execute the rest
      assert step.return == {:__ptc_return__, %{status: "ok"}}
      assert step.memory == %{}
      assert step.prints == []
    end

    test "fail should terminate execution immediately" do
      code = """
      (do
        (fail "error message")
        (def should-not-exist 123))
      """

      {:ok, step} = Lisp.run(code)

      assert step.return == {:__ptc_fail__, "error message"}
      assert step.memory == %{}
    end
  end
end
