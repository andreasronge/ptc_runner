defmodule PtcRunner.Validator do
  @moduledoc """
  Validates DSL programs against the schema.

  Ensures operations have correct structure and required fields.
  """

  @doc """
  Validates an AST node against the DSL schema.

  ## Arguments
    - ast: The AST to validate

  ## Returns
    - `:ok` if valid
    - `{:error, {:validation_error, message}}` if invalid
  """
  @spec validate(map()) :: :ok | {:error, {:validation_error, String.t()}}
  def validate(ast) when is_map(ast) do
    validate_node(ast)
  end

  def validate(ast) do
    {:error, {:validation_error, "AST must be a map, got #{inspect(ast)}"}}
  end

  defp validate_node(node) when not is_map(node) do
    {:error, {:validation_error, "Node must be a map, got #{inspect(node)}"}}
  end

  defp validate_node(node) do
    case Map.get(node, "op") do
      nil -> {:error, {:validation_error, "Missing required field 'op'"}}
      op -> validate_operation(op, node)
    end
  end

  # Data operations
  defp validate_operation("literal", node) do
    case Map.has_key?(node, "value") do
      true -> :ok
      false -> {:error, {:validation_error, "Operation 'literal' requires field 'value'"}}
    end
  end

  defp validate_operation("load", node) do
    case Map.has_key?(node, "name") do
      true -> :ok
      false -> {:error, {:validation_error, "Operation 'load' requires field 'name'"}}
    end
  end

  defp validate_operation("var", node) do
    case Map.has_key?(node, "name") do
      true -> :ok
      false -> {:error, {:validation_error, "Operation 'var' requires field 'name'"}}
    end
  end

  defp validate_operation("let", node) do
    with :ok <- require_field(node, "name", "Operation 'let' requires field 'name'"),
         :ok <- validate_let_name(node),
         :ok <- require_field(node, "value", "Operation 'let' requires field 'value'"),
         :ok <- require_field(node, "in", "Operation 'let' requires field 'in'") do
      # Recursively validate nested expressions
      with :ok <- validate_node(Map.get(node, "value")) do
        validate_node(Map.get(node, "in"))
      end
    end
  end

  defp validate_operation("if", node) do
    with :ok <- require_field(node, "condition", "Operation 'if' requires field 'condition'"),
         :ok <- require_field(node, "then", "Operation 'if' requires field 'then'"),
         :ok <- require_field(node, "else", "Operation 'if' requires field 'else'") do
      # Recursively validate nested expressions
      with :ok <- validate_node(Map.get(node, "condition")) do
        with :ok <- validate_node(Map.get(node, "then")) do
          validate_node(Map.get(node, "else"))
        end
      end
    end
  end

  defp validate_operation("and", node) do
    case Map.get(node, "conditions") do
      nil ->
        {:error, {:validation_error, "Operation 'and' requires field 'conditions'"}}

      conditions when not is_list(conditions) ->
        {:error, {:validation_error, "Field 'conditions' must be a list"}}

      conditions ->
        validate_list(conditions)
    end
  end

  defp validate_operation("or", node) do
    case Map.get(node, "conditions") do
      nil ->
        {:error, {:validation_error, "Operation 'or' requires field 'conditions'"}}

      conditions when not is_list(conditions) ->
        {:error, {:validation_error, "Field 'conditions' must be a list"}}

      conditions ->
        validate_list(conditions)
    end
  end

  defp validate_operation("not", node) do
    with :ok <- require_field(node, "condition", "Operation 'not' requires field 'condition'") do
      validate_node(Map.get(node, "condition"))
    end
  end

  defp validate_operation("merge", node) do
    case Map.get(node, "objects") do
      nil ->
        {:error, {:validation_error, "Operation 'merge' requires field 'objects'"}}

      objects when not is_list(objects) ->
        {:error, {:validation_error, "Field 'objects' must be a list"}}

      objects ->
        validate_list(objects)
    end
  end

  defp validate_operation("concat", node) do
    case Map.get(node, "lists") do
      nil ->
        {:error, {:validation_error, "Operation 'concat' requires field 'lists'"}}

      lists when not is_list(lists) ->
        {:error, {:validation_error, "Field 'lists' must be a list"}}

      lists ->
        validate_list(lists)
    end
  end

  defp validate_operation("zip", node) do
    case Map.get(node, "lists") do
      nil ->
        {:error, {:validation_error, "Operation 'zip' requires field 'lists'"}}

      lists when not is_list(lists) ->
        {:error, {:validation_error, "Field 'lists' must be a list"}}

      lists ->
        validate_list(lists)
    end
  end

  # Control flow
  defp validate_operation("pipe", node) do
    case Map.get(node, "steps") do
      nil ->
        {:error, {:validation_error, "Operation 'pipe' requires field 'steps'"}}

      steps when not is_list(steps) ->
        {:error, {:validation_error, "Field 'steps' must be a list"}}

      steps ->
        validate_list(steps)
    end
  end

  # Collection operations
  defp validate_operation("filter", node) do
    with :ok <- require_field(node, "where", "Operation 'filter' requires field 'where'") do
      validate_node(Map.get(node, "where"))
    end
  end

  defp validate_operation("map", node) do
    with :ok <- require_field(node, "expr", "Operation 'map' requires field 'expr'") do
      validate_node(Map.get(node, "expr"))
    end
  end

  defp validate_operation("select", node) do
    case Map.get(node, "fields") do
      nil ->
        {:error, {:validation_error, "Operation 'select' requires field 'fields'"}}

      fields when not is_list(fields) ->
        {:error, {:validation_error, "Field 'fields' must be a list"}}

      fields ->
        Enum.all?(fields, &is_binary/1)
        |> case do
          true -> :ok
          false -> {:error, {:validation_error, "All field names in 'fields' must be strings"}}
        end
    end
  end

  # Comparison
  defp validate_operation("eq", node) do
    case require_field(node, "field", "Operation 'eq' requires field 'field'") do
      :ok -> require_field(node, "value", "Operation 'eq' requires field 'value'")
      err -> err
    end
  end

  defp validate_operation("neq", node) do
    case require_field(node, "field", "Operation 'neq' requires field 'field'") do
      :ok -> require_field(node, "value", "Operation 'neq' requires field 'value'")
      err -> err
    end
  end

  defp validate_operation("gt", node) do
    case require_field(node, "field", "Operation 'gt' requires field 'field'") do
      :ok -> require_field(node, "value", "Operation 'gt' requires field 'value'")
      err -> err
    end
  end

  defp validate_operation("gte", node) do
    case require_field(node, "field", "Operation 'gte' requires field 'field'") do
      :ok -> require_field(node, "value", "Operation 'gte' requires field 'value'")
      err -> err
    end
  end

  defp validate_operation("lt", node) do
    case require_field(node, "field", "Operation 'lt' requires field 'field'") do
      :ok -> require_field(node, "value", "Operation 'lt' requires field 'value'")
      err -> err
    end
  end

  defp validate_operation("lte", node) do
    case require_field(node, "field", "Operation 'lte' requires field 'field'") do
      :ok -> require_field(node, "value", "Operation 'lte' requires field 'value'")
      err -> err
    end
  end

  # Comparison: contains
  defp validate_operation("contains", node) do
    case require_field(node, "field", "Operation 'contains' requires field 'field'") do
      :ok -> require_field(node, "value", "Operation 'contains' requires field 'value'")
      err -> err
    end
  end

  # Access operations
  defp validate_operation("get", node) do
    case Map.get(node, "path") do
      nil ->
        {:error, {:validation_error, "Operation 'get' requires field 'path'"}}

      path when not is_list(path) ->
        {:error, {:validation_error, "Field 'path' must be a list"}}

      path ->
        Enum.all?(path, &is_binary/1)
        |> case do
          true -> :ok
          false -> {:error, {:validation_error, "All path elements in 'path' must be strings"}}
        end
    end
  end

  # Aggregations
  defp validate_operation("sum", node) do
    case Map.get(node, "field") do
      nil -> {:error, {:validation_error, "Operation 'sum' requires field 'field'"}}
      field when is_binary(field) -> :ok
      _ -> {:error, {:validation_error, "Field 'field' must be a string"}}
    end
  end

  defp validate_operation("count", _node) do
    :ok
  end

  defp validate_operation("avg", node) do
    validate_aggregation_field(node, "avg")
  end

  defp validate_operation("min", node) do
    validate_aggregation_field(node, "min")
  end

  defp validate_operation("max", node) do
    validate_aggregation_field(node, "max")
  end

  defp validate_operation("first", _node) do
    :ok
  end

  defp validate_operation("last", _node) do
    :ok
  end

  defp validate_operation("nth", node) do
    case Map.get(node, "index") do
      nil ->
        {:error, {:validation_error, "Operation 'nth' requires field 'index'"}}

      index when is_integer(index) and index >= 0 ->
        :ok

      index when is_integer(index) ->
        {:error, {:validation_error, "Operation 'nth' index must be non-negative, got #{index}"}}

      _ ->
        {:error, {:validation_error, "Operation 'nth' field 'index' must be an integer"}}
    end
  end

  defp validate_operation("reject", node) do
    with :ok <- require_field(node, "where", "Operation 'reject' requires field 'where'") do
      validate_node(Map.get(node, "where"))
    end
  end

  # Tool integration
  defp validate_operation("call", node) do
    with :ok <- require_field(node, "tool", "Operation 'call' requires field 'tool'") do
      case Map.get(node, "args") do
        nil -> :ok
        args when is_map(args) -> :ok
        _ -> {:error, {:validation_error, "Field 'args' must be a map"}}
      end
    end
  end

  # Unknown operation
  defp validate_operation(op, _node) do
    suggestion = suggest_operation(op)
    {:error, {:validation_error, "Unknown operation '#{op}'#{suggestion}"}}
  end

  @valid_operations ~w(literal load var let if and or not merge concat zip pipe filter map select eq neq gt gte lt lte contains get sum count avg min max first last nth reject call)

  defp suggest_operation(unknown_op) do
    @valid_operations
    |> Enum.map(fn valid -> {valid, String.jaro_distance(String.downcase(unknown_op), valid)} end)
    |> Enum.max_by(fn {_op, score} -> score end)
    |> case do
      {suggested, score} when score > 0.8 -> ". Did you mean '#{suggested}'?"
      _ -> ""
    end
  end

  defp require_field(node, field, message) do
    case Map.has_key?(node, field) do
      true -> :ok
      false -> {:error, {:validation_error, message}}
    end
  end

  defp validate_aggregation_field(node, op_name) do
    case Map.get(node, "field") do
      nil -> {:error, {:validation_error, "Operation '#{op_name}' requires field 'field'"}}
      field when is_binary(field) -> :ok
      _ -> {:error, {:validation_error, "Field 'field' must be a string"}}
    end
  end

  defp validate_list(list) do
    Enum.reduce_while(list, :ok, fn node, :ok ->
      case validate_node(node) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_let_name(node) do
    case Map.get(node, "name") do
      name when is_binary(name) -> :ok
      _ -> {:error, {:validation_error, "Field 'name' must be a string"}}
    end
  end
end
