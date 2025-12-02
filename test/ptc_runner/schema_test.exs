defmodule PtcRunner.SchemaTest do
  use ExUnit.Case

  describe "Schema module" do
    test "operations/0 returns a map" do
      operations = PtcRunner.Schema.operations()
      assert is_map(operations)
      assert map_size(operations) == 33
    end

    test "valid_operation_names/0 returns 33 operation names in sorted order" do
      names = PtcRunner.Schema.valid_operation_names()

      assert is_list(names)
      assert length(names) == 33
      assert names == Enum.sort(names)

      expected_ops =
        ~w(and avg call concat contains count eq filter first get gt gte if last let literal load lt lte map max merge min neq not nth or pipe reject select sum var zip)

      assert Enum.sort(names) == expected_ops
    end

    test "get_operation/1 returns operation definition for valid operation" do
      {:ok, literal_def} = PtcRunner.Schema.get_operation("literal")

      assert is_map(literal_def)
      assert literal_def["description"] == "A literal JSON value"
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
    test "get has required 'path' and optional 'default'" do
      {:ok, def} = PtcRunner.Schema.get_operation("get")
      assert def["fields"]["path"]["required"] == true
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
end
