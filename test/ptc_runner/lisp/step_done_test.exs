defmodule PtcRunner.Lisp.StepDoneTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "step-done" do
    test "stores summary and returns it" do
      {:ok, step} = Lisp.run(~S|(step-done "gather" "Found 42 records")|, journal: %{})

      assert step.return == "Found 42 records"
      assert step.summaries == %{"gather" => "Found 42 records"}
    end

    test "multiple step-done calls accumulate" do
      code = ~S|
        (do
          (step-done "a" "first")
          (step-done "b" "second"))
      |

      {:ok, step} = Lisp.run(code, journal: %{})

      assert step.summaries == %{"a" => "first", "b" => "second"}
    end

    test "later step-done overwrites earlier for same id" do
      code = ~S|
        (do
          (step-done "a" "first")
          (step-done "a" "updated"))
      |

      {:ok, step} = Lisp.run(code, journal: %{})

      assert step.summaries == %{"a" => "updated"}
    end

    test "works with dynamic id" do
      code = ~S|(step-done (str "step-" 1) "done")|

      {:ok, step} = Lisp.run(code, journal: %{})

      assert step.summaries == %{"step-1" => "done"}
    end

    test "coerces integer id to string" do
      {:ok, step} = Lisp.run(~S|(step-done 1 "done")|, journal: %{})

      assert step.summaries == %{"1" => "done"}
    end

    test "rejects nil id" do
      {:error, step} = Lisp.run(~S|(step-done nil "done")|, journal: %{})

      assert step.fail.reason == :type_error
      assert step.fail.message =~ "step-done"
      assert step.fail.message =~ "id"
    end

    test "rejects nil summary" do
      {:error, step} = Lisp.run(~S|(step-done "a" nil)|, journal: %{})

      assert step.fail.reason == :type_error
      assert step.fail.message =~ "summary"
    end

    test "rejects list as id" do
      {:error, step} = Lisp.run(~S|(step-done [1 2] "done")|, journal: %{})

      assert step.fail.reason == :type_error
    end

    test "summaries from pmap closures are not propagated (known limitation)" do
      # pmap runs closures in separate Task processes — EvalContext side effects
      # (prints, summaries, user_ns) don't propagate back. This matches the
      # existing behavior for println inside pmap. Use sequential map or
      # call step-done after pmap completes.
      code = ~S|
        (do
          (pmap (fn [id] (step-done id (str "done-" id)))
                ["a" "b" "c"])
          nil)
      |

      {:ok, step} = Lisp.run(code, journal: %{}, timeout: 5000, pmap_timeout: 5000)

      assert step.summaries == %{}
    end

    test "step-done works at top level in sequential do block" do
      code = ~S|
        (do
          (step-done "a" "done-a")
          (step-done "b" "done-b")
          (step-done "c" "done-c"))
      |

      {:ok, step} = Lisp.run(code, journal: %{})

      assert step.summaries == %{"a" => "done-a", "b" => "done-b", "c" => "done-c"}
    end
  end

  describe "task-reset" do
    test "removes key from journal" do
      {:ok, step} = Lisp.run(~S|(task-reset "a")|, journal: %{"a" => 1, "b" => 2})

      assert step.return == nil
      assert step.journal == %{"b" => 2}
    end

    test "no-op when key not in journal" do
      {:ok, step} = Lisp.run(~S|(task-reset "missing")|, journal: %{"a" => 1})

      assert step.journal == %{"a" => 1}
    end

    test "handles nil journal gracefully" do
      {:ok, step} = Lisp.run(~S|(task-reset "a")|)

      assert step.return == nil
    end

    test "rejects nil id" do
      {:error, step} = Lisp.run(~S|(task-reset nil)|, journal: %{})

      assert step.fail.reason == :type_error
    end
  end
end
