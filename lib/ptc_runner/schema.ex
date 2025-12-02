defmodule PtcRunner.Schema do
  @moduledoc """
  Declarative schema module that defines all DSL operations.

  This module serves as the single source of truth for operation definitions,
  supporting validation, JSON Schema generation, and documentation.
  """

  # Essential operations for nested expressions (minimized for schema size)
  @nested_ops ~w(load literal filter map sum count gt gte lt lte eq)

  @operations %{
    # Data operations
    "literal" => %{
      "description" => "A literal JSON value",
      "fields" => %{
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "load" => %{
      "description" => "Load a resource by name. Use name='input' to load the input data",
      "fields" => %{
        "name" => %{"type" => :string, "required" => true}
      }
    },
    "var" => %{
      "description" => "Reference a variable",
      "fields" => %{
        "name" => %{"type" => :string, "required" => true}
      }
    },

    # Binding
    "let" => %{
      "description" => "Bind a value to a variable",
      "fields" => %{
        "name" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :expr, "required" => true},
        "in" => %{"type" => :expr, "required" => true}
      }
    },

    # Control flow
    "if" => %{
      "description" => "Conditional expression",
      "fields" => %{
        "condition" => %{"type" => :expr, "required" => true},
        "then" => %{"type" => :expr, "required" => true},
        "else" => %{"type" => :expr, "required" => true}
      }
    },
    "and" => %{
      "description" => "Logical AND of conditions",
      "fields" => %{
        "conditions" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "or" => %{
      "description" => "Logical OR of conditions",
      "fields" => %{
        "conditions" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "not" => %{
      "description" => "Logical NOT of a condition",
      "fields" => %{
        "condition" => %{"type" => :expr, "required" => true}
      }
    },

    # Combining operations
    "merge" => %{
      "description" => "Merge multiple objects",
      "fields" => %{
        "objects" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "concat" => %{
      "description" => "Concatenate multiple lists",
      "fields" => %{
        "lists" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "zip" => %{
      "description" => "Zip multiple lists together",
      "fields" => %{
        "lists" => %{"type" => {:list, :expr}, "required" => true}
      }
    },
    "pipe" => %{
      "description" =>
        "Sequence of operations. Steps: [load input, then filter/map/sum/count]. Example: pipe with steps [load, filter, count]",
      "fields" => %{
        "steps" => %{"type" => {:list, :expr}, "required" => true}
      }
    },

    # Collection operations
    "filter" => %{
      "description" => "Keep items matching condition. Use with gt/lt/eq in 'where' field",
      "fields" => %{
        "where" => %{"type" => :expr, "required" => true}
      }
    },
    "map" => %{
      "description" => "Transform collection elements",
      "fields" => %{
        "expr" => %{"type" => :expr, "required" => true}
      }
    },
    "select" => %{
      "description" => "Select specific fields from objects",
      "fields" => %{
        "fields" => %{"type" => {:list, :string}, "required" => true}
      }
    },
    "reject" => %{
      "description" => "Reject collection elements based on condition",
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
      "description" => "Field not equals value",
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
      "description" => "Check greater than or equal",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "lt" => %{
      "description" => "Check less than",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "lte" => %{
      "description" => "Check less than or equal",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "contains" => %{
      "description" => "Check if field contains value",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },

    # Access operations
    "get" => %{
      "description" => "Get value at path",
      "fields" => %{
        "path" => %{"type" => {:list, :string}, "required" => true},
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
      "description" => "Average values in a field",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "min" => %{
      "description" => "Minimum value in a field",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "max" => %{
      "description" => "Maximum value in a field",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "first" => %{
      "description" => "Get first element",
      "fields" => %{}
    },
    "last" => %{
      "description" => "Get last element",
      "fields" => %{}
    },
    "nth" => %{
      "description" => "Get element at index",
      "fields" => %{
        "index" => %{"type" => :non_neg_integer, "required" => true}
      }
    },

    # Tool integration
    "call" => %{
      "description" => "Call a tool",
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
