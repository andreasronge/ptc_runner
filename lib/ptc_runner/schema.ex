defmodule PtcRunner.Schema do
  @moduledoc """
  Declarative schema module that defines all DSL operations.

  This module serves as the single source of truth for operation definitions,
  supporting validation, JSON Schema generation, and documentation.
  """

  # Essential operations for nested expressions (minimized for schema size)
  @nested_ops ~w(load literal filter map sum count gt gte lt lte eq keys typeof)

  @operations %{
    # Data operations
    "literal" => %{
      "description" => "A literal JSON value. Example: {op:'literal', value:42}",
      "fields" => %{
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "load" => %{
      "description" =>
        "Load a resource by name. Use name='input' to load the input data. Example: {op:'load', name:'input'}",
      "fields" => %{
        "name" => %{"type" => :string, "required" => true}
      }
    },
    "var" => %{
      "description" => "Reference a variable. Example: {op:'var', name:'count'}",
      "fields" => %{
        "name" => %{"type" => :string, "required" => true}
      }
    },

    # Binding
    "let" => %{
      "description" =>
        "Bind a value to a variable. Example: {op:'let', name:'x', value:{op:'literal', value:5}, in:{op:'var', name:'x'}}",
      "fields" => %{
        "name" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :expr, "required" => true},
        "in" => %{"type" => :expr, "required" => true}
      }
    },

    # Control flow
    "if" => %{
      "description" =>
        "Conditional expression. Example: {op:'if', condition:{op:'gt', field:'age', value:18}, then:{op:'literal', value:'adult'}, else:{op:'literal', value:'minor'}}",
      "fields" => %{
        "condition" => %{"type" => :expr, "required" => true},
        "then" => %{"type" => :expr, "required" => true},
        "else" => %{"type" => :expr, "required" => true}
      }
    },
    "and" => %{
      "description" =>
        "Logical AND of conditions. Example: {op:'and', conditions:[{op:'gt', field:'age', value:18}, {op:'eq', field:'status', value:'active'}]}",
      "fields" => %{
        "conditions" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "or" => %{
      "description" =>
        "Logical OR of conditions. Example: {op:'or', conditions:[{op:'eq', field:'status', value:'pending'}, {op:'eq', field:'status', value:'cancelled'}]}",
      "fields" => %{
        "conditions" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "not" => %{
      "description" =>
        "Logical NOT of a condition. Example: {op:'not', condition:{op:'eq', field:'status', value:'deleted'}}",
      "fields" => %{
        "condition" => %{"type" => :expr, "required" => true}
      }
    },

    # Combining operations
    "merge" => %{
      "description" =>
        "Merge multiple objects. Example: {op:'merge', objects:[{op:'literal', value:{a:1}}, {op:'literal', value:{b:2}}]}",
      "fields" => %{
        "objects" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "concat" => %{
      "description" =>
        "Concatenate multiple lists. Example: {op:'concat', lists:[{op:'literal', value:[1,2]}, {op:'literal', value:[3,4]}]}",
      "fields" => %{
        "lists" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "zip" => %{
      "description" =>
        "Zip multiple lists together. Example: {op:'zip', lists:[{op:'literal', value:[1,2]}, {op:'literal', value:['a','b']}]}",
      "fields" => %{
        "lists" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "pipe" => %{
      "description" =>
        "Sequence of operations. Example: {op:'pipe', steps:[{op:'load', name:'input'}, {op:'filter', where:{op:'gt', field:'price', value:10}}]}",
      "fields" => %{
        "steps" => %{"type" => {:list, :expr}, "required" => true}
      }
    },

    # Collection operations
    "filter" => %{
      "description" =>
        "Keep items matching condition. Example: {op:'filter', where:{op:'gt', field:'price', value:10}}",
      "fields" => %{
        "where" => %{"type" => :expr, "required" => true}
      }
    },
    "map" => %{
      "description" =>
        "Transform collection elements. Example: {op:'map', expr:{op:'get', path:['name']}}",
      "fields" => %{
        "expr" => %{"type" => :expr, "required" => true}
      }
    },
    "select" => %{
      "description" =>
        "Select specific fields from objects. Example: {op:'select', fields:['name', 'email']}",
      "fields" => %{
        "fields" => %{"type" => {:list, :string}, "required" => true}
      }
    },
    "sort_by" => %{
      "description" =>
        "Sort list by field. Example: {op:'sort_by', field:'price'} or {op:'sort_by', field:'price', order:'desc'}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "order" => %{"type" => :string, "required" => false}
      }
    },
    "reject" => %{
      "description" =>
        "Reject collection elements based on condition. Example: {op:'reject', where:{op:'eq', field:'status', value:'inactive'}}",
      "fields" => %{
        "where" => %{"type" => :expr, "required" => true}
      }
    },

    # Comparison operations
    "eq" => %{
      "description" => "Field equals value. Example: {op:'eq', field:'status', value:'active'}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "neq" => %{
      "description" =>
        "Field not equals value. Example: {op:'neq', field:'status', value:'deleted'}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "gt" => %{
      "description" => "Field greater than value. Example: {op:'gt', field:'price', value:10}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "gte" => %{
      "description" =>
        "Field greater than or equal to value. Example: {op:'gte', field:'age', value:18}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "lt" => %{
      "description" => "Field less than value. Example: {op:'lt', field:'price', value:100}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "lte" => %{
      "description" =>
        "Field less than or equal to value. Example: {op:'lte', field:'quantity', value:0}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "contains" => %{
      "description" =>
        "Field contains value. Example: {op:'contains', field:'tags', value:'featured'}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },

    # Access operations
    "get" => %{
      "description" =>
        "Get value at field or path. Use field for single key: {op:'get', field:'name'}. Use path for nested: {op:'get', path:['user', 'name']}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => false},
        "path" => %{"type" => {:list, :string}, "required" => false},
        "default" => %{"type" => :any, "required" => false}
      }
    },

    # Aggregations
    "sum" => %{
      "description" => "Sum numeric field. Example: {op:'sum', field:'price'}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "count" => %{
      "description" => "Count items in collection. Example: {op:'count'}",
      "fields" => %{}
    },
    "avg" => %{
      "description" => "Average of numeric field. Example: {op:'avg', field:'rating'}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "min" => %{
      "description" => "Minimum value in field. Example: {op:'min', field:'price'}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "max" => %{
      "description" => "Maximum value in field. Example: {op:'max', field:'price'}",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "min_by" => %{
      "description" =>
        "Get the row with minimum field value. Example: {op:'min_by', field:'price'} returns the item with lowest price",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "max_by" => %{
      "description" =>
        "Get the row with maximum field value. Example: {op:'max_by', field:'years'} returns the item with highest years",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "first" => %{
      "description" => "Get first element. Example: {op:'first'}",
      "fields" => %{}
    },
    "last" => %{
      "description" => "Get last element. Example: {op:'last'}",
      "fields" => %{}
    },
    "nth" => %{
      "description" => "Get element at index. Example: {op:'nth', index:2}",
      "fields" => %{
        "index" => %{"type" => :non_neg_integer, "required" => true}
      }
    },

    # Introspection operations
    "keys" => %{
      "description" => "Get sorted list of keys in a map. Example: {op:'keys'}",
      "fields" => %{}
    },
    "typeof" => %{
      "description" =>
        "Get type of current value as string. Returns 'object', 'list', 'string', 'number', 'boolean', or 'null'. Example: {op:'typeof'}",
      "fields" => %{}
    },

    # Tool integration
    "call" => %{
      "description" => "Call a tool. Example: {op:'call', tool:'fetch_user', args:{id:123}}",
      "fields" => %{
        "tool" => %{"type" => :string, "required" => true},
        "args" => %{"type" => :map, "required" => false}
      }
    }
  }

  @doc """
  Returns all operation definitions.

  ## Returns
    A map where keys are operation names and values are operation definitions.
  """
  @spec operations() :: map()
  def operations do
    @operations
  end

  @doc """
  Returns a sorted list of valid operation names.

  ## Returns
    A list of operation names in sorted order.
  """
  @spec valid_operation_names() :: list(String.t())
  def valid_operation_names do
    @operations
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Get operation definition by name.

  ## Arguments
    - operation_name: The name of the operation

  ## Returns
    - `{:ok, definition}` if the operation exists
    - `:error` if the operation is unknown
  """
  @spec get_operation(String.t()) :: {:ok, map()} | :error
  def get_operation(operation_name) when is_binary(operation_name) do
    case Map.fetch(@operations, operation_name) do
      {:ok, definition} -> {:ok, definition}
      :error -> :error
    end
  end

  def get_operation(_), do: :error

  @doc """
  Generate a JSON Schema (draft-07) for the PTC DSL.

  ## Returns
    A map representing the JSON Schema that can be encoded to JSON.
  """
  @spec to_json_schema() :: map()
  def to_json_schema do
    operation_schemas =
      @operations
      |> Enum.map(fn {op_name, op_def} ->
        operation_to_schema(op_name, op_def)
      end)

    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "PTC DSL Program",
      "type" => "object",
      "$defs" => %{
        "operation" => %{"oneOf" => operation_schemas}
      },
      "properties" => %{
        "program" => %{
          "description" => "The PTC program operation",
          "$ref" => "#/$defs/operation"
        }
      },
      "required" => ["program"],
      "additionalProperties" => false
    }
  end

  # Convert a single operation to its JSON Schema representation
  defp operation_to_schema(op_name, op_def) do
    fields = op_def["fields"]
    properties = build_properties(op_name, fields)
    required_fields = build_required(fields)

    %{
      "type" => "object",
      "description" => op_def["description"],
      "properties" => properties,
      "required" => required_fields,
      "additionalProperties" => false
    }
  end

  # Build the properties map for an operation schema
  defp build_properties(op_name, fields) do
    base_properties = %{
      "op" => %{"const" => op_name}
    }

    field_properties =
      fields
      |> Enum.map(fn {field_name, field_spec} ->
        {field_name, type_to_json_schema(field_spec["type"])}
      end)
      |> Enum.into(%{})

    Map.merge(base_properties, field_properties)
  end

  # Build the required fields array for an operation schema
  defp build_required(fields) do
    base_required = ["op"]

    field_required =
      fields
      |> Enum.filter(fn {_field_name, field_spec} ->
        field_spec["required"] == true
      end)
      |> Enum.map(fn {field_name, _field_spec} -> field_name end)

    base_required ++ field_required
  end

  @doc """
  Generate a concise prompt describing PTC operations for LLM text mode.

  This produces a compact (~300 tokens) human-readable description of operations
  suitable for system prompts. Much smaller than `to_llm_schema/0` (~10k tokens)
  while still enabling LLMs to generate valid programs.

  ## Options
    - `:examples` - number of full JSON examples to include (default: 2)

  ## Returns
    A string containing operation descriptions and examples.
  """
  @spec to_prompt(keyword()) :: String.t()
  def to_prompt(opts \\ []) do
    num_examples = Keyword.get(opts, :examples, 2)

    categories = [
      {"Data", ~w(load literal var)},
      {"Flow", ~w(pipe let if)},
      {"Logic", ~w(and or not)},
      {"Filter/Transform", ~w(filter map select reject sort_by)},
      {"Compare", ~w(eq neq gt gte lt lte contains)},
      {"Aggregate", ~w(count sum avg min max min_by max_by first last nth)},
      {"Combine", ~w(merge concat zip)},
      {"Access", ~w(get)},
      {"Introspect", ~w(keys typeof)},
      {"Tools", ~w(call)}
    ]

    ops_text = Enum.map_join(categories, "\n", &format_category/1)

    examples_text = build_examples(num_examples)

    """
    PTC Operations (JSON format, wrap in {"program": ...}):

    #{ops_text}
    #{examples_text}
    """
    |> String.trim()
  end

  defp format_category({name, ops}) do
    ops_desc =
      ops
      |> Enum.filter(&Map.has_key?(@operations, &1))
      |> Enum.map_join(", ", &format_op/1)

    "#{name}: #{ops_desc}"
  end

  defp format_op(op_name) do
    case Map.get(@operations, op_name) do
      %{"fields" => fields} when map_size(fields) == 0 ->
        op_name

      %{"fields" => fields} ->
        required =
          fields
          |> Enum.filter(fn {_, spec} -> spec["required"] end)
          |> Enum.map_join(",", fn {name, _} -> name end)

        "#{op_name}(#{required})"

      _ ->
        op_name
    end
  end

  @prompt_examples [
    {"Count filtered items",
     ~s|{"program":{"op":"pipe","steps":[{"op":"load","name":"orders"},{"op":"filter","where":{"op":"gt","field":"total","value":100}},{"op":"count"}]}}|},
    {"Sum with multiple conditions",
     ~s|{"program":{"op":"pipe","steps":[{"op":"load","name":"expenses"},{"op":"filter","where":{"op":"and","conditions":[{"op":"eq","field":"status","value":"approved"},{"op":"eq","field":"category","value":"travel"}]}},{"op":"sum","field":"amount"}]}}|},
    {"Average of filtered data",
     ~s|{"program":{"op":"pipe","steps":[{"op":"load","name":"products"},{"op":"filter","where":{"op":"eq","field":"category","value":"electronics"}},{"op":"avg","field":"price"}]}}|}
  ]

  defp build_examples(n) do
    @prompt_examples
    |> Enum.take(n)
    |> Enum.map_join("\n\n", fn {desc, json} -> "#{desc}:\n#{json}" end)
    |> case do
      "" -> ""
      text -> "\nExamples:\n#{text}"
    end
  end

  @doc """
  Generate a flattened JSON Schema optimized for LLM structured output.

  This schema uses `anyOf` to list all operations at the top level, avoiding
  the recursive `$ref` patterns that LLMs struggle with. The schema is designed
  to work with ReqLLM.generate_object! for structured output mode.

  ## Returns
    A map representing the flattened JSON Schema for the PTC DSL.
  """
  @spec to_llm_schema() :: map()
  def to_llm_schema do
    operation_schemas =
      @operations
      |> Enum.map(fn {op_name, op_def} ->
        operation_to_llm_schema(op_name, op_def)
      end)

    %{
      "title" => "PTC Program",
      "type" => "object",
      "properties" => %{
        "program" => %{
          "description" =>
            "Use pipe to chain operations. Start with load (name='input'), then apply transforms like filter, map, sum",
          "anyOf" => operation_schemas
        }
      },
      "required" => ["program"],
      "additionalProperties" => false
    }
  end

  # Convert a single operation to its flattened schema representation for LLM use
  defp operation_to_llm_schema(op_name, op_def) do
    fields = op_def["fields"]
    properties = build_llm_properties(op_name, fields)
    required_fields = build_required(fields)

    %{
      "type" => "object",
      "description" => op_def["description"],
      "properties" => properties,
      "required" => required_fields,
      "additionalProperties" => false
    }
  end

  # Build the properties map for an LLM schema operation (flattened, no $ref)
  defp build_llm_properties(op_name, fields) do
    base_properties = %{
      "op" => %{"const" => op_name}
    }

    field_properties =
      fields
      |> Enum.map(fn {field_name, field_spec} ->
        {field_name, type_to_llm_json_schema(field_spec["type"])}
      end)
      |> Enum.into(%{})

    Map.merge(base_properties, field_properties)
  end

  # Convert Elixir type to flattened JSON Schema type for LLM use (no $ref)
  defp type_to_llm_json_schema(:any), do: %{}
  defp type_to_llm_json_schema(:string), do: %{"type" => "string"}
  defp type_to_llm_json_schema(:map), do: %{"type" => "object"}
  defp type_to_llm_json_schema(:non_neg_integer), do: %{"type" => "integer", "minimum" => 0}

  defp type_to_llm_json_schema({:list, :string}),
    do: %{"type" => "array", "items" => %{"type" => "string"}}

  # For nested expressions, use anyOf with all operation schemas (one level deep)
  defp type_to_llm_json_schema(:expr), do: %{"anyOf" => nested_operation_schemas()}

  defp type_to_llm_json_schema({:list, :expr}) do
    %{"type" => "array", "items" => %{"anyOf" => nested_operation_schemas()}}
  end

  # Generate operation schemas for nested expressions (limited set, leaf level)
  defp nested_operation_schemas do
    @operations
    |> Enum.filter(fn {op_name, _} -> op_name in @nested_ops end)
    |> Enum.map(fn {op_name, op_def} ->
      fields = op_def["fields"]
      properties = build_nested_properties(op_name, fields)
      required_fields = build_required(fields)

      %{
        "type" => "object",
        "description" => op_def["description"],
        "properties" => properties,
        "required" => required_fields,
        "additionalProperties" => false
      }
    end)
  end

  defp build_nested_properties(op_name, fields) do
    field_properties =
      Enum.into(fields, %{}, fn {field_name, field_spec} ->
        {field_name, type_to_nested_schema(field_spec["type"])}
      end)

    Map.put(field_properties, "op", %{"const" => op_name})
  end

  # Leaf-level type schemas (nested expressions use simple {op: string} to avoid infinite recursion)
  defp type_to_nested_schema(:any), do: %{}
  defp type_to_nested_schema(:string), do: %{"type" => "string"}
  defp type_to_nested_schema(:map), do: %{"type" => "object"}
  defp type_to_nested_schema(:non_neg_integer), do: %{"type" => "integer", "minimum" => 0}

  defp type_to_nested_schema({:list, :string}),
    do: %{"type" => "array", "items" => %{"type" => "string"}}

  defp type_to_nested_schema(:expr) do
    %{"type" => "object", "properties" => %{"op" => %{"type" => "string"}}, "required" => ["op"]}
  end

  defp type_to_nested_schema({:list, :expr}) do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{"op" => %{"type" => "string"}},
        "required" => ["op"]
      }
    }
  end

  # Convert Elixir type to JSON Schema type specification
  defp type_to_json_schema(:any), do: %{}

  defp type_to_json_schema(:string) do
    %{"type" => "string"}
  end

  defp type_to_json_schema(:expr) do
    %{"$ref" => "#/$defs/operation"}
  end

  defp type_to_json_schema({:list, :expr}) do
    %{
      "type" => "array",
      "items" => %{"$ref" => "#/$defs/operation"}
    }
  end

  defp type_to_json_schema({:list, :string}) do
    %{
      "type" => "array",
      "items" => %{"type" => "string"}
    }
  end

  defp type_to_json_schema(:map) do
    %{"type" => "object"}
  end

  defp type_to_json_schema(:non_neg_integer) do
    %{
      "type" => "integer",
      "minimum" => 0
    }
  end
end
