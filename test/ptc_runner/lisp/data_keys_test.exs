defmodule PtcRunner.Lisp.DataKeysTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.DataKeys
  alias PtcRunner.Lisp.Format.SymbolRef
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Parser

  describe "extract/1" do
    test "extracts single data key" do
      {:ok, ast} = parse_and_analyze("(count data/products)")
      assert DataKeys.extract(ast) == MapSet.new([:products])
    end

    test "extracts multiple data keys" do
      {:ok, ast} = parse_and_analyze("(+ (count data/products) (count data/orders))")
      assert DataKeys.extract(ast) == MapSet.new([:products, :orders])
    end

    test "extracts data keys from nested expressions" do
      code = """
      (def products data/products)
      (def filtered (filter :active products))
      (count filtered)
      """

      {:ok, ast} = parse_and_analyze(code)
      assert DataKeys.extract(ast) == MapSet.new([:products])
    end

    test "extracts data keys from let bindings" do
      code = """
      (let [prods data/products
            ords data/orders]
        (+ (count prods) (count ords)))
      """

      {:ok, ast} = parse_and_analyze(code)
      assert DataKeys.extract(ast) == MapSet.new([:products, :orders])
    end

    test "extracts data keys from threading macros" do
      code = """
      (->> data/employees
           (filter :remote)
           (count))
      """

      {:ok, ast} = parse_and_analyze(code)
      assert DataKeys.extract(ast) == MapSet.new([:employees])
    end

    test "extracts data keys from anonymous functions" do
      code = """
      (map (fn [x] (get data/config :key)) data/items)
      """

      {:ok, ast} = parse_and_analyze(code)
      assert DataKeys.extract(ast) == MapSet.new([:config, :items])
    end

    test "returns empty set when no data keys accessed" do
      {:ok, ast} = parse_and_analyze("(+ 1 2 3)")
      assert DataKeys.extract(ast) == MapSet.new()
    end

    test "treats literal payloads as opaque" do
      ast = {:literal, {:data, :secret}}

      assert DataKeys.extract(ast) == MapSet.new()
      assert DataKeys.prefilter_context(ast, %{secret: [1, 2, 3]}) == %{}
    end

    test "handles complex benchmark code" do
      code = """
      (def products data/products)
      (def products-with-metrics
        (map (fn [p]
               (assoc p :expected_revenue (* (:price p) (:stock p))))
             products))
      (def sorted (sort-by :expected_revenue > products-with-metrics))
      (return (first sorted))
      """

      {:ok, ast} = parse_and_analyze(code)
      assert DataKeys.extract(ast) == MapSet.new([:products])
    end
  end

  describe "filter_context/2" do
    test "filters context to only include accessed data keys" do
      {:ok, ast} = parse_and_analyze("(count data/products)")

      ctx = %{
        "products" => [1, 2, 3],
        "orders" => [4, 5, 6],
        "employees" => [7, 8, 9]
      }

      filtered = DataKeys.filter_context(ast, ctx)
      assert filtered == %{"products" => [1, 2, 3]}
    end

    test "preserves non-list context values" do
      {:ok, ast} = parse_and_analyze("(count data/products)")

      ctx = %{
        "products" => [1, 2, 3],
        "orders" => [4, 5, 6],
        "question" => "How many products?",
        "fail" => nil
      }

      filtered = DataKeys.filter_context(ast, ctx)

      assert filtered == %{
               "products" => [1, 2, 3],
               "question" => "How many products?",
               "fail" => nil
             }
    end

    test "handles atom keys in context" do
      {:ok, ast} = parse_and_analyze("(count data/products)")

      ctx = %{
        products: [1, 2, 3],
        orders: [4, 5, 6]
      }

      filtered = DataKeys.filter_context(ast, ctx)
      assert filtered == %{products: [1, 2, 3]}
    end

    test "returns empty map when no data keys match" do
      {:ok, ast} = parse_and_analyze("(+ 1 2)")

      ctx = %{
        "products" => [1, 2, 3],
        "orders" => [4, 5, 6]
      }

      filtered = DataKeys.filter_context(ast, ctx)
      assert filtered == %{}
    end

    test "handles multiple accessed data keys" do
      {:ok, ast} = parse_and_analyze("(+ (count data/products) (count data/orders))")

      ctx = %{
        "products" => [1, 2, 3],
        "orders" => [4, 5, 6],
        "employees" => [7, 8, 9]
      }

      filtered = DataKeys.filter_context(ast, ctx)
      assert filtered == %{"products" => [1, 2, 3], "orders" => [4, 5, 6]}
    end

    test "filters out unused large maps (not just lists)" do
      {:ok, ast} = parse_and_analyze("(count data/products)")

      ctx = %{
        "products" => [1, 2, 3],
        "lookup_table" => %{1 => "one", 2 => "two", 3 => "three"},
        "question" => "How many?"
      }

      filtered = DataKeys.filter_context(ast, ctx)
      # Large map "lookup_table" should be filtered out
      # Scalar "question" should be preserved
      assert filtered == %{"products" => [1, 2, 3], "question" => "How many?"}
    end

    test "filters out unused MapSets" do
      {:ok, ast} = parse_and_analyze("(count data/items)")

      ctx = %{
        "items" => [1, 2, 3],
        "seen_ids" => MapSet.new([1, 2, 3])
      }

      filtered = DataKeys.filter_context(ast, ctx)
      assert filtered == %{"items" => [1, 2, 3]}
    end

    test "retains unrenderable keys for bounded input handling" do
      {:ok, ast} = parse_and_analyze("nil")
      invalid_charlist = [0xD800]
      ctx = %{invalid_charlist => [1, 2, 3]}

      assert DataKeys.filter_context(ast, ctx) == ctx
    end

    test "defers symbol-reference key inspection to bounded input handling" do
      {:ok, ast} = parse_and_analyze("nil")
      symbol = %SymbolRef{name: "unused"}
      ctx = %{symbol => [1, 2, 3]}

      assert DataKeys.filter_context(ast, ctx) == ctx
    end

    test "filters normalized symbol-reference collections by their source spelling" do
      unused = {:symbol_ref, "unused"}
      used = {:symbol_ref, "used"}
      ctx = %{unused => [1, 2, 3], used => [4, 5, 6]}

      {:ok, no_data_ast} = parse_and_analyze("nil")
      assert DataKeys.filter_context(no_data_ast, ctx) == %{}

      {:ok, used_ast} = parse_and_analyze(~S|data/'used|)
      assert DataKeys.filter_context(used_ast, ctx) == %{used => [4, 5, 6]}
    end
  end

  describe "prefilter_context/2" do
    test "removes unused collection grants with ordinary host keys" do
      {:ok, ast} = parse_and_analyze("(count data/products)")

      ctx = %{
        "products" => [1, 2, 3],
        :unused => %{1 => "one"},
        "question" => "How many?"
      }

      assert DataKeys.prefilter_context(ast, ctx) == %{
               "products" => [1, 2, 3]
             }
    end

    test "drops unrelated unusual keys without enumerating the grant" do
      {:ok, ast} = parse_and_analyze("nil")
      charlist_key = ~c"unused"
      symbol_key = %SymbolRef{name: "unused"}
      ctx = %{charlist_key => [1, 2, 3], symbol_key => [4, 5, 6]}

      assert DataKeys.prefilter_context(ast, ctx) == %{}
    end

    test "retains referenced symbol-wrapper keys for bounded normalization" do
      {:ok, ast} = parse_and_analyze(~S|data/'used|)
      symbol_key = %SymbolRef{name: "used"}
      ctx = %{symbol_key => [1, 2, 3], %SymbolRef{name: "unused"} => [4, 5, 6]}

      assert DataKeys.prefilter_context(ast, ctx) == %{symbol_key => [1, 2, 3]}
    end

    test "quoted-symbol lookup is independent of existing VM atoms" do
      _existing_atom = :"'atom-table-quoted-key"
      symbol_key = %SymbolRef{name: "atom-table-quoted-key"}

      assert {:ok, %{return: 42}} =
               Lisp.run(~S|data/'atom-table-quoted-key|,
                 context: %{symbol_key => 42},
                 strict_data: true
               )
    end

    test "public runs retain every bounded key variant accepted by data lookup" do
      context = %{
        LispKeyword.new("foo") => 1,
        "foo_bar" => 2
      }

      assert {:ok, %{return: [1, 2]}} =
               Lisp.run("[data/foo data/foo-bar]", context: context, strict_data: true)
    end
  end

  # Helper to parse and analyze code
  defp parse_and_analyze(code) do
    with {:ok, raw_ast} <- Parser.parse(code) do
      Analyze.analyze(raw_ast)
    end
  end
end
