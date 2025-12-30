defmodule PtcRunner.SubAgent.Signature.Coercion do
  @moduledoc """
  Coerce values to expected types with warning generation.

  This module handles lenient input validation for LLMs, which sometimes
  produce slightly malformed data (e.g., quoted numbers, missing types).

  ## Coercion Rules

  Input coercion is lenient with warnings:
  - `"42"` → `:int` produces `42` with warning
  - `"3.14"` → `:float` produces `3.14` with warning
  - `42` → `:float` produces `42.0` silently (widening is safe)
  - `42.0` → `:int` produces error (precision loss not allowed)

  Output validation is strict - no coercion applied.

  ## Special Types

  - DateTime, Date, Time, NaiveDateTime: Accept ISO 8601 strings
  - Atoms: Coerce atoms to strings, strings to atoms (using `String.to_existing_atom/1`)

  ## Examples

      iex> Coercion.coerce("42", :int)
      {:ok, 42, ["coerced string \\"42\\" to integer"]}

      iex> Coercion.coerce(42, :float)
      {:ok, 42.0, []}

      iex> Coercion.coerce("hello", :int)
      {:error, "cannot coerce string \\"hello\\" to integer"}

      iex> Coercion.coerce("hello", :keyword)
      {:ok, :hello, ["coerced string \\"hello\\" to keyword"]}
  """

  @type coercion_result :: {:ok, term(), [String.t()]} | {:error, String.t()}

  @doc """
  Coerce a value to the expected type.

  Returns `{:ok, coerced_value, warnings}` or `{:error, reason}`.

  ## Examples

      iex> Coercion.coerce("42", :int)
      {:ok, 42, ["coerced string \\"42\\" to integer"]}

      iex> Coercion.coerce(42, :float)
      {:ok, 42.0, []}

      iex> Coercion.coerce("hello", :int)
      {:error, "cannot coerce string \\"hello\\" to integer"}

      iex> Coercion.coerce_input(%{"id" => "42", "name" => "Alice"}, {:map, [{"id", :int}, {"name", :string}]})
      {:ok, %{"id" => 42, "name" => "Alice"}, ["coerced string \\"42\\" to integer"]}
  """
  @spec coerce(term(), atom() | tuple()) :: coercion_result()
  def coerce(value, type) do
    coerce(value, type, [])
  end

  @doc """
  Coerce a value to the expected type with options.

  Options:
  - `:nested` - whether this is a nested coercion (default: false)

  Returns `{:ok, coerced_value, warnings}` or `{:error, reason}`.
  """
  @spec coerce(term(), atom() | tuple(), keyword()) :: coercion_result()
  def coerce(value, type, _opts) do
    coerce_impl(value, type)
  end

  # ============================================================
  # Primitive Type Coercion
  # ============================================================

  defp coerce_impl(value, :string) when is_binary(value) do
    {:ok, value, []}
  end

  defp coerce_impl(value, :string) when is_atom(value) do
    {:ok, atom_to_string(value), ["coerced keyword to string"]}
  end

  defp coerce_impl(_value, :string) do
    {:error, "cannot coerce to string"}
  end

  defp coerce_impl(value, :int) when is_integer(value) and not is_boolean(value) do
    {:ok, value, []}
  end

  defp coerce_impl(value, :int) when is_binary(value) do
    coerce_string_to_int(value)
  end

  defp coerce_impl(_value, :int) do
    {:error, "cannot coerce to integer"}
  end

  defp coerce_impl(value, :float) when is_float(value) do
    {:ok, value, []}
  end

  defp coerce_impl(value, :float) when is_integer(value) and not is_boolean(value) do
    {:ok, float(value), []}
  end

  defp coerce_impl(value, :float) when is_binary(value) do
    coerce_string_to_float(value)
  end

  defp coerce_impl(_value, :float) do
    {:error, "cannot coerce to float"}
  end

  defp coerce_impl(value, :bool) when is_boolean(value) do
    {:ok, value, []}
  end

  defp coerce_impl(value, :bool) when is_binary(value) do
    coerce_string_to_bool(value)
  end

  defp coerce_impl(_value, :bool) do
    {:error, "cannot coerce to boolean"}
  end

  defp coerce_impl(value, :keyword) when is_atom(value) do
    {:ok, value, []}
  end

  defp coerce_impl(value, :keyword) when is_binary(value) do
    coerce_string_to_keyword(value)
  end

  defp coerce_impl(_value, :keyword) do
    {:error, "cannot coerce to keyword"}
  end

  defp coerce_impl(value, :any) do
    {:ok, value, []}
  end

  defp coerce_impl(value, :map) when is_map(value) do
    {:ok, value, []}
  end

  defp coerce_impl(_value, :map) do
    {:error, "cannot coerce to map"}
  end

  # Optional types
  defp coerce_impl(nil, {:optional, _type}) do
    {:ok, nil, []}
  end

  defp coerce_impl(value, {:optional, type}) do
    coerce_impl(value, type)
  end

  # List types
  defp coerce_impl(value, {:list, element_type}) when is_list(value) do
    coerce_list(value, element_type, [])
  end

  defp coerce_impl(_value, {:list, _element_type}) do
    {:error, "cannot coerce to list"}
  end

  # Map types with fields
  defp coerce_impl(value, {:map, fields}) when is_map(value) do
    coerce_map(value, fields, %{}, [])
  end

  defp coerce_impl(_value, {:map, _fields}) do
    {:error, "cannot coerce to map"}
  end

  # Catch-all for unknown types
  defp coerce_impl(_value, _type) do
    {:error, "unsupported type"}
  end

  # ============================================================
  # String to Int Coercion
  # ============================================================

  defp coerce_string_to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {num, ""} ->
        warning = "coerced string \"#{value}\" to integer"
        {:ok, num, [warning]}

      _ ->
        {:error, "cannot coerce string \"#{value}\" to integer"}
    end
  end

  # ============================================================
  # String to Float Coercion
  # ============================================================

  defp coerce_string_to_float(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {num, ""} ->
        warning = "coerced string \"#{value}\" to float"
        {:ok, num, [warning]}

      {num, _rest} ->
        # Successfully parsed some of it - if it's a whole number conversion, accept it
        warning = "coerced string \"#{value}\" to float"
        {:ok, num, [warning]}

      :error ->
        # Try integer first (in case it's a whole number like "42")
        case Integer.parse(trimmed) do
          {num, ""} ->
            warning = "coerced string \"#{value}\" to float"
            {:ok, float(num), [warning]}

          _ ->
            {:error, "cannot coerce string \"#{value}\" to float"}
        end
    end
  end

  # ============================================================
  # String to Bool Coercion
  # ============================================================

  defp coerce_string_to_bool("true") do
    warning = "coerced string \"true\" to boolean"
    {:ok, true, [warning]}
  end

  defp coerce_string_to_bool("false") do
    warning = "coerced string \"false\" to boolean"
    {:ok, false, [warning]}
  end

  defp coerce_string_to_bool(value) do
    {:error, "cannot coerce string \"#{value}\" to boolean"}
  end

  # ============================================================
  # String to Keyword Coercion
  # ============================================================

  defp coerce_string_to_keyword(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    warning = "coerced string \"#{value}\" to keyword"
    {:ok, atom, [warning]}
  rescue
    ArgumentError ->
      {:error, "cannot coerce string \"#{value}\" to keyword"}
  end

  # ============================================================
  # List Coercion
  # ============================================================

  defp coerce_list([], _element_type, warnings) do
    {:ok, [], warnings}
  end

  defp coerce_list([head | tail], element_type, acc_warnings) do
    case coerce_impl(head, element_type) do
      {:ok, coerced_head, head_warnings} ->
        case coerce_list(tail, element_type, acc_warnings ++ head_warnings) do
          {:ok, coerced_tail, final_warnings} ->
            {:ok, [coerced_head | coerced_tail], final_warnings}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================
  # Map Coercion
  # ============================================================

  defp coerce_map(data, [], acc, warnings) when is_map(data) do
    {:ok, acc, warnings}
  end

  defp coerce_map(data, [{field_name, field_type} | rest], acc, warnings) when is_map(data) do
    case get_field_with_key(data, field_name) do
      {:ok, value, key} ->
        case coerce_impl(value, field_type) do
          {:ok, coerced_value, field_warnings} ->
            new_acc = Map.put(acc, key, coerced_value)
            coerce_map(data, rest, new_acc, warnings ++ field_warnings)

          {:error, reason} ->
            {:error, reason}
        end

      :missing ->
        # Check if field is optional
        if optional?(field_type) do
          coerce_map(data, rest, acc, warnings)
        else
          {:error, "missing required field \"#{field_name}\""}
        end
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  # Get field with the original key that was used
  defp get_field_with_key(data, field_name) when is_map(data) do
    atom_key = String.to_atom(field_name)

    cond do
      Map.has_key?(data, atom_key) ->
        {:ok, Map.get(data, atom_key), atom_key}

      Map.has_key?(data, field_name) ->
        {:ok, Map.get(data, field_name), field_name}

      true ->
        :missing
    end
  end

  defp optional?({:optional, _type}), do: true
  defp optional?(_), do: false

  defp atom_to_string(atom) when is_atom(atom) do
    atom |> Atom.to_string()
  end

  defp float(value) when is_integer(value) do
    value * 1.0
  end
end
