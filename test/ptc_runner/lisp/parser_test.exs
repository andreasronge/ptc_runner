defmodule PtcRunner.Lisp.ParserTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Parser

  describe "literals" do
    test "nil" do
      assert {:ok, nil} = Parser.parse("nil")
    end

    test "booleans" do
      assert {:ok, true} = Parser.parse("true")
      assert {:ok, false} = Parser.parse("false")
    end

    test "integers" do
      assert {:ok, 42} = Parser.parse("42")
      assert {:ok, -17} = Parser.parse("-17")
      assert {:ok, 0} = Parser.parse("0")
    end

    test "floats" do
      assert {:ok, 3.14} = Parser.parse("3.14")
      assert {:ok, -0.5} = Parser.parse("-0.5")
      assert {:ok, 2.5e10} = Parser.parse("2.5e10")
    end

    test "strings" do
      assert {:ok, {:string, "hello"}} = Parser.parse(~s("hello"))
      assert {:ok, {:string, "line1\nline2"}} = Parser.parse(~s("line1\\nline2"))
      assert {:ok, {:string, "quote: \""}} = Parser.parse(~s("quote: \\""))
    end

    test "keywords" do
      assert {:ok, {:keyword, :name}} = Parser.parse(":name")
      assert {:ok, {:keyword, :user_id}} = Parser.parse(":user_id")
      assert {:ok, {:keyword, :empty?}} = Parser.parse(":empty?")
      assert {:ok, {:keyword, :valid!}} = Parser.parse(":valid!")
    end

    test "characters" do
      assert {:ok, {:string, "r"}} = Parser.parse("\\r")
      assert {:ok, {:string, "\n"}} = Parser.parse("\\newline")
      assert {:ok, {:string, " "}} = Parser.parse("\\space")
      assert {:ok, {:string, "\t"}} = Parser.parse("\\tab")
      assert {:ok, {:string, "\r"}} = Parser.parse("\\return")
      assert {:ok, {:string, "\b"}} = Parser.parse("\\backspace")
      assert {:ok, {:string, "\f"}} = Parser.parse("\\formfeed")
      assert {:ok, {:string, "a"}} = Parser.parse("\\a")
      assert {:ok, {:string, "A"}} = Parser.parse("\\A")
      assert {:ok, {:string, "3"}} = Parser.parse("\\3")
      assert {:ok, {:string, "λ"}} = Parser.parse("\\λ")
    end
  end

  describe "symbols" do
    test "simple symbols" do
      assert {:ok, {:symbol, :filter}} = Parser.parse("filter")
      assert {:ok, {:symbol, :"sort-by"}} = Parser.parse("sort-by")
      assert {:ok, {:symbol, :empty?}} = Parser.parse("empty?")
    end

    test "operator symbols" do
      assert {:ok, {:symbol, :+}} = Parser.parse("+")
      assert {:ok, {:symbol, :"->>"}} = Parser.parse("->>")
      assert {:ok, {:symbol, :>=}} = Parser.parse(">=")
    end

    test "namespaced symbols" do
      assert {:ok, {:ns_symbol, :ctx, :input}} = Parser.parse("ctx/input")
      assert {:ok, {:ns_symbol, :foo, :bar}} = Parser.parse("foo/bar")
    end

    test "Clojure-style namespaced symbols with dots" do
      assert {:ok, {:ns_symbol, :"clojure.string", :join}} = Parser.parse("clojure.string/join")
      assert {:ok, {:ns_symbol, :"clojure.core", :map}} = Parser.parse("clojure.core/map")
      assert {:ok, {:ns_symbol, :"clojure.set", :union}} = Parser.parse("clojure.set/union")
    end

    test "nil/true/false don't match as prefixes" do
      # "nilly" should be a symbol, not nil + "ly"
      assert {:ok, {:symbol, :nilly}} = Parser.parse("nilly")
      assert {:ok, {:symbol, :truthy}} = Parser.parse("truthy")
    end
  end

  describe "collections" do
    test "empty vector" do
      assert {:ok, {:vector, []}} = Parser.parse("[]")
    end

    test "vector with elements" do
      assert {:ok, {:vector, [1, 2, 3]}} = Parser.parse("[1 2 3]")
    end

    test "nested vectors" do
      assert {:ok, {:vector, [{:vector, [1, 2]}, {:vector, [3, 4]}]}} =
               Parser.parse("[[1 2] [3 4]]")
    end

    test "empty map" do
      assert {:ok, {:map, []}} = Parser.parse("{}")
    end

    test "map with entries" do
      assert {:ok, {:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]}} =
               Parser.parse("{:a 1 :b 2}")
    end

    test "list (s-expression)" do
      assert {:ok, {:list, [{:symbol, :+}, 1, 2]}} = Parser.parse("(+ 1 2)")
    end

    test "nested list" do
      assert {:ok,
              {:list,
               [
                 {:symbol, :filter},
                 {:list, [{:symbol, :where}, {:keyword, :active}, {:symbol, :=}, true]},
                 {:symbol, :users}
               ]}} = Parser.parse("(filter (where :active = true) users)")
    end

    test "empty set" do
      set_empty = "#" <> "{}"
      assert {:ok, {:set, []}} = Parser.parse(set_empty)
    end

    test "set with elements" do
      set_elems = "#" <> "{1 2 3}"
      assert {:ok, {:set, [1, 2, 3]}} = Parser.parse(set_elems)
    end

    test "set with keywords" do
      set_kw = "#" <> "{:a :b}"
      assert {:ok, {:set, [{:keyword, :a}, {:keyword, :b}]}} = Parser.parse(set_kw)
    end

    test "nested set" do
      set_nested = "#" <> "{#" <> "{1 2}}"
      assert {:ok, {:set, [{:set, [1, 2]}]}} = Parser.parse(set_nested)
    end

    test "set containing vector" do
      set_vec = "#" <> "{[1 2]}"
      assert {:ok, {:set, [{:vector, [1, 2]}]}} = Parser.parse(set_vec)
    end

    test "set with whitespace and commas" do
      set_ws = "#" <> "{ 1 , 2 , 3 }"
      assert {:ok, {:set, [1, 2, 3]}} = Parser.parse(set_ws)
    end

    test "set containing map" do
      set_map = "#" <> "{:a {:b 1}}"

      assert {:ok, {:set, [{:keyword, :a}, {:map, [{{:keyword, :b}, 1}]}]}} =
               Parser.parse(set_map)
    end

    test "set with mixed types" do
      set_mixed = "#" <> "{:a \"b\" 3}"
      assert {:ok, {:set, [{:keyword, :a}, {:string, "b"}, 3]}} = Parser.parse(set_mixed)
    end
  end

  describe "whitespace and comments" do
    test "ignores whitespace" do
      assert {:ok, {:vector, [1, 2, 3]}} = Parser.parse("  [ 1  2  3 ]  ")
    end

    test "commas as whitespace" do
      assert {:ok, {:vector, [1, 2, 3]}} = Parser.parse("[1, 2, 3]")
    end

    test "ignores comments" do
      assert {:ok, 42} = Parser.parse("; this is a comment\n42")

      assert {:ok, {:list, [{:symbol, :+}, 1, 2]}} =
               Parser.parse("(+ 1 ; inline comment\n 2)")
    end
  end

  describe "complex expressions" do
    test "threading macro" do
      source = """
      (->> ctx/products
           (filter (where :in-stock))
           (sort-by :price)
           (take 10))
      """

      assert {:ok, {:list, [{:symbol, :"->>"}, {:ns_symbol, :ctx, :products} | _]}} =
               Parser.parse(source)
    end

    test "let with destructuring" do
      source = "(let [{:keys [name age]} user] name)"
      assert {:ok, {:list, [{:symbol, :let} | _]}} = Parser.parse(source)
    end
  end

  describe "error cases" do
    test "unclosed vector" do
      assert {:error, {:parse_error, _}} = Parser.parse("[1 2 3")
    end

    test "unclosed string" do
      assert {:error, {:parse_error, _}} = Parser.parse(~s("hello))
    end

    test "odd number of map elements returns error tuple" do
      # Consistent error handling - no exceptions escape parse/1
      assert {:error, {:parse_error, _}} = Parser.parse("{:a 1 :b}")
    end

    test "namespaced keywords are not supported" do
      # Spec: "no namespaced keywords like :foo/bar"
      # Parses as two separate tokens: :foo and /bar (a symbol)
      assert {:ok, {:program, [{:keyword, :foo}, {:symbol, :"/bar"}]}} = Parser.parse(":foo/bar")
    end

    test "quoted lists are rejected" do
      # Spec: "NO lists '(1 2 3)"
      assert {:error, {:parse_error, _}} = Parser.parse("'(1 2 3)")
    end

    test "multiline strings are rejected" do
      # Single-line strings only
      assert {:error, {:parse_error, _}} = Parser.parse("\"hello\nworld\"")
    end

    test "unclosed set returns error" do
      unclosed_set = "#" <> "{1 2 3"
      assert {:error, {:parse_error, _}} = Parser.parse(unclosed_set)
    end

    test "space between # and { is invalid" do
      assert {:error, {:parse_error, _}} = Parser.parse("# {1 2}")
    end

    test "regex literals are rejected with helpful error" do
      assert {:error, {:parse_error, message}} = Parser.parse(~S|(split "a b" #" ")|)
      assert message =~ "regex literals"
      assert message =~ "not supported"
    end
  end

  describe "numeric edge cases" do
    test "leading decimal point is invalid" do
      assert {:error, {:parse_error, _}} = Parser.parse(".5")
    end

    test "trailing decimal point is invalid" do
      assert {:error, {:parse_error, _}} = Parser.parse("5.")
    end

    test "exponent without decimal parses as two tokens" do
      # We require digits.digits before exponent for scientific notation
      # Without decimal, parses as integer followed by symbol
      assert {:ok, {:program, [2, {:symbol, :e10}]}} = Parser.parse("2e10")
    end

    test "positive sign on numbers" do
      # +5 parses as symbol, not number
      assert {:ok, {:symbol, :"+5"}} = Parser.parse("+5")
    end
  end

  describe "symbol boundary edge cases" do
    test "nil? is a symbol not nil" do
      assert {:ok, {:symbol, :nil?}} = Parser.parse("nil?")
    end

    test "true? is a symbol not true" do
      assert {:ok, {:symbol, :true?}} = Parser.parse("true?")
    end

    test "false-positive is a symbol not false" do
      assert {:ok, {:symbol, :"false-positive"}} = Parser.parse("false-positive")
    end

    test "nilly is a symbol not nil" do
      assert {:ok, {:symbol, :nilly}} = Parser.parse("nilly")
    end
  end

  describe "var reader syntax #'" do
    test "simple var" do
      assert {:ok, {:var, :x}} = Parser.parse("#'x")
    end

    test "var with question mark" do
      assert {:ok, {:var, :suspicious?}} = Parser.parse("#'suspicious?")
    end

    test "var with bang" do
      assert {:ok, {:var, :save!}} = Parser.parse("#'save!")
    end

    test "var with underscore" do
      assert {:ok, {:var, :my_var}} = Parser.parse("#'my_var")
    end

    test "var with hyphen" do
      assert {:ok, {:var, :"my-var"}} = Parser.parse("#'my-var")
    end

    test "var in collection" do
      assert {:ok, {:vector, [{:var, :x}, {:var, :y}]}} = Parser.parse("[#'x #'y]")
    end

    test "var in map value" do
      assert {:ok, {:map, [{{:keyword, :result}, {:var, :foo}}]}} =
               Parser.parse("{:result #'foo}")
    end

    test "invalid var - number" do
      assert {:error, {:parse_error, _}} = Parser.parse("#'123")
    end

    test "invalid var - missing symbol" do
      assert {:error, {:parse_error, _}} = Parser.parse("#'")
    end
  end

  describe "short function syntax #()" do
    test "empty short function" do
      assert {:ok, {:short_fn, []}} = Parser.parse("#()")
    end

    test "short function with single placeholder" do
      assert {:ok, {:short_fn, [{:symbol, :%}]}} = Parser.parse("#(%)")
    end

    test "short function with arithmetic" do
      assert {:ok, {:short_fn, [{:symbol, :+}, {:symbol, :%}, 1]}} = Parser.parse("#(+ % 1)")
    end

    test "short function with numeric placeholders" do
      assert {:ok, {:short_fn, [{:symbol, :+}, {:symbol, :"%1"}, {:symbol, :"%2"}]}} =
               Parser.parse("#(+ %1 %2)")
    end

    test "short function with multiple uses of same placeholder" do
      assert {:ok, {:short_fn, [{:symbol, :*}, {:symbol, :%}, {:symbol, :%}]}} =
               Parser.parse("#(* % %)")
    end

    test "short function with whitespace and formatting" do
      assert {:ok, {:short_fn, [{:symbol, :+}, {:symbol, :%}, 1]}} =
               Parser.parse("#(  +  %  1  )")
    end

    test "short function can be nested in lists" do
      assert {:ok,
              {:list,
               [
                 {:symbol, :filter},
                 {:short_fn, [{:symbol, :>}, {:symbol, :%}, 10]},
                 {:vector, [5, 15]}
               ]}} = Parser.parse("(filter #(> % 10) [5 15])")
    end

    test "set literal still parses correctly" do
      assert {:ok, {:set, [1, 2, 3]}} = Parser.parse("#" <> "{1 2 3}")
    end

    test "placeholder symbols parse outside #()" do
      assert {:ok, {:symbol, :%}} = Parser.parse("%")
      assert {:ok, {:symbol, :"%1"}} = Parser.parse("%1")
      assert {:ok, {:symbol, :"%2"}} = Parser.parse("%2")
    end
  end

  describe "multiple top-level expressions" do
    test "single expression returns unwrapped (backward compatible)" do
      assert {:ok, 42} = Parser.parse("42")
      assert {:ok, {:symbol, :x}} = Parser.parse("x")
    end

    test "multiple expressions return {:program, list}" do
      assert {:ok, {:program, [1, 2, 3]}} = Parser.parse("1 2 3")
    end

    test "empty input returns nil" do
      assert {:ok, nil} = Parser.parse("")
      assert {:ok, nil} = Parser.parse("   ")
    end

    test "comment-only input returns nil" do
      assert {:ok, nil} = Parser.parse("; just a comment")
      assert {:ok, nil} = Parser.parse("; comment\n; another")
    end

    test "multiple expressions with complex forms" do
      source = "(def x 1) (def y 2) (+ x y)"
      assert {:ok, {:program, [_, _, _]}} = Parser.parse(source)
    end

    test "multiple expressions with newlines" do
      source = """
      (def x 1)
      (def y 2)
      (+ x y)
      """

      assert {:ok, {:program, [_, _, _]}} = Parser.parse(source)
    end

    test "expressions with comments between them" do
      source = """
      (def x 1) ; define x
      (def y 2) ; define y
      (+ x y)   ; result
      """

      assert {:ok, {:program, [_, _, _]}} = Parser.parse(source)
    end
  end
end
