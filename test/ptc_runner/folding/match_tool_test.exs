defmodule PtcRunner.Folding.MatchToolTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.MatchTool

  # === Basic Token Matching ===

  test "exact match on simple expression" do
    assert MatchTool.matches?("(count data/products)", "(count data/products)")
  end

  test "no match when different function" do
    refute MatchTool.matches?("(count data/products)", "(filter data/products)")
  end

  test "no match when different data source" do
    refute MatchTool.matches?("(count data/products)", "(count data/employees)")
  end

  # === Wildcard Basics ===

  test "wildcard matches single token" do
    assert MatchTool.matches?("(count data/products)", "(count *)")
  end

  test "wildcard matches any data source" do
    assert MatchTool.matches?("(count data/employees)", "(count *)")
    assert MatchTool.matches?("(count data/orders)", "(count *)")
  end

  test "wildcard matches numeric literal" do
    assert MatchTool.matches?("(> 500 300)", "(> * 300)")
    assert MatchTool.matches?("(> 500 300)", "(> 500 *)")
  end

  test "wildcard matches keyword" do
    assert MatchTool.matches?("(get x :price)", "(get x *)")
    assert MatchTool.matches?("(get x :price)", "(get * :price)")
  end

  test "multiple wildcards" do
    assert MatchTool.matches?("(> 500 300)", "(> * *)")
    assert MatchTool.matches?("(filter something data/products)", "(filter * *)")
  end

  test "all wildcards" do
    assert MatchTool.matches?("(count data/products)", "(* *)")
  end

  test "single wildcard matches single token only" do
    # (count data/products) has 2 tokens inside parens, pattern has 1 wildcard + count
    assert MatchTool.matches?("(count data/products)", "(count *)")
    # But wildcard doesn't match TWO tokens
    refute MatchTool.matches?("(count data/products extra)", "(count *)")
  end

  # === Nested Expression Matching ===

  test "wildcard matches nested parenthesized expression" do
    assert MatchTool.matches?(
             "(count (filter (fn [x] true) data/products))",
             "(count *)"
           )
  end

  test "wildcard matches complex nested expression" do
    assert MatchTool.matches?(
             "(filter (fn [x] (> (get x :price) 500)) data/products)",
             "(filter * *)"
           )
  end

  test "nested pattern matching" do
    assert MatchTool.matches?(
             "(filter (fn [x] (> (get x :price) 500)) data/products)",
             "(filter (fn [x] *) data/products)"
           )
  end

  test "deeply nested pattern" do
    assert MatchTool.matches?(
             "(filter (fn [x] (> (get x :price) 500)) data/products)",
             "(filter (fn [x] (> * 500)) data/products)"
           )
  end

  test "pattern with nested wildcard in get" do
    assert MatchTool.matches?(
             "(filter (fn [x] (> (get x :price) 500)) data/products)",
             "(filter (fn [x] (> (get x *) 500)) data/products)"
           )
  end

  # === Non-Matching Cases ===

  test "different nesting structure doesn't match" do
    refute MatchTool.matches?("(count data/products)", "(filter * *)")
  end

  test "different arity doesn't match" do
    refute MatchTool.matches?("(count data/products)", "(count * *)")
  end

  test "too few arguments doesn't match" do
    refute MatchTool.matches?("(> 500 300)", "(> *)")
  end

  test "empty source doesn't match non-empty pattern" do
    refute MatchTool.matches?("", "(count *)")
  end

  test "non-parenthesized source against parenthesized pattern" do
    refute MatchTool.matches?("500", "(count *)")
  end

  # === Bracket Matching ===

  test "bracket expressions in patterns" do
    assert MatchTool.matches?("(fn [x] (count x))", "(fn [x] *)")
  end

  test "wildcard matches bracket expression" do
    assert MatchTool.matches?("(fn [x] (count x))", "(fn * (count x))")
  end

  # === Real-World Phenotype Patterns ===

  test "match count of any data source" do
    sources = [
      "(count data/products)",
      "(count data/employees)",
      "(count data/orders)",
      "(count data/expenses)"
    ]

    Enum.each(sources, fn src ->
      assert MatchTool.matches?(src, "(count *)"),
             "Expected (count *) to match #{src}"
    end)
  end

  test "match filter with any predicate and data" do
    source = "(filter (fn [x] (> (get x :price) 500)) data/products)"
    assert MatchTool.matches?(source, "(filter * *)")
    assert MatchTool.matches?(source, "(filter * data/products)")
    assert MatchTool.matches?(source, "(filter (fn [x] *) *)")
    refute MatchTool.matches?(source, "(filter * data/employees)")
  end

  test "match let binding pattern" do
    source = "(let [x (count data/products)] (> x 5))"
    assert MatchTool.matches?(source, "(let * *)")
    assert MatchTool.matches?(source, "(let [x *] *)")
    refute MatchTool.matches?(source, "(count *)")
  end

  test "match map pattern" do
    source = "(map (fn [x] (get x :name)) data/employees)"
    assert MatchTool.matches?(source, "(map * *)")
    assert MatchTool.matches?(source, "(map (fn [x] *) data/employees)")
    refute MatchTool.matches?(source, "(filter * *)")
  end

  test "match comparison patterns" do
    assert MatchTool.matches?("(> (get x :price) 500)", "(> * *)")
    assert MatchTool.matches?("(> (get x :price) 500)", "(> (get x *) *)")
    assert MatchTool.matches?("(< (get x :amount) 100)", "(< * *)")
  end

  test "match cross-dataset join pattern" do
    source =
      "(let [ids (set (map (fn [e] (get e :id)) (filter (fn [e] (= (get e :department) \"engineering\")) data/employees)))] (count (filter (fn [ex] (contains? ids (get ex :employee_id))) data/expenses)))"

    assert MatchTool.matches?(source, "(let * *)")
    assert MatchTool.matches?(source, "(let [ids *] *)")
    refute MatchTool.matches?(source, "(count *)")
    refute MatchTool.matches?(source, "(filter * *)")
  end

  # === Whitespace Handling ===

  test "handles extra whitespace" do
    assert MatchTool.matches?("  (count   data/products)  ", "(count *)")
  end

  test "handles multiline source" do
    source = "(count\n  data/products)"
    assert MatchTool.matches?(source, "(count *)")
  end

  # === Edge Cases ===

  test "empty pattern matches empty source" do
    assert MatchTool.matches?("", "")
  end

  test "bare token matches bare token" do
    assert MatchTool.matches?("500", "500")
    assert MatchTool.matches?("500", "*")
  end

  test "wildcard-only pattern matches any single expression" do
    assert MatchTool.matches?("(count data/products)", "*")
    assert MatchTool.matches?("500", "*")
    assert MatchTool.matches?(":price", "*")
  end

  # === Anti-Gaming Tests ===
  # These verify that the match is structural, not string-based

  test "junk string literal doesn't affect structural match" do
    # A program that wraps count in identity — should NOT match (count *)
    refute MatchTool.matches?("(identity (count data/products))", "(count *)")
    # But should match (identity *)
    assert MatchTool.matches?("(identity (count data/products))", "(identity *)")
  end

  test "reordered arguments don't match" do
    refute MatchTool.matches?("(> 500 (get x :price))", "(> (get x :price) *)")
    assert MatchTool.matches?("(> 500 (get x :price))", "(> * (get x :price))")
  end

  # === Tool Executor ===

  test "tool_executor returns match function" do
    executor = MatchTool.tool_executor("(count data/products)")
    assert {:ok, true} = executor.("match", %{"pattern" => "(count *)"})
    assert {:ok, false} = executor.("match", %{"pattern" => "(filter * *)"})
  end

  test "tool_executor with nil peer source" do
    executor = MatchTool.tool_executor(nil)
    assert {:ok, false} = executor.("match", %{"pattern" => "(count *)"})
  end
end
