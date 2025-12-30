defmodule PtcRunner.SubAgent.Signature.Validator do
  @moduledoc """
  Validates data against signature type specifications.

  Provides strict validation with path-based error reporting.
  """

  @type validation_error :: %{
          path: [String.t() | non_neg_integer()],
          message: String.t()
        }

  @doc """
  Validate data against a signature AST.

  Returns :ok or {:error, [validation_error()]}
  """
  @spec validate(term(), term()) :: :ok | {:error, [validation_error()]}
  def validate(data, signature) do
    case validate_type(data, signature, []) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # ============================================================
  # Type Validation
  # ============================================================

  # Primitive types
  defp validate_type(data, :string, path) do
    if is_binary(data) do
      []
    else
      [error_at(path, "expected string, got #{type_name(data)}")]
    end
  end

  defp validate_type(data, :int, path) do
    if is_integer(data) and not is_boolean(data) do
      []
    else
      [error_at(path, "expected int, got #{type_name(data)}")]
    end
  end

  defp validate_type(data, :float, path) do
    if is_float(data) do
      []
    else
      [error_at(path, "expected float, got #{type_name(data)}")]
    end
  end

  defp validate_type(data, :bool, path) do
    if is_boolean(data) do
      []
    else
      [error_at(path, "expected bool, got #{type_name(data)}")]
    end
  end

  defp validate_type(data, :keyword, path) do
    if is_atom(data) do
      []
    else
      [error_at(path, "expected keyword, got #{type_name(data)}")]
    end
  end

  defp validate_type(data, :map, path) do
    if is_map(data) do
      []
    else
      [error_at(path, "expected map, got #{type_name(data)}")]
    end
  end

  defp validate_type(_data, :any, _path) do
    # :any matches everything
    []
  end

  # Optional types
  defp validate_type(nil, {:optional, _type}, _path) do
    []
  end

  defp validate_type(data, {:optional, type}, path) do
    validate_type(data, type, path)
  end

  # List types
  defp validate_type(data, {:list, element_type}, path) do
    if is_list(data) do
      data
      |> Enum.with_index()
      |> Enum.flat_map(fn {element, index} ->
        validate_type(element, element_type, path ++ [index])
      end)
    else
      [error_at(path, "expected list, got #{type_name(data)}")]
    end
  end

  # Map types with field validation
  defp validate_type(data, {:map, fields}, path) do
    if is_map(data) do
      validate_map_fields(data, fields, path)
    else
      [error_at(path, "expected map, got #{type_name(data)}")]
    end
  end

  # ============================================================
  # Map Field Validation
  # ============================================================

  defp validate_map_fields(data, fields, path) do
    Enum.flat_map(fields, fn {field_name, field_type} ->
      case get_field(data, field_name) do
        {:ok, value} ->
          validate_type(value, field_type, path ++ [field_name])

        :missing ->
          # Check if field is optional
          if optional?(field_type) do
            []
          else
            [error_at(path ++ [field_name], "expected field, got nil")]
          end
      end
    end)
  end

  # Try both atom and string keys
  defp get_field(data, field_name) when is_map(data) do
    cond do
      Map.has_key?(data, String.to_atom(field_name)) ->
        {:ok, Map.get(data, String.to_atom(field_name))}

      Map.has_key?(data, field_name) ->
        {:ok, Map.get(data, field_name)}

      true ->
        :missing
    end
  end

  defp get_field(_data, _field_name) do
    :missing
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp optional?({:optional, _type}), do: true
  defp optional?(_), do: false

  defp type_name(data) when is_binary(data), do: "string"
  defp type_name(data) when is_integer(data) and not is_boolean(data), do: "int"
  defp type_name(data) when is_float(data), do: "float"
  defp type_name(data) when is_boolean(data), do: "bool"
  defp type_name(data) when is_atom(data), do: "keyword"
  defp type_name(data) when is_map(data), do: "map"
  defp type_name(data) when is_list(data), do: "list"
  defp type_name(data), do: inspect(data)

  defp error_at(path, message) do
    %{path: path, message: message}
  end
end
