defmodule PtcRunner.SubAgent.TypeExtractorTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.SubAgent.TypeExtractor

  alias PtcRunner.SubAgent.TypeExtractor
  alias PtcRunner.TypeExtractorFixtures, as: TestFunctions

  describe "extract/1" do
    test "extracts signature and description from simple function" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.get_time/0)

      assert signature == "() -> :string"
      assert description == "Get the current time"
    end

    test "extracts signature with multiple parameters" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.add/2)

      assert signature == "(a :int, b :int) -> :int"
      assert description == "Add two integers"
    end

    test "extracts signature with String.t() and list return" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.search/2)

      assert signature == "(query :string, limit :int) -> [:map]"
      assert description == "Search for items matching query"
    end

    test "extracts signature with structured map return" do
      {:ok, {signature, _description}} = TypeExtractor.extract(&TestFunctions.get_user/1)

      # Structured maps are now expanded to {field :type} format
      assert signature == "(id :int) -> {id :int, name :string}"
    end

    test "extracts signature with boolean return" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.positive?/1)

      assert signature == "(n :float) -> :bool"
      assert description == "Check if value is positive"
    end

    test "extracts signature with float parameters and return" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.calculate/2)

      assert signature == "(a :int, b :float) -> :float"
      assert description == "Function with float return"
    end

    test "extracts signature with list of integers" do
      {:ok, {signature, _description}} = TypeExtractor.extract(&TestFunctions.get_numbers/0)

      assert signature == "() -> [:int]"
    end

    test "extracts signature with any type" do
      {:ok, {signature, _description}} = TypeExtractor.extract(&TestFunctions.dynamic/1)

      assert signature == "(x :any) -> :any"
    end

    test "extracts signature with DateTime converted to string" do
      {:ok, {signature, _description}} = TypeExtractor.extract(&TestFunctions.get_datetime/0)

      assert signature == "() -> :string"
    end

    test "extracts signature with untyped map" do
      {:ok, {signature, _description}} = TypeExtractor.extract(&TestFunctions.get_config/0)

      assert signature == "() -> :map"
    end

    test "extracts only first line of multi-line documentation" do
      {:ok, {_signature, description}} = TypeExtractor.extract(&TestFunctions.multi_line_doc/1)

      assert description == "Multi-line documentation."
    end

    test "returns signature but nil description when @doc is missing" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.no_doc_function/1)

      assert signature == "(_ :string) -> :keyword"
      assert description == nil
    end

    test "returns description but nil signature when @spec is missing" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.no_spec_function/1)

      assert signature == nil
      assert description == "Function with no spec"
    end

    test "returns nil for both when @doc and @spec are missing" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.no_doc_no_spec/1)

      assert signature == nil
      assert description == nil
    end

    test "returns nil for anonymous functions" do
      anon_fn = fn x -> x * 2 end
      {:ok, {signature, description}} = TypeExtractor.extract(anon_fn)

      assert signature == nil
      assert description == nil
    end

    test "handles standard library functions" do
      # String.upcase/1 has @doc and @spec in Elixir stdlib
      {:ok, {signature, description}} = TypeExtractor.extract(&String.upcase/1)

      # Should extract something, even if basic
      assert is_binary(signature) or is_nil(signature)
      assert is_binary(description) or is_nil(description)
    end

    test "handles functions from modules without compiled docs gracefully" do
      # Create a function from a module that might not have docs
      # Should not crash, should return nil
      {:ok, {signature, description}} = TypeExtractor.extract(&Enum.map/2)

      # Should handle gracefully - either extract or return nil
      assert (is_binary(signature) and is_binary(description)) or
               (is_nil(signature) and is_nil(description)) or
               (is_binary(signature) and is_nil(description)) or
               (is_nil(signature) and is_binary(description))
    end

    test "uses highest arity spec when multiple specs exist" do
      # filter_items has @spec with arity 1 and arity 2
      # Should use the highest arity (2)
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.filter_items/2)

      assert signature == "(query :string, limit :int) -> [:map]"
      assert description == "Function with multiple specs"
    end

    test "expands custom @type definitions" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.get_custom_user/1)

      # user() type should be expanded to {id :int, name :string}
      assert signature == "(id :int) -> {id :int, name :string}"
      assert description == "Function using custom type"
    end

    test "expands nested custom types" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.get_nested/1)

      # nested_type() should expand user() within it
      assert signature == "(id :int) -> {user {id :int, name :string}, created_at :string}"
      assert description == "Function with nested custom type"
    end

    test "expands list of custom types" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.list_users/0)

      # user_list() -> [user()] -> [{id :int, name :string}]
      assert signature == "() -> [{id :int, name :string}]"
      assert description == "Function with list of custom types"
    end

    test "falls back to :any for opaque types" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.get_secret/0)

      # Opaque types cannot be expanded
      assert signature == "() -> :any"
      assert description == "Function with opaque type"
    end

    test "respects max depth limit of 3" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.get_deep/0)

      # Should expand to depth 3, then fall back to :any for level4
      # level1 -> {data level2} (depth 0 -> 1)
      # level2 -> {data level3} (depth 1 -> 2)
      # level3 -> {data level4} (depth 2 -> 3)
      # level4 -> :any (depth 3, max reached)
      assert signature == "() -> {data {data {data :any}}}"
      assert description == "Function with deeply nested type"
    end

    test "falls back to :any for self-referential types" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.get_tree/0)

      # Self-referential tree type expands to depth 3, then falls back to :any
      # tree -> {value :int, children [tree]} (depth 0 -> 1)
      # tree -> {value :int, children [tree]} (depth 1 -> 2)
      # tree -> {value :int, children [tree]} (depth 2 -> 3)
      # tree -> :any (depth 3, max reached)
      assert signature ==
               "() -> {value :int, children [{value :int, children [{value :int, children [:any]}]}]}"

      assert description == "Function with self-referential type"
    end

    test "converts {:ok, map()} | {:error, atom()} union to result/error format" do
      {:ok, {signature, description}} =
        TypeExtractor.extract(&TestFunctions.get_user_result/1)

      # {:ok, map()} | {:error, atom()} -> {result :map, error :keyword?}
      assert signature == "(id :int) -> {result :map, error :keyword?}"
      assert description == "Function with {:ok, map()} | {:error, atom()} union"
    end

    test "converts {:ok, user()} | {:error, atom()} union with custom type expansion" do
      {:ok, {signature, description}} =
        TypeExtractor.extract(&TestFunctions.get_custom_user_result/1)

      # {:ok, user()} | {:error, atom()} -> {result {id :int, name :string}, error :keyword?}
      assert signature == "(id :int) -> {result {id :int, name :string}, error :keyword?}"
      assert description == "Function with {:ok, user()} | {:error, atom()} union"
    end

    test "converts {:ok, String.t()} | {:error, binary()} union" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.fetch_data/1)

      # {:ok, String.t()} | {:error, binary()} -> {result :string, error :string?}
      assert signature == "(key :string) -> {result :string, error :string?}"
      assert description == "Function with {:ok, String.t()} | {:error, binary()} union"
    end

    test "falls back to :any for non-ok/error union types" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.get_status/0)

      # :active | :inactive is not a {:ok, t} | {:error, e} pattern
      assert signature == "() -> :any"
      assert description == "Function with non-ok/error union"
    end

    test "converts String.t() | nil to :string?" do
      {:ok, {signature, description}} = TypeExtractor.extract(&TestFunctions.get_optional_name/0)

      assert signature == "() -> :string?"
      assert description == "Function with String.t() | nil return"
    end

    test "converts nil | integer() to :int?" do
      {:ok, {signature, description}} =
        TypeExtractor.extract(&TestFunctions.get_optional_count/0)

      assert signature == "() -> :int?"
      assert description == "Function with nil | integer() return"
    end
  end

  describe "integration with Tool.new/2" do
    test "bare function reference extracts metadata" do
      {:ok, tool} = PtcRunner.Tool.new("get_time", &TestFunctions.get_time/0)

      assert tool.name == "get_time"
      assert tool.signature == "() -> :string"
      assert tool.description == "Get the current time"
      assert tool.type == :native
    end

    test "bare function with parameters extracts metadata" do
      {:ok, tool} = PtcRunner.Tool.new("add", &TestFunctions.add/2)

      assert tool.name == "add"
      assert tool.signature == "(a :int, b :int) -> :int"
      assert tool.description == "Add two integers"
      assert tool.type == :native
    end

    test "anonymous function has nil metadata" do
      {:ok, tool} = PtcRunner.Tool.new("anon", fn x -> x end)

      assert tool.name == "anon"
      assert tool.signature == nil
      assert tool.description == nil
      assert tool.type == :native
    end

    test "explicit signature overrides extracted signature" do
      explicit_sig = "(x :int, y :int) -> :float"
      {:ok, tool} = PtcRunner.Tool.new("add", {&TestFunctions.add/2, explicit_sig})

      assert tool.signature == explicit_sig
      # Description is not extracted when explicit signature is provided
      assert tool.description == nil
    end

    test "keyword options override extracted metadata" do
      options = [
        signature: "(custom :string) -> :int",
        description: "Custom description"
      ]

      {:ok, tool} = PtcRunner.Tool.new("custom", {&TestFunctions.add/2, options})

      assert tool.signature == "(custom :string) -> :int"
      assert tool.description == "Custom description"
    end
  end
end
