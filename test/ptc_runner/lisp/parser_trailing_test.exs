defmodule PtcRunner.Lisp.ParserTrailingTest do
  use ExUnit.Case
  alias PtcRunner.Lisp.Parser

  test "parses with extra trailing parentheses" do
    source = "(+ 1 2)))"
    assert {:ok, _ast} = Parser.parse(source)
  end

  test "parses with multiple expressions and extra trailing parentheses" do
    source = "(def x 1) (+ x 1))))"
    assert {:ok, {:program, _asts}} = Parser.parse(source)
  end

  test "parses with extra trailing brackets" do
    source = "[1 2 3]]]"
    assert {:ok, _ast} = Parser.parse(source)
  end

  test "parses with extra trailing braces" do
    assert {:ok, _} = Parser.parse("{:a 1}}}")
  end

  test "parses with mixed trailing delimiters" do
    assert {:ok, _} = Parser.parse("(+ 1 2))]}")
  end

  test "parses with extra parentheses between expressions" do
    source = "(defn f [x] x))) (f 1)"
    assert {:ok, {:program, [_, _]}} = Parser.parse(source)
  end
end
