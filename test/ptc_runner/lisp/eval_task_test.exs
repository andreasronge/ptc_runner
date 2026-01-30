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
    test "symbol as task ID resolves dynamically" do
      # Unbound symbol fails at runtime, not analysis
      {:error, step} = Lisp.run(~S|(task my-id 42)|)
      assert step.fail.reason == :unbound_var

      # Bound symbol works as dynamic task ID
      {:ok, step} = Lisp.run(~S|(def my-id "test-1") (task my-id 42)|, journal: %{})
      assert step.return == 42
      assert step.journal == %{"test-1" => 42}
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

  describe "(task) dynamic IDs with (str ...)" do
    test "str expression as task ID" do
      {:ok, step} =
        Lisp.run(
          ~S|(def name "bob") (task (str "prepare_" name) 42)|,
          journal: %{}
        )

      assert step.return == 42
      assert step.journal == %{"prepare_bob" => 42}
    end

    test "str expression with cache hit" do
      {:ok, step} =
        Lisp.run(
          ~S|(def name "bob") (task (str "prepare_" name) 42)|,
          journal: %{"prepare_bob" => "cached"}
        )

      assert step.return == "cached"
    end
  end

  describe "(task) failure semantics" do
    test "fail inside task body does not commit to journal" do
      {:ok, step} = Lisp.run(~S|(task "will-fail" (fail "oops"))|, journal: %{})

      # fail signal propagates - the task result is a fail signal
      assert {:__ptc_fail__, "oops"} = step.return
      assert step.journal == %{}
    end

    test "fail inside task halts execution - code after task does not run" do
      {:ok, step} =
        Lisp.run(~S|(do (task "x" (fail "oops")) (+ 1 2))|, journal: %{})

      # Should get the fail signal, NOT 3
      assert {:__ptc_fail__, "oops"} = step.return
      assert step.journal == %{}
    end
  end

  describe "(task) re-invocation pattern" do
    test "second run with journal skips cached tasks and continues" do
      tools = %{"send_email" => fn %{"to" => to} -> "sent_to_#{to}" end}

      # Turn 1: execute task, get journal
      {:ok, step1} =
        Lisp.run(~S|(task "email" (tool/send_email {:to "bob"}))|,
          journal: %{},
          tools: tools
        )

      assert step1.journal == %{"email" => "sent_to_bob"}

      # Turn 2: re-run with journal - tool should NOT be called again
      # Using a tool map without the tool proves it wasn't called
      {:ok, step2} =
        Lisp.run(
          ~S|(do (task "email" (tool/send_email {:to "bob"})) (str (task "email" (tool/send_email {:to "bob"})) "_done"))|,
          journal: step1.journal
        )

      assert step2.return == "sent_to_bob_done"
      assert step2.journal == %{"email" => "sent_to_bob"}
    end
  end
end
