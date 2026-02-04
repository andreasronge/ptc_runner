defmodule PtcRunner.SubAgent.SignatureTest do
  use ExUnit.Case

  alias PtcRunner.SubAgent.Signature

  describe "parse/1" do
    test "parses simple signature" do
      assert {:ok, sig} = Signature.parse("(id :int) -> :string")
      assert sig == {:signature, [{"id", :int}], :string}
    end

    test "parses shorthand signature" do
      assert {:ok, sig} = Signature.parse("{count :int}")
      assert sig == {:signature, [], {:map, [{"count", :int}]}}
    end

    test "handles invalid input" do
      assert {:error, _} = Signature.parse("invalid")
    end

    test "rejects non-string input" do
      assert {:error, _} = Signature.parse(123)
    end
  end

  describe "validate/2" do
    test "validates correct output" do
      {:ok, sig} = Signature.parse("() -> {count :int, items [:string]}")

      assert :ok = Signature.validate(sig, %{count: 5, items: ["a", "b"]})
    end

    test "rejects invalid output" do
      {:ok, sig} = Signature.parse("() -> :int")

      assert {:error, _} = Signature.validate(sig, "not an int")
    end

    test "validates complex nested structure" do
      {:ok, sig} =
        Signature.parse("(query :string) -> {results [{id :int, title :string, tags [:string]}]}")

      assert :ok =
               Signature.validate(sig, %{
                 results: [
                   %{id: 1, title: "Result 1", tags: ["tag1", "tag2"]},
                   %{id: 2, title: "Result 2", tags: []}
                 ]
               })
    end
  end

  describe "validate_input/2" do
    test "validates input parameters" do
      {:ok, sig} = Signature.parse("(id :int, name :string) -> :bool")

      assert :ok = Signature.validate_input(sig, %{id: 42, name: "Alice"})
    end

    test "rejects missing parameter" do
      {:ok, sig} = Signature.parse("(id :int, name :string) -> :bool")

      assert {:error, _} = Signature.validate_input(sig, %{id: 42})
    end

    test "rejects wrong parameter type" do
      {:ok, sig} = Signature.parse("(id :int) -> :bool")

      assert {:error, _} = Signature.validate_input(sig, %{id: "not an int"})
    end
  end

  describe "render/1" do
    test "renders simple signature" do
      sig = {:signature, [{"id", :int}], :string}
      assert "(id :int) -> :string" = Signature.render(sig)
    end

    test "renders signature with no parameters" do
      sig = {:signature, [], :string}
      assert "-> :string" = Signature.render(sig)
    end

    test "renders signature with optional field" do
      sig = {:signature, [], {:map, [{"email", {:optional, :string}}]}}
      assert "-> {email :string?}" = Signature.render(sig)
    end

    test "renders signature with list" do
      sig = {:signature, [], {:list, :int}}
      assert "-> [:int]" = Signature.render(sig)
    end

    test "renders complex signature" do
      sig =
        {:signature, [{"query", :string}, {"limit", :int}],
         {:map, [{"count", :int}, {"items", {:list, {:map, [{"id", :int}]}}}]}}

      rendered = Signature.render(sig)
      assert rendered =~ "query :string"
      assert rendered =~ "limit :int"
      assert rendered =~ "count :int"
      assert rendered =~ "items"
      assert rendered =~ "[{id :int}]"
    end
  end

  describe "round-trip - parse then render" do
    test "simple signature" do
      original = "(id :int) -> :string"
      {:ok, parsed} = Signature.parse(original)
      rendered = Signature.render(parsed)
      assert original == rendered
    end

    test "complex signature" do
      original = "(query :string, limit :int) -> {count :int, items [:string]}"
      {:ok, parsed} = Signature.parse(original)
      rendered = Signature.render(parsed)
      assert original == rendered
    end

    test "shorthand signature" do
      original = "{count :int}"
      {:ok, parsed} = Signature.parse(original)
      rendered = Signature.render(parsed)

      # Shorthand is rendered as "-> {...}" since no params
      assert "-> {count :int}" == rendered
    end
  end

  describe "spec examples" do
    test "search example" do
      {:ok, sig} = Signature.parse("(query :string, limit :int) -> [{id :int, title :string}]")

      assert :ok =
               Signature.validate(sig, [
                 %{id: 1, title: "Result 1"},
                 %{id: 2, title: "Result 2"}
               ])
    end

    test "get_user example" do
      {:ok, sig} = Signature.parse("(id :int) -> {name :string, email :string?}")

      assert :ok = Signature.validate(sig, %{name: "Alice", email: "alice@example.com"})
      assert :ok = Signature.validate(sig, %{name: "Bob", email: nil})
    end

    test "empty map example" do
      {:ok, sig} = Signature.parse("{}")
      assert :ok = Signature.validate(sig, %{})
    end

    test "any type example" do
      {:ok, sig} = Signature.parse(":any")
      assert :ok = Signature.validate(sig, "anything")
      assert :ok = Signature.validate(sig, 42)
      assert :ok = Signature.validate(sig, %{})
    end

    test "firewalled field example" do
      {:ok, sig} = Signature.parse("() -> {summary :string, count :int, _email_ids [:int]}")

      assert :ok =
               Signature.validate(sig, %{summary: "Found items", count: 5, _email_ids: [1, 2, 3]})
    end

    test "nested structure example" do
      {:ok, sig} =
        Signature.parse("() -> {user {id :int, profile {bio :string, avatar :string?}}}")

      assert :ok =
               Signature.validate(sig, %{
                 user: %{
                   id: 1,
                   profile: %{bio: "Developer", avatar: "http://example.com/avatar.jpg"}
                 }
               })

      assert :ok =
               Signature.validate(sig, %{
                 user: %{
                   id: 1,
                   profile: %{bio: "Developer", avatar: nil}
                 }
               })
    end
  end

  describe "error messages are helpful" do
    test "shows path for nested error" do
      {:ok, sig} =
        Signature.parse("() -> {results [{id :int}]}")

      {:error, errors} = Signature.validate(sig, %{results: [%{id: "not int"}]})

      assert errors != []

      assert Enum.any?(errors, fn err ->
               Enum.at(err.path, 0) == "results" and Enum.at(err.path, 1) == 0
             end)
    end

    test "invalid type in signature includes hint about valid types" do
      {:error, message} = Signature.parse("(pending :list) -> :bool")

      assert message =~ "Hint: Valid types are"
      assert message =~ ":string"
      assert message =~ ":int"
      assert message =~ "[:type]"
    end

    test "other invalid types also include hint" do
      {:error, message} = Signature.parse("(items :array) -> :bool")

      assert message =~ "Hint: Valid types are"
    end
  end

  describe "to_json_schema/1" do
    test "converts simple primitive return type" do
      {:ok, sig} = Signature.parse("() -> :string")
      assert %{"type" => "string"} = Signature.to_json_schema(sig)
    end

    test "converts object with required fields" do
      {:ok, sig} = Signature.parse("() -> {sentiment :string, score :float}")
      schema = Signature.to_json_schema(sig)

      assert schema["type"] == "object"
      assert schema["properties"]["sentiment"] == %{"type" => "string"}
      assert schema["properties"]["score"] == %{"type" => "number"}
      assert schema["required"] == ["sentiment", "score"]
      assert schema["additionalProperties"] == false
    end

    test "handles optional fields" do
      {:ok, sig} = Signature.parse("() -> {name :string, nickname :string?}")
      schema = Signature.to_json_schema(sig)

      assert schema["required"] == ["name"]
      assert schema["properties"]["nickname"] == %{"type" => "string"}
    end

    test "handles nested maps" do
      {:ok, sig} = Signature.parse("() -> {analysis {sentiment :string, score :float}}")
      schema = Signature.to_json_schema(sig)

      analysis = schema["properties"]["analysis"]
      assert analysis["type"] == "object"
      assert analysis["properties"]["sentiment"] == %{"type" => "string"}
      assert analysis["properties"]["score"] == %{"type" => "number"}
    end

    test "handles arrays (wrapped in object for LLM compatibility)" do
      {:ok, sig} = Signature.parse("() -> [:string]")
      schema = Signature.to_json_schema(sig)

      # Array schemas are wrapped in object because most LLM providers require object at root
      assert schema["type"] == "object"
      assert schema["properties"]["items"]["type"] == "array"
      assert schema["properties"]["items"]["items"] == %{"type" => "string"}
    end

    test "handles arrays of objects (wrapped in object for LLM compatibility)" do
      {:ok, sig} = Signature.parse("() -> [{id :int, name :string}]")
      schema = Signature.to_json_schema(sig)

      # Array schemas are wrapped in object because most LLM providers require object at root
      assert schema["type"] == "object"
      assert schema["properties"]["items"]["type"] == "array"
      assert schema["properties"]["items"]["items"]["type"] == "object"
      assert schema["properties"]["items"]["items"]["properties"]["id"] == %{"type" => "integer"}
    end

    test "converts all primitive types correctly" do
      type_mappings = [
        {":string", %{"type" => "string"}},
        {":int", %{"type" => "integer"}},
        {":float", %{"type" => "number"}},
        {":bool", %{"type" => "boolean"}},
        {":any", %{"type" => "object"}},
        {":map", %{"type" => "object"}},
        {":keyword", %{"type" => "string"}}
      ]

      for {sig_type, expected} <- type_mappings do
        {:ok, sig} = Signature.parse("() -> #{sig_type}")
        assert Signature.to_json_schema(sig) == expected, "Failed for #{sig_type}"
      end
    end

    test "ignores input parameters (only converts output)" do
      {:ok, sig} = Signature.parse("(text :string, count :int) -> {result :bool}")
      schema = Signature.to_json_schema(sig)

      # Should only have the output schema, not input params
      assert schema["properties"] == %{"result" => %{"type" => "boolean"}}
    end

    test "handles empty map" do
      {:ok, sig} = Signature.parse("() -> {}")
      schema = Signature.to_json_schema(sig)

      assert schema == %{
               "type" => "object",
               "properties" => %{},
               "required" => [],
               "additionalProperties" => false
             }
    end

    test ":any signature generates valid schema for Bedrock (must have type field)" do
      # BUG: Bedrock requires input_schema to have a "type" field.
      # Currently :any returns %{} which causes Bedrock API error:
      # "tools.0.custom.input_schema.type: Field required"
      #
      # This affects synthesis gates which use `signature: ":any"` for JSON mode.
      {:ok, sig} = Signature.parse("() -> :any")
      schema = Signature.to_json_schema(sig)

      # Schema must have a type field for Bedrock compatibility
      assert Map.has_key?(schema, "type"),
             ":any schema must have 'type' field for Bedrock compatibility (currently returns #{inspect(schema)})"
    end
  end
end
