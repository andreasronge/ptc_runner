defmodule PtcRunner.Kernel.JSONSchema do
  @moduledoc """
  Internal compiler for the bounded capability JSON Schema profile.

  The accepted profile is a strict subset of JSON Schema 2020-12 containing
  `type`, `title`, `description`, `default`, `properties`, `required`,
  `additionalProperties`, `propertyNames`, `items`, `enum`, `const`, `minimum`,
  `maximum`, `minLength`, `maxLength`, `minItems`, `maxItems`, `maxProperties`,
  and the single bounded `sha256` string format. Types are scalar rather than
  unions, roots are objects, and a missing `additionalProperties` on an object
  is normalized to `false`.

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
  enter that explanation. Validation and explanation projection run together
  in one time- and heap-bounded worker. Proven schema invalidity is distinct
  from validator timeout, heap exhaustion, crashes, and malformed validator
  results.

  Rejection reports the first proven fault as a closed `rule` atom plus the
  segments locating it inside the submitted schema document. Every segment is
  a key or index the submitted document actually carries, so the location
  always resolves in the file the author opens. The profile is deliberately
  closed, and its edges are not guessable from a bare refusal: an unsupported
  keyword, a misspelled type, and an unsatisfiable bound are three different
  authoring mistakes and must not report identically.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONSchema.SHA256Format
  alias PtcRunner.Kernel.JSONValue

  @allowed ~w(type title description properties required additionalProperties propertyNames items enum const minimum maximum minLength maxLength minItems maxItems maxProperties format)
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
  @simple_argument_segment ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @expected_constraints ~w(minimum maximum minLength maxLength minItems maxItems maxProperties)

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
    maxProperties: "maxProperties",
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
  @type segment :: {:property, binary()} | {:index, non_neg_integer()}
  @type rejection :: %{rule: atom(), segments: [segment()]}

  @dialects [
    "https://json-schema.org/draft/2020-12/schema",
    "http://json-schema.org/draft-07/schema#"
  ]

  @spec compile(map()) :: {:ok, map(), compiled()} | {:error, {:invalid_schema, rejection()}}
  def compile(schema) when is_map(schema) and not is_struct(schema) do
    with {:ok, schema} <- validate_dialect(schema),
         {:ok, normalized} <- normalize(schema, [], 1),
         :ok <- validate_root_object(normalized),
         {:ok, encoded} <- encode_normalized(normalized),
         :ok <- validate_schema_size(encoded),
         {:ok, root} <- build(normalized) do
      {:ok, normalized, root}
    else
      {:error, %{rule: _rule} = rejection} -> {:error, {:invalid_schema, rejection}}
    end
  rescue
    _exception -> {:error, {:invalid_schema, rejection(:unsupported_schema, [])}}
  end

  def compile(_schema), do: {:error, {:invalid_schema, rejection(:not_a_schema_object, [])}}

  @doc """
  Returns every rule a rejection can carry, most specific first.

  The set is closed so a diagnostic boundary can render each rule from a fixed
  literal instead of forwarding compiler prose.
  """
  @spec rules() :: [atom()]
  def rules do
    [
      :not_a_schema_object,
      :unsupported_keyword,
      :type_missing,
      :unsupported_type,
      :unsupported_format,
      :keyword_not_applicable,
      :invalid_keyword_value,
      :bounds_inverted,
      :required_property_undeclared,
      :root_not_object,
      :unsupported_dialect,
      :depth_exceeded,
      :too_many_properties,
      :too_many_enum_members,
      :schema_too_large,
      :unsupported_schema
    ]
  end

  defp validate_root_object(%{"type" => "object"}), do: :ok
  defp validate_root_object(_normalized), do: {:error, rejection(:root_not_object, [])}

  defp encode_normalized(normalized) do
    case DeterministicJSON.encode(normalized) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, rejection(:unsupported_schema, [])}
    end
  end

  defp validate_schema_size(encoded) do
    if byte_size(encoded) <= @max_schema_bytes,
      do: :ok,
      else: {:error, rejection(:schema_too_large, [])}
  end

  defp build(normalized) do
    case JSV.build(normalized, atoms: false, formats: [SHA256Format], warnings: :silent) do
      {:ok, root} -> {:ok, root}
      _invalid -> {:error, rejection(:unsupported_schema, [])}
    end
  end

  @spec valid?(compiled(), term()) :: boolean()
  def valid?(root, value) do
    match?({:ok, _validated}, JSV.validate(value, root, cast: false))
  rescue
    _exception -> false
  end

  @doc "Validates a value and returns only bounded, schema-authored rejection facts."
  @spec validate(compiled(), map(), term(), pos_integer(), pos_integer()) ::
          :ok | {:invalid, [violation()]} | {:unavailable, atom()}
  def validate(root, schema, value, timeout_ms, max_heap_words)
      when is_map(schema) and not is_struct(schema) and is_integer(timeout_ms) and
             timeout_ms > 0 and is_integer(max_heap_words) and max_heap_words > 0 do
    explain? = match?({:ok, _remaining}, explanation_value_budget(value, @max_explanation_nodes))

    case BoundedWorker.run(fn -> validate_value(root, schema, value, explain?) end,
           timeout_ms: timeout_ms,
           max_heap_words: max_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, :ok} -> :ok
      {:ok, {:invalid, violations}} when is_list(violations) -> {:invalid, violations}
      {:ok, {:unavailable, cause}} when is_atom(cause) -> {:unavailable, cause}
      {:ok, _unexpected} -> {:unavailable, :unexpected_validator_result}
      {:error, cause} -> {:unavailable, cause}
    end
  end

  defp validate_value(root, schema, value, explain?) do
    if JSONValue.value?(value) do
      case JSV.validate(value, root, cast: false) do
        {:ok, _validated} ->
          :ok

        {:error, %JSV.ValidationError{errors: errors}} ->
          violations = if explain?, do: project_violations(errors, schema), else: []
          {:invalid, violations}
      end
    else
      {:invalid, []}
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
  # Otherwise canonicalize the bounded candidate set before selecting three,
  # so upstream validator ordering cannot change the retained subset.
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
    |> Enum.map(&project_violation(&1, schema))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.argument, &1.constraint})
    |> Enum.take(@max_violations)
  end

  defp project_violation(error, schema) do
    with kind when is_atom(kind) <- Map.get(error, :kind),
         {:ok, constraint} <- Map.fetch(@constraint_keys, kind),
         schema_path when is_list(schema_path) <- Map.get(error, :schema_path),
         {:ok, node, path} <- schema_context(schema, schema_path, constraint),
         {:ok, argument} <- render_argument(path),
         {:ok, declared} <- Map.fetch(node, constraint) do
      violation = %{argument: argument, constraint: constraint}

      case project_expected(constraint, declared) do
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
  defp schema_context(schema, schema_path, constraint),
    do: schema_path |> Enum.reverse() |> walk_schema_context(schema, [], constraint)

  defp walk_schema_context([], node, path, _constraint), do: {:ok, node, Enum.reverse(path)}

  defp walk_schema_context([:root | rest], node, path, constraint),
    do: walk_schema_context(rest, node, path, constraint)

  defp walk_schema_context(
         [{:properties, name} | rest],
         %{"properties" => properties},
         path,
         constraint
       )
       when is_map(properties) do
    case Map.fetch(properties, name) do
      {:ok, child} -> walk_schema_context(rest, child, [name | path], constraint)
      :error -> :error
    end
  end

  defp walk_schema_context([:items | rest], %{"items" => child}, path, constraint),
    do: walk_schema_context(rest, child, [:item | path], constraint)

  # JSV may prefix an object node's schema path with `:propertyNames` even for
  # a sibling keyword such as `maxProperties`. Stay on the object when it
  # declares the violated constraint; otherwise descend into the nested names
  # schema. Never retain a caller-authored property name on the argument path.
  defp walk_schema_context([:propertyNames | rest], node, path, constraint)
       when is_map(node) and is_binary(constraint) do
    cond do
      Map.has_key?(node, constraint) ->
        walk_schema_context(rest, node, path, constraint)

      is_map(node["propertyNames"]) ->
        walk_schema_context(rest, node["propertyNames"], path, constraint)

      true ->
        :error
    end
  end

  defp walk_schema_context(_segments, _node, _path, _constraint), do: :error

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

  defp project_expected(constraint, value) when constraint in @expected_constraints do
    with true <- is_number(value),
         {:ok, encoded} <- DeterministicJSON.encode(value),
         true <- byte_size(encoded) <= @max_expected_bytes do
      {:ok, value}
    else
      _too_large_or_structured -> :omit
    end
  end

  defp project_expected(_constraint, _value), do: :omit

  @doc false
  @spec declared_expected(atom(), map()) :: {:ok, number()} | :omit
  def declared_expected(kind, schema) when is_atom(kind) and is_map(schema) do
    with {:ok, constraint} <- Map.fetch(@constraint_keys, kind),
         {:ok, declared} <- Map.fetch(schema, constraint) do
      project_expected(constraint, declared)
    else
      _unsupported_or_absent -> :omit
    end
  end

  def declared_expected(_kind, _schema), do: :omit

  defp normalize(_schema, path, depth) when depth > @max_depth,
    do: reject(:depth_exceeded, path)

  defp normalize(schema, path, depth) when is_map(schema) and not is_struct(schema) do
    if JSONValue.map?(schema),
      do: schema |> drop_ignored_annotations() |> normalize_node(path, depth),
      else: reject(:not_a_schema_object, path)
  end

  defp normalize(_schema, path, _depth), do: reject(:not_a_schema_object, path)

  # Local checks locate themselves relative to this node and are lifted onto
  # `path` here; recursive child normalization already carries the full path
  # and reports absolute segments.
  defp normalize_node(schema, path, depth) do
    type = schema["type"]

    with :ok <- validate_keywords(schema),
         :ok <- validate_type(schema),
         :ok <- validate_text(schema, "title"),
         :ok <- validate_text(schema, "description"),
         :ok <- validate_number_bounds(schema),
         :ok <- validate_size_bounds(schema, "minLength", "maxLength"),
         :ok <- validate_size_bounds(schema, "minItems", "maxItems"),
         :ok <- validate_format(schema, type),
         :ok <- validate_const(schema),
         :ok <- validate_enum(schema),
         {:ok, properties} <- normalize_properties(schema, type, path, depth),
         {:ok, items} <- normalize_items(schema, type, path, depth),
         {:ok, property_names} <- normalize_property_names(schema, type, path, depth),
         :ok <- validate_required(schema, type, properties),
         :ok <- validate_additional_properties(schema, type),
         :ok <- validate_max_properties(schema, type) do
      normalized =
        schema
        |> maybe_put("properties", properties)
        |> maybe_put("items", items)
        |> maybe_put("propertyNames", property_names)
        |> normalize_additional_properties(type)

      {:ok, normalized}
    else
      {:error, {rule, suffix}} when is_atom(rule) -> reject(rule, path, suffix)
      {:error, %{rule: _rule}} = absolute -> absolute
    end
  end

  # A root "$schema" selects the dialect: absence defaults to 2020-12, a
  # supported URI is removed after validation, anything else is rejected.
  # Nested "$schema" is rejected in normalize/3 like any unknown keyword.
  defp validate_dialect(schema) do
    case Map.fetch(schema, "$schema") do
      :error ->
        {:ok, schema}

      {:ok, dialect} when dialect in @dialects ->
        {:ok, Map.delete(schema, "$schema")}

      {:ok, _dialect} ->
        {:error, rejection(:unsupported_dialect, [{:property, "$schema"}])}
    end
  end

  defp validate_keywords(schema) do
    case schema |> Map.keys() |> Enum.reject(&(&1 in @allowed)) |> Enum.sort() do
      [] -> :ok
      [keyword | _rest] -> {:error, {:unsupported_keyword, keyword_segments(keyword)}}
    end
  end

  # A profile node is typed: `enum` and `const` alone do not imply one here,
  # even though bare `enum` is the idiomatic JSON Schema spelling. Reporting
  # that as a missing `type` rather than as a generic refusal is the whole
  # difference between a one-line fix and bisecting the schema by hand.
  defp validate_type(schema) do
    case Map.fetch(schema, "type") do
      {:ok, type} when type in @types -> :ok
      {:ok, _type} -> {:error, {:unsupported_type, [{:property, "type"}]}}
      :error -> {:error, {:type_missing, []}}
    end
  end

  defp keyword_segments(keyword) when is_binary(keyword), do: [{:property, keyword}]
  defp keyword_segments(_keyword), do: []

  defp rejection(rule, segments), do: %{rule: rule, segments: segments}

  defp reject(rule, path, suffix \\ []),
    do: {:error, rejection(rule, Enum.reverse(path, suffix))}

  # Vendor "x-…" extension keys and JSON Schema's non-validating "default"
  # annotation are discarded as deliberate client policy; mainstream MCP SDKs
  # emit them by default and this profile assigns them no runtime semantics.
  # Unsupported semantic keywords remain rejected.
  defp drop_ignored_annotations(schema) do
    Map.reject(schema, fn {key, _value} ->
      key == "default" or String.starts_with?(key, "x-")
    end)
  end

  defp normalize_properties(schema, "object", path, depth) do
    case Map.fetch(schema, "properties") do
      :error ->
        {:ok, nil}

      {:ok, properties} when is_map(properties) and not is_struct(properties) ->
        if map_size(properties) <= @max_properties,
          do: normalize_schema_map(properties, path, depth + 1),
          else: {:error, {:too_many_properties, [{:property, "properties"}]}}

      {:ok, _properties} ->
        {:error, {:invalid_keyword_value, [{:property, "properties"}]}}
    end
  end

  defp normalize_properties(schema, _type, _path, _depth),
    do: not_applicable(schema, "properties")

  defp normalize_schema_map(properties, path, depth) do
    properties
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn
      {name, child}, {:ok, normalized} when is_binary(name) ->
        case normalize(child, [{:property, name}, {:property, "properties"} | path], depth) do
          {:ok, normalized_child} ->
            {:cont, {:ok, Map.put(normalized, name, normalized_child)}}

          error ->
            {:halt, error}
        end

      _property, _acc ->
        {:halt, {:error, {:invalid_keyword_value, [{:property, "properties"}]}}}
    end)
  end

  defp normalize_items(schema, "array", path, depth) do
    case Map.fetch(schema, "items") do
      {:ok, items} -> normalize(items, [{:property, "items"} | path], depth + 1)
      :error -> {:ok, nil}
    end
  end

  defp normalize_items(schema, _type, _path, _depth), do: not_applicable(schema, "items")

  defp normalize_property_names(schema, "object", path, depth) do
    case Map.fetch(schema, "propertyNames") do
      {:ok, names} ->
        normalize(names, [{:property, "propertyNames"} | path], depth + 1)

      :error ->
        {:ok, nil}
    end
  end

  defp normalize_property_names(schema, _type, _path, _depth),
    do: not_applicable(schema, "propertyNames")

  defp validate_max_properties(schema, "object") do
    case Map.fetch(schema, "maxProperties") do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value >= 0 ->
        :ok

      {:ok, _value} ->
        {:error, {:invalid_keyword_value, [{:property, "maxProperties"}]}}
    end
  end

  defp validate_max_properties(schema, _type) do
    case not_applicable(schema, "maxProperties") do
      {:ok, nil} -> :ok
      error -> error
    end
  end

  defp not_applicable(schema, keyword) do
    if Map.has_key?(schema, keyword),
      do: {:error, {:keyword_not_applicable, [{:property, keyword}]}},
      else: {:ok, nil}
  end

  defp validate_required(schema, "object", properties) do
    case Map.get(schema, "required", []) do
      required when is_list(required) and length(required) <= @max_properties ->
        validate_required_names(required, properties)

      _required ->
        {:error, {:invalid_keyword_value, [{:property, "required"}]}}
    end
  end

  defp validate_required(schema, _type, _properties) do
    case not_applicable(schema, "required") do
      {:ok, nil} -> :ok
      error -> error
    end
  end

  defp validate_required_names(required, properties) do
    unique = MapSet.new(required)

    cond do
      not Enum.all?(required, &is_binary/1) or MapSet.size(unique) != length(required) ->
        {:error, {:invalid_keyword_value, [{:property, "required"}]}}

      not Enum.all?(required, &Map.has_key?(properties || %{}, &1)) ->
        {:error, {:required_property_undeclared, [{:property, "required"}]}}

      true ->
        :ok
    end
  end

  defp validate_additional_properties(schema, "object") do
    case Map.get(schema, "additionalProperties", false) do
      value when is_boolean(value) -> :ok
      _value -> {:error, {:invalid_keyword_value, [{:property, "additionalProperties"}]}}
    end
  end

  defp validate_additional_properties(schema, _type) do
    case not_applicable(schema, "additionalProperties") do
      {:ok, nil} -> :ok
      error -> error
    end
  end

  defp normalize_additional_properties(schema, "object"),
    do: Map.put_new(schema, "additionalProperties", false)

  defp normalize_additional_properties(schema, _type), do: schema

  defp validate_text(schema, key) do
    case Map.fetch(schema, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      {:ok, _value} -> {:error, {:invalid_keyword_value, [{:property, key}]}}
    end
  end

  defp validate_number_bounds(schema),
    do: validate_bounds(schema, "minimum", "maximum", &valid_optional_number?/1)

  defp validate_format(schema, "string") do
    case Map.fetch(schema, "format") do
      :error -> :ok
      {:ok, "sha256"} -> :ok
      {:ok, _format} -> {:error, {:unsupported_format, [{:property, "format"}]}}
    end
  end

  defp validate_format(schema, _type) do
    case not_applicable(schema, "format") do
      {:ok, nil} -> :ok
      error -> error
    end
  end

  defp validate_size_bounds(schema, minimum_key, maximum_key),
    do:
      validate_bounds(
        schema,
        minimum_key,
        maximum_key,
        &valid_optional_non_negative_integer?/1
      )

  defp validate_bounds(schema, minimum_key, maximum_key, valid?) do
    minimum = Map.get(schema, minimum_key)
    maximum = Map.get(schema, maximum_key)

    cond do
      not valid?.(minimum) ->
        {:error, {:invalid_keyword_value, [{:property, minimum_key}]}}

      not valid?.(maximum) ->
        {:error, {:invalid_keyword_value, [{:property, maximum_key}]}}

      is_number(minimum) and is_number(maximum) and minimum > maximum ->
        {:error, {:bounds_inverted, [{:property, minimum_key}]}}

      true ->
        :ok
    end
  end

  defp validate_const(schema) do
    case Map.fetch(schema, "const") do
      :error ->
        :ok

      {:ok, value} ->
        if JSONValue.value?(value),
          do: :ok,
          else: {:error, {:invalid_keyword_value, [{:property, "const"}]}}
    end
  end

  defp validate_enum(schema) do
    case Map.fetch(schema, "enum") do
      :error ->
        :ok

      {:ok, values} when is_list(values) and length(values) > @max_enum_members ->
        {:error, {:too_many_enum_members, [{:property, "enum"}]}}

      {:ok, values} when is_list(values) and values != [] ->
        validate_enum_members(values)

      {:ok, _values} ->
        {:error, {:invalid_keyword_value, [{:property, "enum"}]}}
    end
  end

  defp validate_enum_members(values) do
    with true <- Enum.all?(values, &JSONValue.value?/1),
         {:ok, encoded} <- encode_enum_members(values),
         true <- MapSet.size(MapSet.new(encoded)) == length(encoded) do
      :ok
    else
      _reason -> {:error, {:invalid_keyword_value, [{:property, "enum"}]}}
    end
  end

  defp encode_enum_members(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, encoded} ->
      case DeterministicJSON.encode(value) do
        {:ok, member} -> {:cont, {:ok, [member | encoded]}}
        _error -> {:halt, :error}
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
