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

  describe "return/fail in threading macros" do
    test "return in thread-last (->>)" do
      {:ok, step} = Lisp.run("(->> 42 (return))")
      assert step.return == {:__ptc_return__, 42}
    end

    test "return in thread-first (->)" do
      {:ok, step} = Lisp.run("(-> 42 (return))")
      assert step.return == {:__ptc_return__, 42}
    end

    test "fail in thread-last (->>)" do
      {:ok, step} = Lisp.run("(->> \"error\" (fail))")
      assert step.return == {:__ptc_fail__, "error"}
    end

    test "fail in thread-first (->)" do
      {:ok, step} = Lisp.run("(-> {:reason :test} (fail))")
      assert step.return == {:__ptc_fail__, %{reason: :test}}
    end

    test "return in longer pipeline" do
      code = """
      (->> [1 2 3 4 5]
           (filter #(> % 2))
           (count)
           (return))
      """

      {:ok, step} = Lisp.run(code)
      assert step.return == {:__ptc_return__, 3}
    end
  end
end
