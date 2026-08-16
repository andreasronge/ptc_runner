defmodule PtcRunner.Lisp.PrintlnTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Java.Time.Instant

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
    assert step.return == %{"a" => 1}
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

  test "println structurally previews a huge map before capturing it" do
    payload = String.duplicate("x", 10_000)

    source =
      ~s|(println {"aaa_payload" "#{payload}" "status" "ok" "trace_id" "trace-1"})|

    assert {:ok, step} = Lisp.run(source, max_print_length: 256)
    [output] = step.prints

    assert output =~ ~S|"status"|
    assert output =~ ~S|"trace_id"|
    assert output =~ "preview truncated"
    assert String.length(output) <= 256
    refute output =~ String.duplicate("x", 1_000)
  end

  test "println preserves canonical native Java labels" do
    assert {:ok, instant} = Instant.parse(["2024-01-02T03:04:05Z"])

    assert {:ok, step} = Lisp.run_native("(println value)", memory: %{"value" => instant})
    assert step.prints == ["#java[java.time.Instant 2024-01-02T03:04:05Z]"]
  end

  test "println renders composite callables opaquely" do
    source = """
    (println (constantly "token"))
    (println (partial + 1))
    (println (juxt inc dec))
    (println (comp inc dec))
    (println (complement nil?))
    (println (every-pred int? pos?))
    (println (some-fn nil? pos?))
    (println (fnil + 0))
    """

    assert {:ok, step} = Lisp.run(source)
    assert step.prints == List.duplicate("#fn[...]", 8)
  end

  test "println marks omitted trailing arguments at the exact print boundary" do
    assert {:ok, step} = Lisp.run(~S|(println "abc" "d")|, max_print_length: 3)
    assert step.prints == ["abc... (3/4 chars)"]
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

  test "println in pmap is captured in input order" do
    source = """
    (pmap (fn [x] (println "item" x) (* x x)) [1 2 3])
    """

    {:ok, step} = Lisp.run(source)
    assert step.return == [1, 4, 9]
    assert step.prints == ["item 1", "item 2", "item 3"]
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
    assert step.return == "done"
    assert step.prints == ["x is 3", "x is 2", "x is 1"]
  end

  test "map println captures output from HOF closures" do
    source = """
    (map println [1 2 3])
    """

    {:ok, step} = Lisp.run(source)
    # Returns list of nils (println returns nil)
    assert step.return == [nil, nil, nil]
    # Prints are captured from HOF closure invocations
    assert step.prints == ["1", "2", "3"]
  end

  test "map println respects configurable max_print_length" do
    assert {:ok, step} = Lisp.run(~S|(map println ["abcdef"])|, max_print_length: 3)
    assert step.prints == ["abc... (3/6 chars)"]
  end

  test "pmap println respects configurable max_print_length" do
    assert {:ok, step} = Lisp.run(~S|(pmap println ["abcdef"])|, max_print_length: 3)
    assert step.prints == ["abc... (3/6 chars)"]
  end

  test "println output truncated at 2000 characters (TRN-011)" do
    # Generate a string longer than 2000 chars
    long_string = String.duplicate("x", 2500)

    source = """
    (println "#{long_string}")
    """

    {:ok, step} = Lisp.run(source)
    [output] = step.prints
    assert String.starts_with?(output, "xxx")
    assert output =~ "... (2000/2500 chars)"
  end

  test "multiple long println calls each truncated independently" do
    long_a = String.duplicate("a", 2100)
    long_b = String.duplicate("b", 2100)

    source = """
    (println "#{long_a}")
    (println "#{long_b}")
    """

    {:ok, step} = Lisp.run(source)
    assert length(step.prints) == 2

    [first, second] = step.prints
    assert String.starts_with?(first, "aaa")
    assert first =~ "... (2000/2100 chars)"

    assert String.starts_with?(second, "bbb")
    assert second =~ "... (2000/2100 chars)"
  end

  test "println respects configurable max_print_length option" do
    long_string = String.duplicate("y", 200)

    source = """
    (println "#{long_string}")
    """

    # Custom limit of 100 characters
    {:ok, step} = Lisp.run(source, max_print_length: 100)
    [output] = step.prints
    assert String.starts_with?(output, "yyy")
    assert output =~ "... (100/200 chars)"
  end

  test "max_print_length propagates into defn calls" do
    long_string = String.duplicate("z", 200)

    source = """
    (defn log-msg [s] (println s))
    (log-msg "#{long_string}")
    """

    # Custom limit of 100 characters should be respected inside defn
    {:ok, step} = Lisp.run(source, max_print_length: 100)
    [output] = step.prints
    assert String.starts_with?(output, "zzz")
    assert output =~ "... (100/200 chars)"
  end

  test "max_print_length propagates into closure calls" do
    long_string = String.duplicate("w", 200)

    source = """
    (let [log (fn [s] (println s))]
      (log "#{long_string}"))
    """

    {:ok, step} = Lisp.run(source, max_print_length: 100)
    [output] = step.prints
    assert String.starts_with?(output, "www")
    assert output =~ "... (100/200 chars)"
  end

  describe "char list detection (take on string)" do
    test "println joins char list from (take n string)" do
      source = ~S|(println (take 10 "hello world"))|

      {:ok, step} = Lisp.run(source)
      assert step.prints == ["hello worl"]
    end

    test "println joins char list with mixed content" do
      source = ~S|(println "File:" (take 5 "abcdefgh"))|

      {:ok, step} = Lisp.run(source)
      assert step.prints == ["File: abcde"]
    end

    test "println does not join normal integer list" do
      source = ~S|(println [1 2 3])|

      {:ok, step} = Lisp.run(source)
      assert step.prints == ["[1 2 3]"]
    end

    test "println does not join empty list" do
      source = ~S|(println [])|

      {:ok, step} = Lisp.run(source)
      assert step.prints == ["[]"]
    end

    test "println does not join list of multi-char strings" do
      source = ~S|(println ["hello" "world"])|

      {:ok, step} = Lisp.run(source)
      assert step.prints == [~S|["hello" "world"]|]
    end

    test "println does not join mixed list (chars and non-chars)" do
      source = ~S|(println ["a" 1 "b"])|

      {:ok, step} = Lisp.run(source)
      assert step.prints == [~S|["a" 1 "b"]|]
    end

    test "println does not infer a char list from a bounded prefix" do
      prefix = Enum.map_join(1..64, " ", fn _ -> ~S|"a"| end)
      source = "(println [#{prefix} 42])"

      assert {:ok, step} = Lisp.run(source, max_print_length: 64)
      [output] = step.prints

      assert output =~ "preview truncated"
      refute output == String.duplicate("a", 63) <> "…"
    end

    test "println handles nested char list in expression" do
      source = ~S|
        (def content "defmodule Foo do\n  def bar, do: :ok\nend")
        (println "First 20 chars:" (take 20 content))
      |

      {:ok, step} = Lisp.run(source)
      assert step.prints == ["First 20 chars: defmodule Foo do\n  d"]
    end
  end
end
