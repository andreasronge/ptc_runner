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

  # Unknown operation
  defp validate_operation(op, _node) do
    {:error, {:validation_error, "Unknown operation '#{op}'"}}
  end

  defp require_field(node, field, message) do
    case Map.has_key?(node, field) do
      true -> :ok
      false -> {:error, {:validation_error, message}}
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
end
