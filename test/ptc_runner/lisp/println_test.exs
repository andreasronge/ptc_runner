defmodule PtcRunner.Lisp.PrintlnTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp

  test "println output is preserved through function calls" do
    source = ~S"""
    (do
      (println "before call")
      ((fn [] (println "inside fn") nil))
      (println "after call"))
    """

    {:ok, step} = Lisp.run(source)
    assert step.prints == ["before call", "inside fn", "after call"]
  end

  test "println accumulates output" do
    source = """
    (println "hello")
    (println "world" 42)
    {:a 1}
    """

    {:ok, step} = Lisp.run(source)
    assert step.return == %{a: 1}
    assert step.prints == ["hello", "world 42"]
  end

  test "println formats lisp values correctly" do
    source = ~S"""
    (println {:a 1 :b [2 3]})
    (println #{1 2})
    (println (fn [x] (+ x 1)))
    """

    {:ok, step} = Lisp.run(source)
    assert Enum.at(step.prints, 0) == ~S|{:a 1 :b [2 3]}|
    assert Enum.at(step.prints, 1) == ~S|#{1 2}|
    assert Enum.at(step.prints, 2) == "#fn[x]"
  end

  test "println works inside functions" do
    source = """
    (defn my-func [x]
      (println "debug x:" x)
      (* x 2))
    (my-func 10)
    """

    {:ok, step} = Lisp.run(source)
    assert step.return == 20
    assert step.prints == ["debug x: 10"]
  end

  test "println works in pmap (collected from side effects)" do
    # Note: pmap in PTC-Lisp captures the context but updates to it (like prints)
    # might be tricky depending on how they are merged back.
    # Current implementation of pmap DOES NOT merge back context updates from parallel tasks
    # because they are executed in separate tasks and only the result is collected.

    source = """
    (pmap (fn [x] (println "item" x) (* x x)) [1 2 3])
    """

    {:ok, step} = Lisp.run(source)
    assert step.return == [1, 4, 9]
    # Current expectation: prints inside pmap are LOST because pmap
    # doesn't collect context changes from parallel tasks.
    # If we wanted to support this, we'd need to change pmap to return context too.
    # For now, we only support prints in the main thread.
    assert step.prints == []
  end

  test "println in loop with recur captures all iterations" do
    source = """
    (loop [x 3]
      (println "x is" x)
      (if (> x 1)
        (recur (dec x))
        :done))
    """

    {:ok, step} = Lisp.run(source)
    assert step.return == :done
    assert step.prints == ["x is 3", "x is 2", "x is 1"]
  end

  test "map println does not error but output is lost (like pmap)" do
    source = """
    (map println [1 2 3])
    """

    {:ok, step} = Lisp.run(source)
    # Returns list of nils (println returns nil)
    assert step.return == [nil, nil, nil]
    # Prints are NOT captured (same as pmap - HOF side effects lost)
    assert step.prints == []
  end
end
