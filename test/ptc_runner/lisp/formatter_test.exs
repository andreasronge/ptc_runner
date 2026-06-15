defmodule PtcRunner.Lisp.FormatterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Formatter
  alias PtcRunner.Lisp.Parser

  describe "literals - nil, booleans, numbers" do
    test "nil" do
      assert Formatter.format(nil) == "nil"
    end

    test "true" do
      assert Formatter.format(true) == "true"
    end

    test "false" do
      assert Formatter.format(false) == "false"
    end

    test "integers" do
      assert Formatter.format(42) == "42"
      assert Formatter.format(-17) == "-17"
      assert Formatter.format(0) == "0"
    end

    test "floats" do
      formatted = Formatter.format(3.14)
      assert String.starts_with?(formatted, "3.14")

      formatted = Formatter.format(-0.5)
      assert String.starts_with?(formatted, "-0.5")
    end
  end

  describe "strings with escape sequences" do
    test "simple string" do
      assert Formatter.format({:string, "hello"}) == ~s("hello")
    end

    test "backslash escape" do
      assert Formatter.format({:string, "path\\to\\file"}) == ~s("path\\\\to\\\\file")
    end

    test "quote escape" do
      assert Formatter.format({:string, ~s(quote: ")}) == ~s("quote: \\"")
    end

    test "newline escape" do
      assert Formatter.format({:string, "line1\nline2"}) == ~s("line1\\nline2")
    end

    test "tab escape" do
      assert Formatter.format({:string, "col1\tcol2"}) == ~s("col1\\tcol2")
    end

    test "carriage return escape" do
      assert Formatter.format({:string, "line1\rline2"}) == ~s("line1\\rline2")
    end

    test "multiple escapes in one string" do
      assert Formatter.format({:string, "path\\to\n\"file\""}) ==
               ~s("path\\\\to\\n\\"file\\"")
    end
  end

  describe "keywords" do
    test "simple keyword" do
      assert Formatter.format({:keyword, :status}) == ":status"
    end

    test "keyword with special chars" do
      assert Formatter.format({:keyword, :user_id}) == ":user_id"
      assert Formatter.format({:keyword, :empty?}) == ":empty?"
      assert Formatter.format({:keyword, :valid!}) == ":valid!"
    end
  end

  describe "symbols" do
    test "simple symbol" do
      assert Formatter.format({:symbol, :filter}) == "filter"
    end

    test "symbol with special chars" do
      assert Formatter.format({:symbol, :"sort-by"}) == "sort-by"
      assert Formatter.format({:symbol, :empty?}) == "empty?"
      assert Formatter.format({:symbol, :+}) == "+"
    end
  end

  describe "namespaced symbols" do
    test "data namespace" do
      assert Formatter.format({:ns_symbol, :data, :input}) == "data/input"
    end

    test "generic namespace" do
      assert Formatter.format({:ns_symbol, :foo, :bar}) == "foo/bar"
    end
  end

  describe "vectors" do
    test "empty vector" do
      assert Formatter.format({:vector, []}) == "[]"
    end

    test "vector with integers" do
      assert Formatter.format({:vector, [1, 2, 3]}) == "[1 2 3]"
    end

    test "vector with mixed types" do
      assert Formatter.format({:vector, [1, {:keyword, :a}, {:symbol, :x}]}) ==
               "[1 :a x]"
    end

    test "nested vectors" do
      assert Formatter.format({:vector, [{:vector, [1, 2]}, {:vector, [3, 4]}]}) ==
               "[[1 2] [3 4]]"
    end
  end

  describe "maps" do
    test "empty map" do
      assert Formatter.format({:map, []}) == "{}"
    end

    test "map with keyword keys" do
      assert Formatter.format({:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]}) ==
               "{:a 1 :b 2}"
    end

    test "map with symbol values" do
      assert Formatter.format({:map, [{{:keyword, :op}, {:symbol, :filter}}]}) ==
               "{:op filter}"
    end
  end

  describe "sets" do
    test "empty set" do
      assert Formatter.format({:set, []}) == "#" <> "{}"
    end

    test "set with elements" do
      assert Formatter.format({:set, [1, 2, 3]}) == "#" <> "{1 2 3}"
    end

    test "set with mixed types" do
      assert Formatter.format({:set, [1, {:keyword, :a}, {:symbol, :x}]}) ==
               "#" <> "{1 :a x}"
    end

    test "nested set" do
      assert Formatter.format({:set, [{:set, [1, 2]}]}) == "#" <> "{#" <> "{1 2}}"
    end

    test "set containing vector" do
      assert Formatter.format({:set, [{:vector, [1, 2]}]}) == "#" <> "{[1 2]}"
    end
  end

  describe "lists (s-expressions)" do
    test "simple list" do
      assert Formatter.format({:list, [{:symbol, :+}, 1, 2]}) == "(+ 1 2)"
    end

    test "empty list" do
      assert Formatter.format({:list, []}) == "()"
    end

    test "list with multiple elements" do
      assert Formatter.format({:list, [{:symbol, :filter}, {:symbol, :x}, {:keyword, :y}]}) ==
               "(filter x :y)"
    end

    test "nested list" do
      assert Formatter.format(
               {:list,
                [
                  {:symbol, :filter},
                  {:list, [{:symbol, :fn}, {:vector, [{:symbol, :m}]}, {:keyword, :active}]},
                  {:symbol, :users}
                ]}
             ) == "(filter (fn [m] :active) users)"
    end
  end

  describe "roundtrip verification" do
    test "nil roundtrip" do
      ast = nil
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "integer roundtrip" do
      ast = 42
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "keyword roundtrip" do
      ast = {:keyword, :status}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "symbol roundtrip" do
      ast = {:symbol, :filter}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "namespaced symbol roundtrip" do
      ast = {:ns_symbol, :ctx, :input}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "vector roundtrip" do
      ast = {:vector, [1, 2, 3]}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "map roundtrip" do
      ast = {:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "list roundtrip" do
      ast = {:list, [{:symbol, :+}, 1, 2]}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "string with escapes roundtrip" do
      ast = {:string, "line1\nline2"}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "complex nested structure roundtrip" do
      ast =
        {:list,
         [
           {:symbol, :filter},
           {:vector, [{:keyword, :status}, {:symbol, :active}]},
           {:map, [{{:keyword, :limit}, 10}]}
         ]}

      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "set roundtrip" do
      ast = {:set, [1, 2, 3]}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "empty set roundtrip" do
      ast = {:set, []}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end

    test "nested set roundtrip" do
      ast = {:set, [{:set, [1, 2]}]}
      formatted = Formatter.format(ast)
      {:ok, parsed} = Parser.parse(formatted)
      assert Formatter.format(parsed) == formatted
    end
  end

  # These raw reader-macro nodes can appear verbatim in a prelude body, so the
  # `(source ...)` precompute (Formatter over the captured body form) must render
  # them. They were never exercised by the generated roundtrip property.
  describe "reader-macro literals (raw parser AST)" do
    test "anonymous short-fn #() roundtrips" do
      assert Formatter.format({:short_fn, [{:symbol, :*}, {:symbol, "%"}, 2]}) == "#(* % 2)"
      {:ok, parsed} = Parser.parse("#(* % 2)")
      assert Formatter.format(parsed) == "#(* % 2)"
    end

    test "regex literal #\"...\" roundtrips" do
      assert Formatter.format({:regex_literal, "ab+"}) == ~S(#"ab+")
      {:ok, parsed} = Parser.parse(~S(#"ab+"))
      assert Formatter.format(parsed) == ~S(#"ab+")
    end

    test "regex literal with escape-significant chars round-trips at the AST level" do
      # The body must be escaped with the parser's inverse, or these produce
      # malformed source. A quote inside a regex is the case codex flagged
      # (`#"a\"b"` parses to `a"b`); rendering it raw yields `#"a"b"` (unclosed).
      # `\n`/`\t` and a trailing backslash are the same class.
      for input <- [~S(#"a\"b"), ~S(#"\d+"), ~S(#"a\\"), ~S(#"line\n"), ~S(#"\t\d")] do
        {:ok, ast} = Parser.parse(input)
        rendered = Formatter.format(ast)
        assert {:ok, reparsed} = Parser.parse(rendered)

        assert reparsed == ast,
               "regex #{input} did not round-trip: rendered #{rendered}, reparsed #{inspect(reparsed)}"
      end
    end

    test "quoted symbol 'sym roundtrips" do
      assert Formatter.format({:quoted_symbol, "flag"}) == "'flag"
      {:ok, parsed} = Parser.parse("'flag")
      assert Formatter.format(parsed) == "'flag"
    end

    test "var-quote #'sym roundtrips" do
      {:ok, parsed} = Parser.parse("#'inc")
      assert Formatter.format(parsed) == "#'inc"
    end

    test "recent-result refs *1/*2/*3 roundtrip" do
      for ref <- ["*1", "*2", "*3"] do
        {:ok, parsed} = Parser.parse(ref)
        assert Formatter.format(parsed) == ref
      end
    end
  end
end
