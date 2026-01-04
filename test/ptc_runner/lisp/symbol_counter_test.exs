defmodule PtcRunner.Lisp.SymbolCounterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.{Parser, SymbolCounter}

  doctest SymbolCounter

  describe "count/1" do
    test "empty program returns 0" do
      assert {:ok, ast} = Parser.parse("nil")
      assert SymbolCounter.count(ast) == 0
    end

    test "counts unique keywords" do
      assert {:ok, ast} = Parser.parse("{:a 1 :b 2 :c 3}")
      assert SymbolCounter.count(ast) == 3
    end

    test "counts unique symbols" do
      assert {:ok, ast} = Parser.parse("[foo bar baz]")
      assert SymbolCounter.count(ast) == 3
    end

    test "duplicate symbols counted once" do
      assert {:ok, ast} = Parser.parse("{:a 1 :a 2 :a 3}")
      assert SymbolCounter.count(ast) == 1
    end

    test "keywords and symbols counted together" do
      # :name appears twice as keyword, `name` is a different symbol
      assert {:ok, ast} = Parser.parse("{:name \"Alice\" :age 30}")
      assert SymbolCounter.count(ast) == 2
    end

    test "nested structures" do
      # Nested map with vector containing keywords
      assert {:ok, ast} = Parser.parse("{:outer {:inner [:a :b :c]}}")
      assert SymbolCounter.count(ast) == 5
    end

    test "excludes core language symbols" do
      # These are all core language symbols, should count as 0
      assert {:ok, ast} = Parser.parse("(if true 1 2)")
      assert SymbolCounter.count(ast) == 0

      assert {:ok, ast} = Parser.parse("(let [x 1] x)")
      # 'x' is a user symbol, not core
      assert SymbolCounter.count(ast) == 1

      assert {:ok, ast} = Parser.parse("(fn [a b] (+ a b))")
      # 'a', 'b', '+' are user symbols (+ is not in core_symbols)
      assert SymbolCounter.count(ast) == 3
    end

    test "excludes :else keyword" do
      assert {:ok, ast} = Parser.parse("(cond :else :default)")
      # :default is user-defined, :else is core
      assert SymbolCounter.count(ast) == 1
    end

    test "namespaced symbols count the key part" do
      assert {:ok, ast} = Parser.parse("[ctx/foo ctx/bar]")
      assert SymbolCounter.count(ast) == 2
    end

    test "strings do not count" do
      assert {:ok, ast} = Parser.parse(~S/["hello" "world"]/)
      assert SymbolCounter.count(ast) == 0
    end

    test "numbers do not count" do
      assert {:ok, ast} = Parser.parse("[1 2 3.14 -42]")
      assert SymbolCounter.count(ast) == 0
    end

    test "sets count unique symbols" do
      assert {:ok, ast} = Parser.parse(~S"#{:a :b :c}")
      assert SymbolCounter.count(ast) == 3
    end

    test "short function syntax" do
      # #(+ % 1) -> contains +, %, and 1
      # % is a placeholder symbol (not in core), + is user symbol
      assert {:ok, ast} = Parser.parse(~S"#(+ % 1)")
      assert SymbolCounter.count(ast) == 2
    end

    test "complex program with many unique keywords" do
      # Generate a map with 100 unique keywords
      keywords = Enum.map_join(1..100, " ", &":k#{&1}")
      program = "{#{keywords}}"
      assert {:ok, ast} = Parser.parse(program)
      assert SymbolCounter.count(ast) == 100
    end
  end
end
