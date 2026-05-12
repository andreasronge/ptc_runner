defmodule PtcRunner.SubAgent.Signature.Validator do
  @moduledoc """
  Validates data against signature type specifications.

  Provides strict validation with path-based error reporting.
  """

  alias PtcRunner.SubAgent.KeyNormalizer

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
    if is_float(data) or is_integer(data) do
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

  # `:datetime` accepts only `%DateTime{}` post-coercion. A bare ISO string
  # would mean coercion ran but didn't produce the canonical form — that's a
  # validator bug, not a happy path. Hard-fail on anything else so misuse
  # surfaces immediately.
  defp validate_type(%DateTime{}, :datetime, _path), do: []

  defp validate_type(data, :datetime, path) do
    [error_at(path, "expected datetime (%DateTime{}), got #{type_name(data)}")]
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

  # Closed maps (from a JSON Schema `additionalProperties: false`): every
  # declared field is validated as usual *and* any undeclared key is an
  # error, so fields the caller explicitly excluded can't leak through.
  defp validate_type(data, {:closed_map, fields}, path) do
    if is_map(data) do
      validate_map_fields(data, fields, path) ++ validate_no_extra_fields(data, fields, path)
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

  # Compare data keys against declared field names, normalizing both sides
  # (atom→string, hyphen→underscore) so a Clojure-style `:user-id` data key
  # still counts as covering a declared `"user_id"` field. Anything left over
  # is an undeclared field.
  defp validate_no_extra_fields(data, fields, path) do
    declared =
      fields
      |> Enum.map(fn {name, _type} -> KeyNormalizer.normalize_key(name) end)
      |> MapSet.new()

    data
    |> Map.keys()
    |> Enum.reject(fn key -> MapSet.member?(declared, KeyNormalizer.normalize_key(key)) end)
    |> Enum.sort_by(&inspect/1)
    |> Enum.map(fn key ->
      error_at(
        path ++ [path_segment(key)],
        "unexpected field — schema disallows additional properties"
      )
    end)
  end

  defp path_segment(key) when is_binary(key) or is_atom(key), do: to_string(key)
  defp path_segment(key), do: inspect(key)

  # Try several key forms so signature field names match regardless of which
  # convention the data uses (Clojure-style `:user-id`, JSON-style `"user-id"`,
  # or normalized `:user_id` / `"user_id"`). PTC-Lisp keyword-keyed maps reach
  # the validator with hyphenated atom keys; Elixir-side tools typically use
  # underscored atom or string keys.
  defp get_field(data, field_name) when is_map(data) do
    normalized = KeyNormalizer.normalize_key(field_name)

    candidates =
      Enum.uniq([
        normalized,
        field_name,
        hyphenate(normalized)
      ])

    Enum.reduce_while(candidates, :missing, fn key, _acc ->
      case try_key(data, key) do
        {:ok, _} = result -> {:halt, result}
        :missing -> {:cont, :missing}
      end
    end)
  end

  defp get_field(_data, _field_name) do
    :missing
  end

  # Look up a string key by trying it both as a string and as an existing atom.
  defp try_key(data, key) when is_binary(key) do
    case try_existing_atom_key(data, key) do
      {:ok, _} = result ->
        result

      :missing ->
        if Map.has_key?(data, key), do: {:ok, Map.get(data, key)}, else: :missing
    end
  end

  defp try_existing_atom_key(data, field_name) do
    atom_key = String.to_existing_atom(field_name)
    if Map.has_key?(data, atom_key), do: {:ok, Map.get(data, atom_key)}, else: :missing
  rescue
    ArgumentError -> :missing
  end

  defp hyphenate(name) when is_binary(name), do: String.replace(name, "_", "-")

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
