defmodule PtcRunner.Kernel.JSONSchema do
  @moduledoc """
  Internal compiler for the bounded capability JSON Schema profile.

  The accepted profile is a strict subset of JSON Schema 2020-12 containing
  `type`, `title`, `description`, `default`, `properties`, `required`,
  `additionalProperties`, `items`, `enum`, `const`, `minimum`, `maximum`,
  `minLength`, `maxLength`, `minItems`, `maxItems`, and the single bounded
  `sha256` string format. Types are scalar rather than unions, roots are
  objects, and a missing `additionalProperties` on an object is normalized to
  `false`.

  `$schema` selects the schema dialect; absence means the MCP default
  (2020-12). Because the accepted profile is a common subset of the
  allowlisted dialects, a supported root `$schema` URI (2020-12, or draft-07
  as a deliberate compatibility translation) is accepted and removed, while
  unknown, malformed, and nested dialect markers are rejected. Vendor `x-…`
  extension keys and the standard non-validating `default` annotation are
  discarded from every level as a deliberate client policy — mainstream MCP
  SDKs emit them by default. They do not reach normalized output, encodings,
  hashes, or runtime argument construction. All other unknown keywords remain
  rejected.

  Each normalized schema is at most 64 KiB with maximum depth 16, 128
  properties per object, and 256 enum members. Schemas are compiled once with
  JSV. Runtime validation delegates to the compiled JSV root; this module does
  not evaluate schemas.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONSchema.SHA256Format
  alias PtcRunner.Kernel.JSONValue

  @allowed ~w(type title description properties required additionalProperties items enum const minimum maximum minLength maxLength minItems maxItems format)
  @types ~w(null boolean object array number integer string)
  @max_schema_bytes 65_536
  @max_depth 16
  @max_properties 128
  @max_enum_members 256

  @type compiled :: JSV.Root.t()

  @dialects [
    "https://json-schema.org/draft/2020-12/schema",
    "http://json-schema.org/draft-07/schema#"
  ]

  @spec compile(map()) :: {:ok, map(), compiled()} | {:error, :invalid_schema}
  def compile(schema) when is_map(schema) and not is_struct(schema) do
    with {:ok, schema} <- validate_dialect(schema),
         {:ok, normalized} <- normalize(schema, 1),
         true <- normalized["type"] == "object",
         {:ok, encoded} <- DeterministicJSON.encode(normalized),
         true <- byte_size(encoded) <= @max_schema_bytes,
         {:ok, root} <-
           JSV.build(normalized, atoms: false, formats: [SHA256Format], warnings: :silent) do
      {:ok, normalized, root}
    else
      _reason -> {:error, :invalid_schema}
    end
  rescue
    _exception -> {:error, :invalid_schema}
  end

  def compile(_schema), do: {:error, :invalid_schema}

  @spec valid?(compiled(), term()) :: boolean()
  def valid?(root, value) do
    match?({:ok, _validated}, JSV.validate(value, root, cast: false))
  rescue
    _exception -> false
  end

  defp normalize(_schema, depth) when depth > @max_depth, do: {:error, :invalid_schema}

  defp normalize(schema, depth) when is_map(schema) and not is_struct(schema) do
    with true <- JSONValue.map?(schema),
         schema = drop_ignored_annotations(schema),
         true <- Map.keys(schema) -- @allowed == [],
         type when type in @types <- schema["type"],
         :ok <- validate_text(schema, "title"),
         :ok <- validate_text(schema, "description"),
         :ok <- validate_number_bounds(schema),
         :ok <- validate_size_bounds(schema, "minLength", "maxLength"),
         :ok <- validate_size_bounds(schema, "minItems", "maxItems"),
         :ok <- validate_format(schema, type),
         :ok <- validate_const(schema),
         :ok <- validate_enum(schema),
         {:ok, properties} <- normalize_properties(schema, type, depth),
         {:ok, items} <- normalize_items(schema, type, depth),
         :ok <- validate_required(schema, type, properties),
         :ok <- validate_additional_properties(schema, type) do
      normalized =
        schema
        |> maybe_put("properties", properties)
        |> maybe_put("items", items)
        |> normalize_additional_properties(type)

      {:ok, normalized}
    else
      _reason -> {:error, :invalid_schema}
    end
  end

  defp normalize(_schema, _depth), do: {:error, :invalid_schema}

  # A root "$schema" selects the dialect: absence defaults to 2020-12, a
  # supported URI is removed after validation, anything else is rejected.
  # Nested "$schema" is rejected in normalize/2 like any unknown keyword.
  defp validate_dialect(schema) do
    case Map.fetch(schema, "$schema") do
      :error -> {:ok, schema}
      {:ok, dialect} when dialect in @dialects -> {:ok, Map.delete(schema, "$schema")}
      {:ok, _dialect} -> {:error, :invalid_schema}
    end
  end

  # Vendor "x-…" extension keys and JSON Schema's non-validating "default"
  # annotation are discarded as deliberate client policy; mainstream MCP SDKs
  # emit them by default and this profile assigns them no runtime semantics.
  # Unsupported semantic keywords remain rejected.
  defp drop_ignored_annotations(schema) do
    Map.reject(schema, fn {key, _value} ->
      key == "default" or String.starts_with?(key, "x-")
    end)
  end

  defp normalize_properties(schema, "object", depth) do
    case Map.fetch(schema, "properties") do
      :error ->
        {:ok, nil}

      {:ok, properties}
      when is_map(properties) and not is_struct(properties) and
             map_size(properties) <= @max_properties ->
        normalize_schema_map(properties, depth + 1)

      {:ok, _properties} ->
        {:error, :invalid_schema}
    end
  end

  defp normalize_properties(schema, _type, _depth) do
    if Map.has_key?(schema, "properties"),
      do: {:error, :invalid_schema},
      else: {:ok, nil}
  end

  defp normalize_schema_map(properties, depth) do
    Enum.reduce_while(properties, {:ok, %{}}, fn
      {name, child}, {:ok, normalized} when is_binary(name) ->
        case normalize(child, depth) do
          {:ok, normalized_child} ->
            {:cont, {:ok, Map.put(normalized, name, normalized_child)}}

          error ->
            {:halt, error}
        end

      _property, _acc ->
        {:halt, {:error, :invalid_schema}}
    end)
  end

  defp normalize_items(schema, "array", depth) do
    case Map.fetch(schema, "items") do
      {:ok, items} -> normalize(items, depth + 1)
      :error -> {:ok, nil}
    end
  end

  defp normalize_items(schema, _type, _depth) do
    if Map.has_key?(schema, "items"),
      do: {:error, :invalid_schema},
      else: {:ok, nil}
  end

  defp validate_required(schema, "object", properties) do
    case Map.get(schema, "required", []) do
      required when is_list(required) and length(required) <= @max_properties ->
        unique = MapSet.new(required)

        if Enum.all?(required, &is_binary/1) and MapSet.size(unique) == length(required) and
             Enum.all?(required, &Map.has_key?(properties || %{}, &1)),
           do: :ok,
           else: {:error, :invalid_schema}

      _required ->
        {:error, :invalid_schema}
    end
  end

  defp validate_required(schema, _type, _properties) do
    if Map.has_key?(schema, "required"),
      do: {:error, :invalid_schema},
      else: :ok
  end

  defp validate_additional_properties(schema, "object") do
    case Map.get(schema, "additionalProperties", false) do
      value when is_boolean(value) -> :ok
      _value -> {:error, :invalid_schema}
    end
  end

  defp validate_additional_properties(schema, _type) do
    if Map.has_key?(schema, "additionalProperties"),
      do: {:error, :invalid_schema},
      else: :ok
  end

  defp normalize_additional_properties(schema, "object"),
    do: Map.put_new(schema, "additionalProperties", false)

  defp normalize_additional_properties(schema, _type), do: schema

  defp validate_text(schema, key) do
    case Map.fetch(schema, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      {:ok, _value} -> {:error, :invalid_schema}
    end
  end

  defp validate_number_bounds(schema) do
    minimum = Map.get(schema, "minimum")
    maximum = Map.get(schema, "maximum")

    cond do
      not valid_optional_number?(minimum) ->
        {:error, :invalid_schema}

      not valid_optional_number?(maximum) ->
        {:error, :invalid_schema}

      is_number(minimum) and is_number(maximum) and minimum > maximum ->
        {:error, :invalid_schema}

      true ->
        :ok
    end
  end

  defp validate_format(schema, "string") do
    case Map.fetch(schema, "format") do
      :error -> :ok
      {:ok, "sha256"} -> :ok
      {:ok, _format} -> {:error, :invalid_schema}
    end
  end

  defp validate_format(schema, _type) do
    if Map.has_key?(schema, "format"),
      do: {:error, :invalid_schema},
      else: :ok
  end

  defp validate_size_bounds(schema, minimum_key, maximum_key) do
    minimum = Map.get(schema, minimum_key)
    maximum = Map.get(schema, maximum_key)

    cond do
      not valid_optional_non_negative_integer?(minimum) ->
        {:error, :invalid_schema}

      not valid_optional_non_negative_integer?(maximum) ->
        {:error, :invalid_schema}

      is_integer(minimum) and is_integer(maximum) and minimum > maximum ->
        {:error, :invalid_schema}

      true ->
        :ok
    end
  end

  defp validate_const(schema) do
    case Map.fetch(schema, "const") do
      :error -> :ok
      {:ok, value} -> if JSONValue.value?(value), do: :ok, else: {:error, :invalid_schema}
    end
  end

  defp validate_enum(schema) do
    case Map.fetch(schema, "enum") do
      :error ->
        :ok

      {:ok, values}
      when is_list(values) and values != [] and length(values) <= @max_enum_members ->
        with true <- Enum.all?(values, &JSONValue.value?/1),
             {:ok, encoded} <- encode_enum_members(values),
             true <- MapSet.size(MapSet.new(encoded)) == length(encoded) do
          :ok
        else
          _reason -> {:error, :invalid_schema}
        end

      {:ok, _values} ->
        {:error, :invalid_schema}
    end
  end

  defp encode_enum_members(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, encoded} ->
      case DeterministicJSON.encode(value) do
        {:ok, member} -> {:cont, {:ok, [member | encoded]}}
        _error -> {:halt, {:error, :invalid_schema}}
      end
    end)
  end

  defp valid_optional_number?(nil), do: true
  defp valid_optional_number?(value) when is_integer(value), do: true
  defp valid_optional_number?(value) when is_float(value), do: value == value
  defp valid_optional_number?(_value), do: false

  defp valid_optional_non_negative_integer?(nil), do: true
  defp valid_optional_non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp maybe_put(schema, _key, nil), do: schema
  defp maybe_put(schema, key, value), do: Map.put(schema, key, value)
end
