defmodule PtcRunner.Lisp.EvalTaskTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "(task) with journal" do
    test "cache miss evaluates body and commits to journal" do
      {:ok, step} = Lisp.run(~S|(task "step-1" (+ 1 2))|, journal: %{})

      assert step.return == 3
      assert step.journal == %{"step-1" => 3}
    end

    test "cache hit returns stored value without evaluating body" do
      # Body calls a tool that would fail if evaluated - proves caching works
      {:ok, step} =
        Lisp.run(~S|(task "cached" (tool/nonexistent {:x 1}))|,
          journal: %{"cached" => 42}
        )

      assert step.return == 42
      assert step.journal == %{"cached" => 42}
    end

    test "multiple tasks accumulate in journal" do
      {:ok, step} =
        Lisp.run(
          ~S|(do (task "a" 10) (task "b" 20))|,
          journal: %{}
        )

      assert step.return == 20
      assert step.journal == %{"a" => 10, "b" => 20}
    end

    test "task with tool call commits result" do
      tools = %{
        "double" => fn %{"n" => n} -> n * 2 end
      }

      {:ok, step} =
        Lisp.run(~S|(task "doubled" (tool/double {:n 5}))|,
          journal: %{},
          tools: tools
        )

      assert step.return == 10
      assert step.journal == %{"doubled" => 10}
    end

    test "existing journal entries are preserved" do
      {:ok, step} =
        Lisp.run(~S|(task "new" 99)|,
          journal: %{"old" => 1}
        )

      assert step.journal == %{"old" => 1, "new" => 99}
    end
  end

  describe "(task) without journal (nil)" do
    test "executes body without caching" do
      {:ok, step} = Lisp.run(~S|(task "step-1" (+ 1 2))|)

      assert step.return == 3
      assert step.journal == nil
    end
  end

  describe "(task) analyzer validation" do
    test "rejects symbol as task ID" do
      {:error, step} = Lisp.run(~S|(task my-id 42)|)

      assert step.fail.reason == :invalid_form
    end

    test "rejects wrong arity" do
      {:error, step} = Lisp.run(~S|(task "id")|)

      assert step.fail.reason == :invalid_arity
    end

    test "rejects too many args" do
      {:error, step} = Lisp.run(~S|(task "id" 1 2)|)

      assert step.fail.reason == :invalid_arity
    end
  end

  describe "(task) failure semantics" do
    test "fail inside task body does not commit to journal" do
      {:ok, step} = Lisp.run(~S|(task "will-fail" (fail "oops"))|, journal: %{})

      # fail signal propagates - the task result is a fail signal
      assert {:__ptc_fail__, "oops"} = step.return
      assert step.journal == %{}
    end
  end
end
