defmodule PtcRunner.Json.Validator do
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

  defp validate_operation(op, node) do
    case PtcRunner.Schema.get_operation(op) do
      {:ok, definition} ->
        validate_fields(op, node, definition)

      :error ->
        suggestion = suggest_operation(op)
        {:error, {:validation_error, "Unknown operation '#{op}'#{suggestion}"}}
    end
  end

  defp validate_fields(op, node, definition) do
    fields = Map.get(definition, "fields", %{})

    # Special case: handle operations that need custom validation
    case op do
      "let" -> validate_let(op, node, fields)
      "nth" -> validate_nth(node, fields)
      "take" -> validate_take(node, fields)
      "drop" -> validate_drop(node, fields)
      "select" -> validate_select(node, fields)
      "get" -> validate_get(node, fields)
      "sort_by" -> validate_sort_by(node, fields)
      "object" -> validate_object(op, node, fields)
      _ -> validate_fields_generic(op, node, fields)
    end
  end

  defp validate_object(op, node, fields) do
    with :ok <- validate_required_fields(op, node, fields) do
      fields_map = Map.get(node, "fields", %{})

      validate_object_fields(fields_map)
    end
  end

  defp validate_object_fields(fields_map) when is_map(fields_map) do
    Enum.reduce_while(fields_map, :ok, fn {_key, value}, :ok ->
      case validate_object_field_value(value) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_object_fields(_fields_map) do
    {:error, {:validation_error, "Field 'fields' must be a map"}}
  end

  defp validate_object_field_value(value) when is_map(value) and is_map_key(value, "op") do
    validate_node(value)
  end

  defp validate_object_field_value(_value) do
    :ok
  end

  defp validate_let(op, node, fields) do
    with :ok <- validate_required_fields(op, node, fields),
         :ok <- validate_let_name(node),
         :ok <- validate_node(Map.get(node, "value")) do
      validate_node(Map.get(node, "in"))
    end
  end

  defp validate_nth(node, _fields) do
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

  defp validate_take(node, _fields) do
    case Map.get(node, "count") do
      nil ->
        {:error, {:validation_error, "Operation 'take' requires field 'count'"}}

      count when is_integer(count) and count >= 0 ->
        :ok

      count when is_integer(count) ->
        {:error, {:validation_error, "Operation 'take' count must be non-negative, got #{count}"}}

      _ ->
        {:error, {:validation_error, "Operation 'take' field 'count' must be an integer"}}
    end
  end

  defp validate_drop(node, _fields) do
    case Map.get(node, "count") do
      nil ->
        {:error, {:validation_error, "Operation 'drop' requires field 'count'"}}

      count when is_integer(count) and count >= 0 ->
        :ok

      count when is_integer(count) ->
        {:error, {:validation_error, "Operation 'drop' count must be non-negative, got #{count}"}}

      _ ->
        {:error, {:validation_error, "Operation 'drop' field 'count' must be an integer"}}
    end
  end

  defp validate_select(node, _fields) do
    case Map.get(node, "fields") do
      nil ->
        {:error, {:validation_error, "Operation 'select' requires field 'fields'"}}

      fields_val when not is_list(fields_val) ->
        {:error, {:validation_error, "Field 'fields' must be a list"}}

      fields_val ->
        case Enum.all?(fields_val, &is_binary/1) do
          true -> :ok
          false -> {:error, {:validation_error, "All field names in 'fields' must be strings"}}
        end
    end
  end

  defp validate_get(node, _fields) do
    has_field = Map.has_key?(node, "field")
    has_path = Map.has_key?(node, "path")

    cond do
      has_field and has_path ->
        {:error, {:validation_error, "Operation 'get' accepts 'field' or 'path', not both"}}

      has_field ->
        validate_get_field(Map.get(node, "field"))

      has_path ->
        validate_get_path(Map.get(node, "path"))

      true ->
        {:error, {:validation_error, "Operation 'get' requires either 'field' or 'path'"}}
    end
  end

  defp validate_get_field(field) when is_binary(field), do: :ok
  defp validate_get_field(_), do: {:error, {:validation_error, "Field 'field' must be a string"}}

  defp validate_get_path(path) when not is_list(path) do
    {:error, {:validation_error, "Field 'path' must be a list"}}
  end

  defp validate_get_path(path) do
    if Enum.all?(path, &is_binary/1) do
      :ok
    else
      {:error, {:validation_error, "All path elements in 'path' must be strings"}}
    end
  end

  defp validate_sort_by(node, _fields) do
    case Map.get(node, "field") do
      nil ->
        {:error, {:validation_error, "Operation 'sort_by' requires field 'field'"}}

      field when not is_binary(field) ->
        {:error, {:validation_error, "Field 'field' must be a string"}}

      _field ->
        case Map.get(node, "order") do
          nil ->
            :ok

          order when order in ["asc", "desc"] ->
            :ok

          order ->
            {:error, {:validation_error, "Field 'order' must be 'asc' or 'desc', got '#{order}'"}}
        end
    end
  end

  defp validate_fields_generic(op, node, fields) do
    Enum.reduce_while(fields, :ok, fn {field_name, field_spec}, :ok ->
      required? = Map.get(field_spec, "required", false)
      type = Map.get(field_spec, "type")

      case validate_field(node, op, field_name, type, required?) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_field(node, _op, field_name, _type, false)
       when not is_map_key(node, field_name) do
    :ok
  end

  defp validate_field(node, op, field_name, type, _required?) do
    if Map.has_key?(node, field_name) do
      value = Map.get(node, field_name)
      validate_field_type(op, field_name, value, type)
    else
      {:error, {:validation_error, "Operation '#{op}' requires field '#{field_name}'"}}
    end
  end

  defp validate_field_type(_op, _field_name, _value, :any) do
    :ok
  end

  defp validate_field_type(_op, field_name, value, :string) do
    case is_binary(value) do
      true -> :ok
      false -> {:error, {:validation_error, "Field '#{field_name}' must be a string"}}
    end
  end

  defp validate_field_type(_op, _field_name, value, :expr) do
    validate_node(value)
  end

  defp validate_field_type(_op, field_name, value, :non_neg_integer) do
    case is_integer(value) and value >= 0 do
      true ->
        :ok

      false ->
        {:error, {:validation_error, "Field '#{field_name}' must be a non-negative integer"}}
    end
  end

  defp validate_field_type(_op, field_name, value, :map) do
    case is_map(value) do
      true -> :ok
      false -> {:error, {:validation_error, "Field '#{field_name}' must be a map"}}
    end
  end

  defp validate_field_type(_op, field_name, value, {:list, :expr}) do
    case is_list(value) do
      true -> validate_list(value)
      false -> {:error, {:validation_error, "Field '#{field_name}' must be a list"}}
    end
  end

  defp validate_field_type(_op, field_name, value, {:list, :string}) do
    case is_list(value) do
      true ->
        case Enum.all?(value, &is_binary/1) do
          true ->
            :ok

          false ->
            {:error, {:validation_error, "All elements in '#{field_name}' must be strings"}}
        end

      false ->
        {:error, {:validation_error, "Field '#{field_name}' must be a list"}}
    end
  end

  defp validate_field_type(_op, _field_name, _value, type) do
    {:error, {:validation_error, "Unknown field type: #{inspect(type)}"}}
  end

  defp validate_required_fields(op, node, fields) do
    Enum.reduce_while(fields, :ok, fn {field_name, field_spec}, :ok ->
      required? = Map.get(field_spec, "required", false)

      case {required?, Map.has_key?(node, field_name)} do
        {true, false} ->
          {:halt,
           {:error, {:validation_error, "Operation '#{op}' requires field '#{field_name}'"}}}

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp suggest_operation(unknown_op) do
    PtcRunner.Schema.valid_operation_names()
    |> Enum.map(fn valid -> {valid, String.jaro_distance(String.downcase(unknown_op), valid)} end)
    |> Enum.max_by(fn {_op, score} -> score end)
    |> case do
      {suggested, score} when score > 0.8 -> ". Did you mean '#{suggested}'?"
      _ -> ""
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
