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
  JSV. Runtime validation delegates to the compiled JSV root. Input rejection
  may retain a small explanation containing only schema-declared paths,
  keywords, and bounds; submitted values and undeclared property names never
  enter that explanation.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONSchema.SHA256Format
  alias PtcRunner.Kernel.JSONValue

  @allowed ~w(type title description properties required additionalProperties items enum const minimum maximum minLength maxLength minItems maxItems format)
  @types ~w(null boolean object array number integer string)
  @max_schema_bytes 65_536
  @max_depth 16
  @max_properties 128
  @max_enum_members 256
  @max_violations 3
  @max_explanation_nodes 64
  @max_explanation_errors 64
  @max_argument_bytes 512
  @max_expected_bytes 256
  @max_expected_members 8
  @simple_argument_segment ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @constraint_keys %{
    type: "type",
    enum: "enum",
    const: "const",
    minimum: "minimum",
    maximum: "maximum",
    minLength: "minLength",
    maxLength: "maxLength",
    minItems: "minItems",
    maxItems: "maxItems",
    format: "format",
    required: "required",
    additionalProperties: "additionalProperties"
  }

  @type compiled :: JSV.Root.t()
  @type violation :: %{
          required(:argument) => binary(),
          required(:constraint) => binary(),
          optional(:expected) => term()
        }

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

  @doc "Validates a value and returns only bounded, schema-authored rejection facts."
  @spec validate(compiled(), map(), term(), pos_integer(), pos_integer()) ::
          :ok | {:error, [violation()]}
  def validate(root, schema, value, timeout_ms, max_heap_words)
      when is_map(schema) and not is_struct(schema) and is_integer(timeout_ms) and
             timeout_ms > 0 and is_integer(max_heap_words) and max_heap_words > 0 do
    if match?({:ok, _remaining}, explanation_value_budget(value, @max_explanation_nodes)) do
      validate_with_details(root, schema, value)
    else
      validate_without_details(root, value, timeout_ms, max_heap_words)
    end
  end

  defp validate_with_details(root, schema, value) do
    case JSV.validate(value, root, cast: false) do
      {:ok, _validated} ->
        :ok

      {:error, %JSV.ValidationError{errors: errors}} ->
        {:error, project_violations(errors, schema)}
    end
  rescue
    _exception -> {:error, []}
  end

  # A large submitted value can make JSV's raw error term exceed the evaluator
  # heap ceiling by itself. Validate such values in a separately bounded worker
  # with enough headroom for the admitted capability-argument ceiling, and
  # discard every diagnostic. Resource exhaustion fails closed as invalid.
  defp validate_without_details(root, value, timeout_ms, max_heap_words) do
    case BoundedWorker.run(fn -> valid?(root, value) end,
           timeout_ms: timeout_ms,
           max_heap_words: max_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, true} -> :ok
      _invalid_or_exhausted -> {:error, []}
    end
  end

  defp explanation_value_budget(_value, remaining) when remaining < 1, do: :over

  defp explanation_value_budget(value, remaining)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: {:ok, remaining - 1}

  defp explanation_value_budget(value, remaining) when is_list(value),
    do: explanation_list_budget(value, remaining - 1)

  defp explanation_value_budget(value, remaining) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, remaining - 1}, fn {_key, child}, {:ok, budget} ->
      case explanation_value_budget(child, budget) do
        {:ok, next_budget} -> {:cont, {:ok, next_budget}}
        :over -> {:halt, :over}
      end
    end)
  end

  defp explanation_value_budget(_value, _remaining), do: :over

  defp explanation_list_budget([], remaining), do: {:ok, remaining}
  defp explanation_list_budget(_values, remaining) when remaining < 1, do: :over

  defp explanation_list_budget([value | rest], remaining) do
    case explanation_value_budget(value, remaining) do
      {:ok, next_remaining} -> explanation_list_budget(rest, next_remaining)
      :over -> :over
    end
  end

  defp explanation_list_budget(_improper_tail, _remaining), do: :over

  # JSV has already accumulated its raw errors. Do not normalize that whole
  # list: one invalid array element creates one formatted message, and a valid-
  # size argument can contain thousands of them. Refuse explanation work before
  # projecting any candidate when the raw cardinality exceeds the fixed budget.
  # Otherwise select at most three safe schema facts with constant extra space.
  defp project_violations(errors, schema) when is_list(errors) do
    if explanation_error_budget?(errors, @max_explanation_errors) do
      select_violations(errors, schema)
    else
      []
    end
  end

  defp explanation_error_budget?([], _remaining), do: true
  defp explanation_error_budget?([_error | _rest], 0), do: false

  defp explanation_error_budget?([_error | rest], remaining),
    do: explanation_error_budget?(rest, remaining - 1)

  defp select_violations(errors, schema) do
    errors
    |> Enum.reduce_while([], fn error, violations ->
      case project_violation(error, schema) do
        nil ->
          {:cont, violations}

        violation ->
          retained = if violation in violations, do: violations, else: [violation | violations]

          if length(retained) == @max_violations,
            do: {:halt, retained},
            else: {:cont, retained}
      end
    end)
    |> Enum.sort_by(&{&1.argument, &1.constraint})
  end

  defp project_violation(error, schema) do
    with kind when is_atom(kind) <- Map.get(error, :kind),
         {:ok, constraint} <- Map.fetch(@constraint_keys, kind),
         schema_path when is_list(schema_path) <- Map.get(error, :schema_path),
         {:ok, node, path} <- schema_context(schema, schema_path),
         {:ok, argument} <- render_argument(path),
         {:ok, declared} <- Map.fetch(node, constraint) do
      violation = %{argument: argument, constraint: constraint}

      case project_expected(declared) do
        {:ok, expected} -> Map.put(violation, :expected, expected)
        :omit -> violation
      end
    else
      _unsupported_or_unresolved -> nil
    end
  end

  # JSV's raw schema path contains only schema-owned tokens and does not carry
  # the rejected value. Resolve every property and item step against the frozen
  # schema before retaining it. Array positions become `[]`, because a
  # submitted index is not a declared schema fact.
  defp schema_context(schema, schema_path),
    do: schema_path |> Enum.reverse() |> walk_schema_context(schema, [])

  defp walk_schema_context([], node, path), do: {:ok, node, Enum.reverse(path)}

  defp walk_schema_context([:root | rest], node, path),
    do: walk_schema_context(rest, node, path)

  defp walk_schema_context([{:properties, name} | rest], %{"properties" => properties}, path)
       when is_map(properties) do
    case Map.fetch(properties, name) do
      {:ok, child} -> walk_schema_context(rest, child, [name | path])
      :error -> :error
    end
  end

  defp walk_schema_context([:items | rest], %{"items" => child}, path),
    do: walk_schema_context(rest, child, [:item | path])

  defp walk_schema_context(_segments, _node, _path), do: :error

  defp render_argument([]), do: {:ok, "$"}

  defp render_argument(path) do
    with {:ok, argument} <-
           Enum.reduce_while(path, {:ok, ""}, fn
             :item, {:ok, rendered} ->
               {:cont, {:ok, rendered <> "[]"}}

             name, {:ok, rendered} ->
               case append_property(rendered, name) do
                 {:ok, next} -> {:cont, {:ok, next}}
                 :error -> {:halt, :error}
               end
           end),
         true <- byte_size(argument) <= @max_argument_bytes do
      {:ok, argument}
    else
      _invalid_or_too_large -> :error
    end
  end

  defp append_property(rendered, name) when is_binary(name) do
    if Regex.match?(@simple_argument_segment, name) do
      separator = if rendered == "", do: "", else: "."
      {:ok, rendered <> separator <> name}
    else
      case DeterministicJSON.encode(name) do
        {:ok, encoded} -> {:ok, rendered <> "[" <> encoded <> "]"}
        {:error, _reason} -> :error
      end
    end
  end

  defp project_expected(value) do
    bounded_shape? =
      scalar?(value) or
        (is_list(value) and length(value) <= @max_expected_members and
           Enum.all?(value, &scalar?/1))

    with true <- bounded_shape?,
         {:ok, encoded} <- DeterministicJSON.encode(value),
         true <- byte_size(encoded) <= @max_expected_bytes do
      {:ok, value}
    else
      _too_large_or_structured -> :omit
    end
  end

  defp scalar?(value),
    do: is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value)

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
