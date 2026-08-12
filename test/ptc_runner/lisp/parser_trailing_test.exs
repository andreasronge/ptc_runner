defmodule PtcRunner.Lisp.ParserTrailingTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Parser

  test "rejects a trailing closing parenthesis with its count and first position" do
    source = "(+ 1 2)))"

    assert {:error, {:parse_error, message, position}} = Parser.parse_with_position(source)
    assert message == "unbalanced parentheses: 2 extra ')' (first at line 1, column 8)"
    assert position == 7
  end

  test "rejects each standalone closing delimiter with actionable feedback" do
    for {source, message} <- [
          {")", "unbalanced parentheses: 1 extra ')' (first at line 1, column 1)"},
          {"]", "unbalanced brackets: 1 extra ']' (first at line 1, column 1)"},
          {"}", "unbalanced braces: 1 extra '}' (first at line 1, column 1)"}
        ] do
      assert {:error, {:parse_error, ^message, 0}} = Parser.parse_with_position(source)
    end
  end

  test "rejects surplus closers between expressions at the first closer" do
    source = "(def x 1)\n  ))\n(+ x 1)"
    position = :binary.match(source, "))") |> elem(0)

    assert {:error, {:parse_error, message, ^position}} = Parser.parse_with_position(source)
    assert message == "unbalanced parentheses: 2 extra ')' (first at line 2, column 3)"
  end

  test "mixed surplus closers identify every delimiter and locate the first" do
    source = "(+ 1 2)) ] }"

    assert {:error, {:parse_error, message, 7}} = Parser.parse_with_position(source)

    assert message ==
             "unexpected closing ')' at line 1, column 8; " <>
               "3 surplus top-level closing delimiters: 1 ')', 1 ']', 1 '}'"
  end

  test "a later hard syntax error remains the primary positioned diagnostic" do
    source = "(+ 1 2) )) @@@"
    position = :binary.match(source, "@@@") |> elem(0)

    assert {:error, {:parse_error, message, ^position}} = Parser.parse_with_position(source)
    assert message == "syntax error: could not parse expression at line 1, column 12"
  end

  test "closing delimiters in strings, regexes, characters, and comments remain data" do
    source = ~S"""
    [")]}" #"[)}]" \) \] \}]
    ; ) ] }
    42
    """

    assert {:ok, {:program, [{:vector, _values}, 42]}} = Parser.parse(source)
  end
end
