defmodule PtcRunner.SchemaTest do
  use ExUnit.Case

  describe "Schema module" do
    test "operations/0 returns a map" do
      operations = PtcRunner.Schema.operations()
      assert is_map(operations)
      assert map_size(operations) == 42
    end

    test "valid_operation_names/0 returns 42 operation names in sorted order" do
      names = PtcRunner.Schema.valid_operation_names()

      assert is_list(names)
      assert length(names) == 42
      assert names == Enum.sort(names)

      expected_ops =
        ~w(and avg call concat contains count distinct drop eq filter first get gt gte if keys last let literal load lt lte map max max_by merge min min_by neq not nth object or pipe reject select sort_by sum take typeof var zip)

      assert Enum.sort(names) == expected_ops
    end

    test "get_operation/1 returns operation definition for valid operation" do
      {:ok, literal_def} = PtcRunner.Schema.get_operation("literal")

      assert is_map(literal_def)

      assert literal_def["description"] ==
               "A literal JSON value. Example: {op:'literal', value:42}"

      assert is_map(literal_def["fields"])
    end

    test "get_operation/1 returns :error for unknown operation" do
      assert PtcRunner.Schema.get_operation("unknown") == :error
    end

    test "get_operation/1 returns :error for non-string input" do
      assert PtcRunner.Schema.get_operation(123) == :error
      assert PtcRunner.Schema.get_operation(nil) == :error
      assert PtcRunner.Schema.get_operation(%{}) == :error
    end
  end

  describe "Data operations" do
    test "literal has required 'value' field" do
      {:ok, def} = PtcRunner.Schema.get_operation("literal")
      assert def["fields"]["value"]["required"] == true
      assert def["fields"]["value"]["type"] == :any
    end

    test "load has required 'name' field" do
      {:ok, def} = PtcRunner.Schema.get_operation("load")
      assert def["fields"]["name"]["required"] == true
      assert def["fields"]["name"]["type"] == :string
    end

    test "var has required 'name' field" do
      {:ok, def} = PtcRunner.Schema.get_operation("var")
      assert def["fields"]["name"]["required"] == true
      assert def["fields"]["name"]["type"] == :string
    end
  end

  describe "Binding operation" do
    test "let has required fields: name, value, in" do
      {:ok, def} = PtcRunner.Schema.get_operation("let")
      assert def["fields"]["name"]["required"] == true
      assert def["fields"]["name"]["type"] == :string
      assert def["fields"]["value"]["required"] == true
      assert def["fields"]["value"]["type"] == :expr
      assert def["fields"]["in"]["required"] == true
      assert def["fields"]["in"]["type"] == :expr
    end
  end

  describe "Control flow operations" do
    test "if has required fields: condition, then, else" do
      {:ok, def} = PtcRunner.Schema.get_operation("if")
      assert def["fields"]["condition"]["required"] == true
      assert def["fields"]["condition"]["type"] == :expr
      assert def["fields"]["then"]["required"] == true
      assert def["fields"]["then"]["type"] == :expr
      assert def["fields"]["else"]["required"] == true
      assert def["fields"]["else"]["type"] == :expr
    end

    test "and has required 'conditions' field as list of expressions" do
      {:ok, def} = PtcRunner.Schema.get_operation("and")
      assert def["fields"]["conditions"]["required"] == true
      assert def["fields"]["conditions"]["type"] == {:list, :expr}
    end

    test "or has required 'conditions' field as list of expressions" do
      {:ok, def} = PtcRunner.Schema.get_operation("or")
      assert def["fields"]["conditions"]["required"] == true
      assert def["fields"]["conditions"]["type"] == {:list, :expr}
    end

    test "not has required 'condition' field" do
      {:ok, def} = PtcRunner.Schema.get_operation("not")
      assert def["fields"]["condition"]["required"] == true
      assert def["fields"]["condition"]["type"] == :expr
    end
  end

  describe "Combining operations" do
    test "merge has required 'objects' field as list of expressions" do
      {:ok, def} = PtcRunner.Schema.get_operation("merge")
      assert def["fields"]["objects"]["required"] == true
      assert def["fields"]["objects"]["type"] == {:list, :expr}
    end

    test "concat has required 'lists' field as list of expressions" do
      {:ok, def} = PtcRunner.Schema.get_operation("concat")
      assert def["fields"]["lists"]["required"] == true
      assert def["fields"]["lists"]["type"] == {:list, :expr}
    end

    test "zip has required 'lists' field as list of expressions" do
      {:ok, def} = PtcRunner.Schema.get_operation("zip")
      assert def["fields"]["lists"]["required"] == true
      assert def["fields"]["lists"]["type"] == {:list, :expr}
    end

    test "pipe has required 'steps' field as list of expressions" do
      {:ok, def} = PtcRunner.Schema.get_operation("pipe")
      assert def["fields"]["steps"]["required"] == true
      assert def["fields"]["steps"]["type"] == {:list, :expr}
    end
  end

  describe "Collection operations" do
    test "filter has required 'where' field" do
      {:ok, def} = PtcRunner.Schema.get_operation("filter")
      assert def["fields"]["where"]["required"] == true
      assert def["fields"]["where"]["type"] == :expr
    end

    test "map has required 'expr' field" do
      {:ok, def} = PtcRunner.Schema.get_operation("map")
      assert def["fields"]["expr"]["required"] == true
      assert def["fields"]["expr"]["type"] == :expr
    end

    test "select has required 'fields' field as list of strings" do
      {:ok, def} = PtcRunner.Schema.get_operation("select")
      assert def["fields"]["fields"]["required"] == true
      assert def["fields"]["fields"]["type"] == {:list, :string}
    end

    test "reject has required 'where' field" do
      {:ok, def} = PtcRunner.Schema.get_operation("reject")
      assert def["fields"]["where"]["required"] == true
      assert def["fields"]["where"]["type"] == :expr
    end
  end

  describe "Comparison operations" do
    test "eq has required 'field' and 'value'" do
      {:ok, def} = PtcRunner.Schema.get_operation("eq")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
      assert def["fields"]["value"]["required"] == true
      assert def["fields"]["value"]["type"] == :any
    end

    test "neq has required 'field' and 'value'" do
      {:ok, def} = PtcRunner.Schema.get_operation("neq")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
      assert def["fields"]["value"]["required"] == true
      assert def["fields"]["value"]["type"] == :any
    end

    test "gt has required 'field' and 'value'" do
      {:ok, def} = PtcRunner.Schema.get_operation("gt")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
      assert def["fields"]["value"]["required"] == true
      assert def["fields"]["value"]["type"] == :any
    end

    test "gte has required 'field' and 'value'" do
      {:ok, def} = PtcRunner.Schema.get_operation("gte")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
      assert def["fields"]["value"]["required"] == true
      assert def["fields"]["value"]["type"] == :any
    end

    test "lt has required 'field' and 'value'" do
      {:ok, def} = PtcRunner.Schema.get_operation("lt")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
      assert def["fields"]["value"]["required"] == true
      assert def["fields"]["value"]["type"] == :any
    end

    test "lte has required 'field' and 'value'" do
      {:ok, def} = PtcRunner.Schema.get_operation("lte")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
      assert def["fields"]["value"]["required"] == true
      assert def["fields"]["value"]["type"] == :any
    end

    test "contains has required 'field' and 'value'" do
      {:ok, def} = PtcRunner.Schema.get_operation("contains")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
      assert def["fields"]["value"]["required"] == true
      assert def["fields"]["value"]["type"] == :any
    end
  end

  describe "Access operations" do
    test "get has optional 'field', 'path', and 'default'" do
      {:ok, def} = PtcRunner.Schema.get_operation("get")
      assert def["fields"]["field"]["required"] == false
      assert def["fields"]["field"]["type"] == :string
      assert def["fields"]["path"]["required"] == false
      assert def["fields"]["path"]["type"] == {:list, :string}
      assert def["fields"]["default"]["required"] == false
      assert def["fields"]["default"]["type"] == :any
    end
  end

  describe "Aggregation operations" do
    test "sum has required 'field'" do
      {:ok, def} = PtcRunner.Schema.get_operation("sum")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
    end

    test "count has no required fields" do
      {:ok, def} = PtcRunner.Schema.get_operation("count")
      assert map_size(def["fields"]) == 0
    end

    test "avg has required 'field'" do
      {:ok, def} = PtcRunner.Schema.get_operation("avg")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
    end

    test "min has required 'field'" do
      {:ok, def} = PtcRunner.Schema.get_operation("min")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
    end

    test "max has required 'field'" do
      {:ok, def} = PtcRunner.Schema.get_operation("max")
      assert def["fields"]["field"]["required"] == true
      assert def["fields"]["field"]["type"] == :string
    end

    test "first has no required fields" do
      {:ok, def} = PtcRunner.Schema.get_operation("first")
      assert map_size(def["fields"]) == 0
    end

    test "last has no required fields" do
      {:ok, def} = PtcRunner.Schema.get_operation("last")
      assert map_size(def["fields"]) == 0
    end

    test "nth has required 'index' as non-negative integer" do
      {:ok, def} = PtcRunner.Schema.get_operation("nth")
      assert def["fields"]["index"]["required"] == true
      assert def["fields"]["index"]["type"] == :non_neg_integer
    end
  end

  describe "Tool integration operation" do
    test "call has required 'tool' and optional 'args'" do
      {:ok, def} = PtcRunner.Schema.get_operation("call")
      assert def["fields"]["tool"]["required"] == true
      assert def["fields"]["tool"]["type"] == :string
      assert def["fields"]["args"]["required"] == false
      assert def["fields"]["args"]["type"] == :map
    end
  end

  describe "Operations have descriptions" do
    test "all operations have descriptions" do
      operations = PtcRunner.Schema.operations()

      Enum.each(operations, fn {op_name, def} ->
        assert is_binary(def["description"]),
               "Operation '#{op_name}' is missing a description"

        assert String.length(def["description"]) > 0,
               "Operation '#{op_name}' has empty description"
      end)
    end
  end

  describe "Fields have proper structure" do
    test "all fields have type and required keys" do
      operations = PtcRunner.Schema.operations()

      Enum.each(operations, fn {op_name, def} ->
        fields = def["fields"]

        Enum.each(fields, fn {field_name, field_spec} ->
          assert Map.has_key?(field_spec, "type"),
                 "Field '#{field_name}' in operation '#{op_name}' missing 'type' key"

          assert Map.has_key?(field_spec, "required"),
                 "Field '#{field_name}' in operation '#{op_name}' missing 'required' key"

          assert is_boolean(field_spec["required"]),
                 "Field '#{field_name}' in operation '#{op_name}' has non-boolean 'required' value"
        end)
      end)
    end
  end

  describe "to_json_schema/0" do
    test "returns a valid JSON Schema structure" do
      schema = PtcRunner.Schema.to_json_schema()

      assert is_map(schema)
      assert schema["$schema"] == "http://json-schema.org/draft-07/schema#"
      assert schema["title"] == "PTC DSL Program"
      assert schema["type"] == "object"
      assert is_map(schema["$defs"])
      assert is_map(schema["$defs"]["operation"])
      assert is_list(schema["$defs"]["operation"]["oneOf"])
    end

    test "schema has program property with correct structure" do
      schema = PtcRunner.Schema.to_json_schema()

      assert is_map(schema["properties"])
      assert is_map(schema["properties"]["program"])
      assert schema["properties"]["program"]["$ref"] == "#/$defs/operation"
      assert schema["required"] == ["program"]
      assert schema["additionalProperties"] == false
    end

    test "generates 42 operation schemas" do
      schema = PtcRunner.Schema.to_json_schema()
      assert length(schema["$defs"]["operation"]["oneOf"]) == 42
    end

    test "each operation schema has required structure" do
      schema = PtcRunner.Schema.to_json_schema()

      Enum.each(schema["$defs"]["operation"]["oneOf"], fn op_schema ->
        assert is_map(op_schema)
        assert op_schema["type"] == "object"
        assert is_map(op_schema["properties"])
        assert is_list(op_schema["required"])
        assert op_schema["additionalProperties"] == false
      end)
    end

    test "literal operation schema is correct" do
      schema = PtcRunner.Schema.to_json_schema()

      literal_schema =
        Enum.find(schema["$defs"]["operation"]["oneOf"], fn op ->
          op["properties"]["op"]["const"] == "literal"
        end)

      assert literal_schema != nil
      assert "op" in literal_schema["required"]
      assert "value" in literal_schema["required"]
      assert literal_schema["properties"]["value"] == %{}
    end

    test "operations with no fields have only 'op' as required" do
      schema = PtcRunner.Schema.to_json_schema()

      count_schema =
        Enum.find(schema["$defs"]["operation"]["oneOf"], fn op ->
          op["properties"]["op"]["const"] == "count"
        end)

      assert count_schema["required"] == ["op"]
    end

    test "get operation has optional field, path, and default" do
      schema = PtcRunner.Schema.to_json_schema()

      get_schema =
        Enum.find(schema["$defs"]["operation"]["oneOf"], fn op ->
          op["properties"]["op"]["const"] == "get"
        end)

      # field, path, and default are all optional in schema (validator enforces field OR path)
      assert get_schema["required"] == ["op"]
      assert Map.has_key?(get_schema["properties"], "field")
      assert Map.has_key?(get_schema["properties"], "path")
      assert Map.has_key?(get_schema["properties"], "default")
    end

    test "expr types use $ref pointing to $defs/operation" do
      schema = PtcRunner.Schema.to_json_schema()

      let_schema =
        Enum.find(schema["$defs"]["operation"]["oneOf"], fn op ->
          op["properties"]["op"]["const"] == "let"
        end)

      assert let_schema["properties"]["value"] == %{"$ref" => "#/$defs/operation"}
      assert let_schema["properties"]["in"] == %{"$ref" => "#/$defs/operation"}
    end

    test "list of expr types have correct schema with $defs/operation reference" do
      schema = PtcRunner.Schema.to_json_schema()

      and_schema =
        Enum.find(schema["$defs"]["operation"]["oneOf"], fn op ->
          op["properties"]["op"]["const"] == "and"
        end)

      assert and_schema["properties"]["conditions"] == %{
               "type" => "array",
               "items" => %{"$ref" => "#/$defs/operation"}
             }
    end

    test "list of string types have correct schema" do
      schema = PtcRunner.Schema.to_json_schema()

      select_schema =
        Enum.find(schema["$defs"]["operation"]["oneOf"], fn op ->
          op["properties"]["op"]["const"] == "select"
        end)

      assert select_schema["properties"]["fields"] == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "non_neg_integer types have minimum constraint" do
      schema = PtcRunner.Schema.to_json_schema()

      nth_schema =
        Enum.find(schema["$defs"]["operation"]["oneOf"], fn op ->
          op["properties"]["op"]["const"] == "nth"
        end)

      assert nth_schema["properties"]["index"] == %{
               "type" => "integer",
               "minimum" => 0
             }
    end

    test "recursive operations like pipe validate correctly" do
      schema = PtcRunner.Schema.to_json_schema()

      pipe_schema =
        Enum.find(schema["$defs"]["operation"]["oneOf"], fn op ->
          op["properties"]["op"]["const"] == "pipe"
        end)

      assert pipe_schema != nil

      assert pipe_schema["properties"]["steps"] == %{
               "type" => "array",
               "items" => %{"$ref" => "#/$defs/operation"}
             }
    end

    test "generated schema is valid JSON" do
      schema = PtcRunner.Schema.to_json_schema()
      json = Jason.encode!(schema)
      decoded = Jason.decode!(json)

      assert decoded == schema
    end

    test "schema file is synchronized with generated schema" do
      generated = PtcRunner.Schema.to_json_schema()
      file_path = Path.expand("priv/ptc_schema.json")

      assert File.exists?(file_path),
             "priv/ptc_schema.json file not found"

      on_disk =
        file_path
        |> File.read!()
        |> Jason.decode!()

      assert generated == on_disk,
             "Generated schema does not match priv/ptc_schema.json"
    end
  end

  describe "to_llm_schema/0" do
    test "returns a valid JSON Schema structure" do
      schema = PtcRunner.Schema.to_llm_schema()

      assert is_map(schema)
      assert schema["title"] == "PTC Program"
      assert schema["type"] == "object"
      assert is_map(schema["properties"])
      assert is_list(schema["properties"]["program"]["anyOf"])
    end

    test "schema has program property with correct structure" do
      schema = PtcRunner.Schema.to_llm_schema()

      assert is_map(schema["properties"])
      assert is_map(schema["properties"]["program"])
      assert is_list(schema["properties"]["program"]["anyOf"])
      assert schema["required"] == ["program"]
      assert schema["additionalProperties"] == false
    end

    test "generates 42 operation schemas" do
      schema = PtcRunner.Schema.to_llm_schema()
      assert length(schema["properties"]["program"]["anyOf"]) == 42
    end

    test "each operation schema has required structure" do
      schema = PtcRunner.Schema.to_llm_schema()

      Enum.each(schema["properties"]["program"]["anyOf"], fn op_schema ->
        assert is_map(op_schema)
        assert op_schema["type"] == "object"
        assert is_map(op_schema["properties"])
        assert is_list(op_schema["required"])
        assert op_schema["additionalProperties"] == false
      end)
    end

    test "literal operation schema is correct" do
      schema = PtcRunner.Schema.to_llm_schema()

      literal_schema =
        Enum.find(schema["properties"]["program"]["anyOf"], fn op ->
          op["properties"]["op"]["const"] == "literal"
        end)

      assert literal_schema != nil
      assert "op" in literal_schema["required"]
      assert "value" in literal_schema["required"]
      assert literal_schema["properties"]["value"] == %{}
    end

    test "operations with no fields have only 'op' as required" do
      schema = PtcRunner.Schema.to_llm_schema()

      count_schema =
        Enum.find(schema["properties"]["program"]["anyOf"], fn op ->
          op["properties"]["op"]["const"] == "count"
        end)

      assert count_schema["required"] == ["op"]
    end

    test "get operation has optional field, path, and default" do
      schema = PtcRunner.Schema.to_llm_schema()

      get_schema =
        Enum.find(schema["properties"]["program"]["anyOf"], fn op ->
          op["properties"]["op"]["const"] == "get"
        end)

      # field, path, and default are all optional in schema (validator enforces field OR path)
      assert get_schema["required"] == ["op"]
      assert Map.has_key?(get_schema["properties"], "field")
      assert Map.has_key?(get_schema["properties"], "path")
      assert Map.has_key?(get_schema["properties"], "default")
    end

    test "expr types use anyOf with operation schemas" do
      schema = PtcRunner.Schema.to_llm_schema()

      let_schema =
        Enum.find(schema["properties"]["program"]["anyOf"], fn op ->
          op["properties"]["op"]["const"] == "let"
        end)

      # Verify value and in fields use anyOf with nested operation schemas
      assert is_list(let_schema["properties"]["value"]["anyOf"])
      assert is_list(let_schema["properties"]["in"]["anyOf"])

      # Each anyOf entry should have op const
      first_value_op = hd(let_schema["properties"]["value"]["anyOf"])
      assert first_value_op["properties"]["op"]["const"] != nil
    end

    test "list of expr types use anyOf schema" do
      schema = PtcRunner.Schema.to_llm_schema()

      and_schema =
        Enum.find(schema["properties"]["program"]["anyOf"], fn op ->
          op["properties"]["op"]["const"] == "and"
        end)

      assert and_schema["properties"]["conditions"]["type"] == "array"
      assert is_map(and_schema["properties"]["conditions"]["items"])
      assert is_list(and_schema["properties"]["conditions"]["items"]["anyOf"])

      # Each anyOf entry should define an operation
      first_op = hd(and_schema["properties"]["conditions"]["items"]["anyOf"])
      assert first_op["properties"]["op"]["const"] != nil
    end

    test "list of string types have correct schema" do
      schema = PtcRunner.Schema.to_llm_schema()

      select_schema =
        Enum.find(schema["properties"]["program"]["anyOf"], fn op ->
          op["properties"]["op"]["const"] == "select"
        end)

      assert select_schema["properties"]["fields"] == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "non_neg_integer types have minimum constraint" do
      schema = PtcRunner.Schema.to_llm_schema()

      nth_schema =
        Enum.find(schema["properties"]["program"]["anyOf"], fn op ->
          op["properties"]["op"]["const"] == "nth"
        end)

      assert nth_schema["properties"]["index"]["type"] == "integer"
      assert nth_schema["properties"]["index"]["minimum"] == 0
    end

    test "recursive operations like pipe use anyOf for steps" do
      schema = PtcRunner.Schema.to_llm_schema()

      pipe_schema =
        Enum.find(schema["properties"]["program"]["anyOf"], fn op ->
          op["properties"]["op"]["const"] == "pipe"
        end)

      assert pipe_schema != nil
      assert pipe_schema["properties"]["steps"]["type"] == "array"
      assert is_list(pipe_schema["properties"]["steps"]["items"]["anyOf"])

      # Steps should include load operation with required name field
      load_schema =
        Enum.find(pipe_schema["properties"]["steps"]["items"]["anyOf"], fn op ->
          op["properties"]["op"]["const"] == "load"
        end)

      assert load_schema != nil
      assert "name" in load_schema["required"]
    end

    test "generated schema is valid JSON" do
      schema = PtcRunner.Schema.to_llm_schema()
      json = Jason.encode!(schema)
      decoded = Jason.decode!(json)

      assert decoded == schema
    end
  end

  describe "to_prompt/1" do
    test "returns a string with operation descriptions" do
      prompt = PtcRunner.Schema.to_prompt()

      assert is_binary(prompt)
      assert String.contains?(prompt, "PTC-JSON")
      assert String.contains?(prompt, "## Operations")
      assert String.contains?(prompt, "pipe(steps)")
      assert String.contains?(prompt, "load(name)")
      assert String.contains?(prompt, "filter(where)")
      assert String.contains?(prompt, "count")
    end

    test "includes all operation categories" do
      prompt = PtcRunner.Schema.to_prompt()

      assert String.contains?(prompt, "Data:")
      assert String.contains?(prompt, "Flow:")
      assert String.contains?(prompt, "Logic:")
      assert String.contains?(prompt, "Filter/Transform:")
      assert String.contains?(prompt, "Compare:")
      assert String.contains?(prompt, "Aggregate:")
      assert String.contains?(prompt, "Combine:")
      assert String.contains?(prompt, "Access:")
      assert String.contains?(prompt, "Tools:")
    end

    test "includes examples by default" do
      prompt = PtcRunner.Schema.to_prompt()

      assert String.contains?(prompt, "Examples:")
      assert String.contains?(prompt, ~s|{"program":|)
      assert String.contains?(prompt, ~s|"op":"pipe"|)
    end

    test "examples option controls number of examples" do
      prompt_none = PtcRunner.Schema.to_prompt(examples: 0)
      prompt_one = PtcRunner.Schema.to_prompt(examples: 1)
      prompt_three = PtcRunner.Schema.to_prompt(examples: 3)

      refute String.contains?(prompt_none, "Examples:")

      assert String.contains?(prompt_one, "Count filtered items")
      refute String.contains?(prompt_one, "Count distinct values")

      assert String.contains?(prompt_three, "Count filtered items")
      assert String.contains?(prompt_three, "Count distinct values")
      # Examples use generic domains (tasks, events, transactions) not test domains
      refute String.contains?(prompt_three, "orders")
      refute String.contains?(prompt_three, "products")
      refute String.contains?(prompt_three, "expenses")
    end

    test "is much smaller than to_llm_schema" do
      prompt = PtcRunner.Schema.to_prompt()
      llm_schema = PtcRunner.Schema.to_llm_schema() |> Jason.encode!()

      # Prompt should be at least 10x smaller
      assert String.length(prompt) < String.length(llm_schema) / 10
    end
  end
end
