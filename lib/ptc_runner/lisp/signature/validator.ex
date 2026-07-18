defmodule PtcRunner.Lisp.Signature.Validator do
  @moduledoc """
  Validates data against signature type specifications.

  Provides strict validation with path-based error reporting.
  """

  alias PtcRunner.Lisp.KeyNormalizer
  alias PtcRunner.Lisp.Keyword, as: LispKeyword

  @type validation_error :: %{
          path: [String.t() | non_neg_integer()],
          message: String.t()
        }

  @doc """
  Validate data against a signature AST.

  Returns :ok or {:error, [validation_error()]}
  """
  @spec validate(term(), term(), keyword()) :: :ok | {:error, [validation_error()]}
  def validate(data, signature, opts \\ []) do
    keyword_representation = Keyword.get(opts, :keyword_representation, :externalized)
    max_errors = Keyword.get(opts, :max_errors, :infinity)

    unless max_errors == :infinity or (is_integer(max_errors) and max_errors > 0) do
      raise ArgumentError, ":max_errors must be a positive integer or :infinity"
    end

    case validate_type(data, signature, [], keyword_representation, max_errors) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # ============================================================
  # Type Validation
  # ============================================================

  # Primitive types
  defp validate_type(data, :string, path, _keyword_representation, _max_errors) do
    if is_binary(data) do
      []
    else
      [error_at(path, "expected string, got #{type_name(data)}")]
    end
  end

  defp validate_type(data, :int, path, _keyword_representation, _max_errors) do
    if is_integer(data) and not is_boolean(data) do
      []
    else
      [error_at(path, "expected int, got #{type_name(data)}")]
    end
  end

  defp validate_type(data, :float, path, _keyword_representation, _max_errors) do
    if is_float(data) or is_integer(data) do
      []
    else
      [error_at(path, "expected float, got #{type_name(data)}")]
    end
  end

  defp validate_type(data, :bool, path, _keyword_representation, _max_errors) do
    if is_boolean(data) do
      []
    else
      [error_at(path, "expected bool, got #{type_name(data)}")]
    end
  end

  # A keyword outside the bounded vocabulary externalizes to a plain binary
  # (#964), so the public post-externalization validator accepts a binary whose
  # contents form a valid keyword name. Prelude contracts run on internal Lisp
  # values and select `:internal`, where ordinary strings must remain distinct.
  defp validate_type(data, :keyword, path, keyword_representation, _max_errors) do
    cond do
      LispKeyword.keyword?(data) ->
        []

      keyword_representation == :externalized and is_binary(data) and
          LispKeyword.valid_name?(data) ->
        []

      true ->
        [error_at(path, "expected keyword, got #{type_name(data)}")]
    end
  end

  defp validate_type(data, :map, path, _keyword_representation, _max_errors) do
    if plain_map?(data) do
      []
    else
      [error_at(path, "expected map, got #{type_name(data)}")]
    end
  end

  defp validate_type(_data, :any, _path, _keyword_representation, _max_errors) do
    # :any matches everything
    []
  end

  # `:datetime` accepts only `%DateTime{}` post-coercion. A bare ISO string
  # would mean coercion ran but didn't produce the canonical form — that's a
  # validator bug, not a happy path. Hard-fail on anything else so misuse
  # surfaces immediately.
  defp validate_type(%DateTime{}, :datetime, _path, _keyword_representation, _max_errors),
    do: []

  defp validate_type(data, :datetime, path, _keyword_representation, _max_errors) do
    [error_at(path, "expected datetime (%DateTime{}), got #{type_name(data)}")]
  end

  # Optional types
  defp validate_type(nil, {:optional, _type}, _path, _keyword_representation, _max_errors) do
    []
  end

  defp validate_type(data, {:optional, type}, path, keyword_representation, max_errors) do
    validate_type(data, type, path, keyword_representation, max_errors)
  end

  # List types
  defp validate_type(data, {:list, element_type}, path, keyword_representation, max_errors) do
    if is_list(data) do
      data
      |> Enum.with_index()
      |> validate_many(max_errors, fn {element, index}, remaining ->
        validate_type(
          element,
          element_type,
          path ++ [index],
          keyword_representation,
          remaining
        )
      end)
    else
      [error_at(path, "expected list, got #{type_name(data)}")]
    end
  end

  # Map types with field validation
  defp validate_type(data, {:map, fields}, path, keyword_representation, max_errors) do
    if plain_map?(data) do
      validate_map_fields(data, fields, path, keyword_representation, max_errors)
    else
      [error_at(path, "expected map, got #{type_name(data)}")]
    end
  end

  # Closed maps (from a JSON Schema `additionalProperties: false`): every
  # declared field is validated as usual *and* any undeclared key is an
  # error, so fields the caller explicitly excluded can't leak through.
  defp validate_type(
         data,
         {:closed_map, fields},
         path,
         keyword_representation,
         max_errors
       ) do
    if plain_map?(data) do
      {field_errors, consumed_keys} =
        validate_map_fields_tracking(data, fields, path, keyword_representation, max_errors)

      remaining = remaining_errors(max_errors, length(field_errors))
      field_errors ++ validate_no_extra_fields(data, consumed_keys, path, remaining)
    else
      [error_at(path, "expected map, got #{type_name(data)}")]
    end
  end

  # ============================================================
  # Map Field Validation
  # ============================================================

  defp validate_map_fields(data, fields, path, keyword_representation, max_errors) do
    {errors, _consumed} =
      validate_map_fields_tracking(data, fields, path, keyword_representation, max_errors)

    errors
  end

  # Like validate_map_fields/3 but also returns the set of consumed data keys
  # so validate_no_extra_fields can flag unconsumed ones directly.
  defp validate_map_fields_tracking(data, fields, path, keyword_representation, max_errors) do
    {errors_reversed, _count, consumed} =
      Enum.reduce_while(fields, {[], 0, MapSet.new()}, fn field, accumulator ->
        validate_map_field(
          field,
          accumulator,
          data,
          path,
          keyword_representation,
          max_errors
        )
      end)

    {Enum.reverse(errors_reversed), consumed}
  end

  defp validate_map_field(
         {field_name, field_type},
         {errs, count, keys},
         data,
         path,
         keyword_representation,
         max_errors
       ) do
    remaining = remaining_errors(max_errors, count)

    if remaining == 0 do
      {:halt, {errs, count, keys}}
    else
      validate_map_field_value(
        get_field(data, field_name),
        field_name,
        field_type,
        {errs, count, keys},
        path,
        keyword_representation,
        remaining
      )
    end
  end

  defp validate_map_field_value(
         {:ok, matched_key, value},
         field_name,
         field_type,
         {errs, count, keys},
         path,
         keyword_representation,
         remaining
       ) do
    field_errors =
      validate_type(
        value,
        field_type,
        path ++ [field_name],
        keyword_representation,
        remaining
      )

    {:cont,
     {Enum.reverse(field_errors, errs), count + length(field_errors),
      MapSet.put(keys, matched_key)}}
  end

  defp validate_map_field_value(
         {:ambiguous, matched_keys},
         field_name,
         _field_type,
         {errs, count, keys},
         path,
         _keyword_representation,
         _remaining
       ) do
    field_error =
      error_at(
        path ++ [field_name],
        "ambiguous field aliases — provide exactly one representation of this field"
      )

    {:cont,
     {[field_error | errs], count + 1, Enum.reduce(matched_keys, keys, &MapSet.put(&2, &1))}}
  end

  defp validate_map_field_value(
         :missing,
         field_name,
         field_type,
         accumulator,
         path,
         _keyword_representation,
         _remaining
       ) do
    missing_map_field(field_name, field_type, accumulator, path)
  end

  defp missing_map_field(_field_name, {:optional, _type}, accumulator, _path),
    do: {:cont, accumulator}

  defp missing_map_field(field_name, _field_type, {errs, count, keys}, path) do
    error = error_at(path ++ [field_name], "expected field, got nil")
    {:cont, {[error | errs], count + 1, keys}}
  end

  # Flag every data key that was not consumed by a declared field.
  defp validate_no_extra_fields(_data, _consumed_keys, _path, 0), do: []

  defp validate_no_extra_fields(data, consumed_keys, path, max_errors) do
    extra_keys =
      data
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(consumed_keys, &1))
      |> Enum.sort_by(&inspect/1)

    extra_keys =
      if max_errors == :infinity, do: extra_keys, else: Enum.take(extra_keys, max_errors)

    Enum.map(extra_keys, fn key ->
      error_at(
        path ++ [path_segment(key)],
        "unexpected field — schema disallows additional properties"
      )
    end)
  end

  defp validate_many(values, max_errors, validator) do
    {errors_reversed, _count} =
      Enum.reduce_while(values, {[], 0}, fn value, {errors, count} ->
        remaining = remaining_errors(max_errors, count)

        if remaining == 0 do
          {:halt, {errors, count}}
        else
          new_errors = validator.(value, remaining)
          new_count = count + length(new_errors)
          next = {Enum.reverse(new_errors, errors), new_count}

          if remaining_errors(max_errors, new_count) == 0,
            do: {:halt, next},
            else: {:cont, next}
        end
      end)

    Enum.reverse(errors_reversed)
  end

  defp remaining_errors(:infinity, _used), do: :infinity
  defp remaining_errors(max_errors, used), do: max(max_errors - used, 0)

  defp path_segment(%LispKeyword{name: name}), do: name
  defp path_segment(key) when is_binary(key) or is_atom(key), do: to_string(key)
  defp path_segment(key), do: inspect(key)

  # Match the complete alias-equivalence class for one declared field:
  # Clojure-style `:user-id`, JSON-style `"user-id"`, and normalized atom or
  # string `user_id` keys. Exactly one physical key may represent a field.
  # Accepting more would let validation inspect one value while flexible Lisp
  # lookup consumes another value from the same map.
  defp get_field(data, field_name) when is_map(data) and not is_struct(data) do
    normalized = KeyNormalizer.normalize_key(field_name)

    matches =
      Enum.filter(data, fn {key, _value} -> normalized_field_key(key) == normalized end)

    case matches do
      [] -> :missing
      [{key, value}] -> {:ok, key, value}
      matches -> {:ambiguous, Enum.map(matches, &elem(&1, 0))}
    end
  end

  defp get_field(_data, _field_name) do
    :missing
  end

  defp normalized_field_key(%LispKeyword{name: name}), do: KeyNormalizer.normalize_key(name)

  defp normalized_field_key(key) when is_binary(key) or is_atom(key),
    do: KeyNormalizer.normalize_key(key)

  defp normalized_field_key(_key), do: nil

  # ============================================================
  # Helpers
  # ============================================================

  defp plain_map?(data), do: is_map(data) and not is_struct(data)

  defp type_name(data) when is_binary(data), do: "string"
  defp type_name(data) when is_integer(data) and not is_boolean(data), do: "int"
  defp type_name(data) when is_float(data), do: "float"
  defp type_name(data) when is_boolean(data), do: "bool"
  defp type_name(nil), do: "nil"
  defp type_name(data) when is_atom(data), do: "keyword"
  defp type_name(%LispKeyword{}), do: "keyword"
  defp type_name(data) when is_map(data) and not is_struct(data), do: "map"
  defp type_name(data) when is_list(data), do: "list"
  defp type_name({:closure, _, _, _, _, _}), do: "function"
  defp type_name(data) when is_function(data), do: "function"
  defp type_name(_data), do: "unknown"

  defp error_at(path, message) do
    %{path: path, message: message}
  end
end
