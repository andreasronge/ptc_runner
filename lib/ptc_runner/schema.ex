defmodule PtcRunner.Schema do
  @moduledoc """
  Declarative schema module that defines all DSL operations.

  This module serves as the single source of truth for operation definitions,
  supporting validation, JSON Schema generation, and documentation.
  """

  @operations %{
    # Data operations
    "literal" => %{
      "description" => "A literal JSON value",
      "fields" => %{
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "load" => %{
      "description" => "Load a resource by name",
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
      "description" => "Pipe value through multiple steps",
      "fields" => %{
        "steps" => %{"type" => {:list, :expr}, "required" => true}
      }
    },

    # Collection operations
    "filter" => %{
      "description" => "Filter collection based on condition",
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
      "description" => "Check equality",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "neq" => %{
      "description" => "Check inequality",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true},
        "value" => %{"type" => :any, "required" => true}
      }
    },
    "gt" => %{
      "description" => "Check greater than",
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
      "description" => "Sum values in a field",
      "fields" => %{
        "field" => %{"type" => :string, "required" => true}
      }
    },
    "count" => %{
      "description" => "Count elements",
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
      "oneOf" => operation_schemas
    }
  end

  # Convert a single operation to its JSON Schema representation
  defp operation_to_schema(op_name, op_def) do
    fields = op_def["fields"]
    properties = build_properties(op_name, fields)
    required_fields = build_required(fields)

    %{
      "type" => "object",
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

  # Convert Elixir type to JSON Schema type specification
  defp type_to_json_schema(:any), do: %{}

  defp type_to_json_schema(:string) do
    %{"type" => "string"}
  end

  defp type_to_json_schema(:expr) do
    %{"$ref" => "#"}
  end

  defp type_to_json_schema({:list, :expr}) do
    %{
      "type" => "array",
      "items" => %{"$ref" => "#"}
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
