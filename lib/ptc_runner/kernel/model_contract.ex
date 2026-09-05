defmodule PtcRunner.Kernel.ModelContract do
  @moduledoc """
  Projects compiled prelude contracts and normalized capability JSON Schema
  into one deterministic, renderer-neutral model contract.

  The projection uses `PtcRunner.Kernel.DeterministicJSON` objects. A function
  contract has `parameters` (ordered `name`/`type` nodes) and `returns`; a
  constant contract has `value`. Type nodes contain `kind` and `nullable`, with
  `items` for arrays or `closed` and ordered `fields` for objects. Each field
  has an independent `required` boolean, so omission is never conflated with a
  nullable value.

  JSON Schema annotations and validity constraints retain their normalized
  names: `title`, `description`, `enum`, `const`, `minimum`, `maximum`,
  `min_length`, `max_length`, `min_items`, `max_items`, and `format`. Missing
  optional output schemas remain `nil`; the prompt renderer omits absent
  information. This structure is presentation data only. Runtime authority
  remains with the compiled prelude contract and capability JSON Schema
  validators.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.TypedCanonicalJSON
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Lisp.Signature

  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_-]*\z/
  @literal_symbols ~w(nil true false)
  @projection_domain <<"ptc.contract-prompt-projection.v1", 0>>

  @doc "Projects the complete normalized application value-contract profile."
  @spec value_contract(ValueContract.t()) ::
          {:ok, term()} | {:error, :unsupported_contract}
  def value_contract(%ValueContract{schema: schema} = contract) do
    cond do
      not ValueContract.sealed?(contract) ->
        {:error, :unsupported_contract}

      Map.has_key?(schema, "oneOf") ->
        case ValueContract.prompt_discriminator(contract) do
          {:ok, discriminator} -> json_schema_union(schema, discriminator)
          :error -> {:error, :unsupported_contract}
        end

      true ->
        json_schema(schema)
    end
  end

  def value_contract(_contract), do: {:error, :unsupported_contract}

  @doc "Returns the annotation-sensitive identity of a renderer-neutral projection."
  @spec projection_hash(term()) :: {:ok, binary()} | {:error, :unsupported_contract}
  def projection_hash(projection) do
    case encoded_projection(projection) do
      {:ok, encoded} ->
        framed = <<byte_size(encoded)::unsigned-big-64, encoded::binary>>

        {:ok,
         "sha256:" <>
           Base.encode16(:crypto.hash(:sha256, @projection_domain <> framed), case: :lower)}

      {:error, _reason} ->
        {:error, :unsupported_contract}
    end
  end

  @doc false
  @spec projection_bytes(term()) :: {:ok, non_neg_integer()} | {:error, :unsupported_contract}
  def projection_bytes(projection) do
    case encoded_projection(projection) do
      {:ok, encoded} -> {:ok, byte_size(encoded)}
      {:error, _reason} -> {:error, :unsupported_contract}
    end
  end

  @spec function(Signature.signature()) :: {:ok, term()} | {:error, :unsupported_contract}
  def function({:signature, params, return_type}) when is_list(params) do
    with {:ok, parameters} <- map_types(params, &parameter/1),
         {:ok, returns} <- type(return_type) do
      {:ok, object([{"parameters", parameters}, {"returns", returns}])}
    end
  end

  def function(_signature), do: {:error, :unsupported_contract}

  @spec value(Signature.type()) :: {:ok, term()} | {:error, :unsupported_contract}
  def value(type) do
    with {:ok, value_type} <- type(type) do
      {:ok, object([{"value", value_type}])}
    end
  end

  @doc "Builds a value contract from only the top-level kind of a JSON value."
  @spec json_value(term()) :: {:ok, term()} | {:error, :unsupported_contract}
  def json_value(value) do
    with {:ok, value_type} <- json_value_type(value) do
      {:ok, object([{"value", value_type}])}
    end
  end

  @spec capability(map(), map() | nil) ::
          {:ok, term()} | {:error, :unsupported_contract}
  def capability(input_schema, output_schema) when is_map(input_schema) do
    with {:ok, input_type} <- json_schema(input_schema),
         {:ok, output_type} <- optional_json_schema(output_schema) do
      parameter = object([{"name", "arguments"}, {"type", input_type}])
      {:ok, object([{"parameters", [parameter]}, {"returns", output_type}])}
    end
  end

  def capability(_input_schema, _output_schema), do: {:error, :unsupported_contract}

  @spec capability_call(binary(), map()) :: binary()
  def capability_call(name, %{"properties" => properties, "required" => required})
      when is_binary(name) and is_map(properties) and is_list(required) do
    fields = Enum.sort(required)

    reserved = fields |> Enum.filter(&identifier_placeholder?/1) |> MapSet.new()

    {arguments, _state} =
      Enum.map_reduce(fields, {reserved, 1}, fn field, state ->
        {placeholder, state} = allocate_placeholder(field, state)
        {"#{inline_json(field)} #{placeholder}", state}
      end)

    "(tool/#{name} {#{Enum.join(arguments, ", ")}})"
  end

  def capability_call(name, _schema) when is_binary(name), do: "(tool/#{name} {})"

  defp parameter({name, type}) when is_binary(name) do
    with {:ok, type} <- type(type) do
      {:ok, object([{"name", name}, {"type", type}])}
    end
  end

  defp parameter(_parameter), do: {:error, :unsupported_contract}

  defp type(:string), do: scalar("string")
  defp type(:int), do: scalar("integer")
  defp type(:float), do: scalar("number")
  defp type(:bool), do: scalar("boolean")
  defp type(:keyword), do: scalar("keyword")
  defp type(:any), do: {:ok, object([{"kind", "any"}, {"nullable", true}])}
  defp type(:datetime), do: scalar("datetime")
  defp type(:map), do: object_type(false, [])

  defp type({:optional, inner_type}) do
    with {:ok, {:object, pairs}} <- type(inner_type) do
      {:ok, {:object, replace_pair(pairs, "nullable", true)}}
    end
  end

  defp type({:list, element_type}) do
    with {:ok, element} <- type(element_type) do
      {:ok, object([{"kind", "array"}, {"nullable", false}, {"items", element}])}
    end
  end

  defp type({map_kind, fields}) when map_kind in [:map, :closed_map] and is_list(fields) do
    with {:ok, fields} <- map_types(fields, &signature_field/1) do
      object_type(map_kind == :closed_map, fields)
    end
  end

  defp type(_type), do: {:error, :unsupported_contract}

  defp json_value_type(nil), do: {:ok, object([{"kind", "nil"}, {"nullable", true}])}
  defp json_value_type(value) when is_boolean(value), do: scalar("boolean")
  defp json_value_type(value) when is_integer(value), do: scalar("integer")
  defp json_value_type(value) when is_float(value), do: scalar("number")
  defp json_value_type(value) when is_binary(value), do: scalar("string")

  defp json_value_type(value) when is_list(value) do
    {:ok,
     object([
       {"kind", "array"},
       {"nullable", false},
       {"items", object([{"kind", "any"}, {"nullable", true}])}
     ])}
  end

  defp json_value_type(value) when is_map(value) and not is_struct(value),
    do:
      {:ok, object([{"kind", "object"}, {"nullable", false}, {"closed", false}, {"fields", []}])}

  defp json_value_type(_value), do: {:error, :unsupported_contract}

  defp signature_field({name, {:optional, inner_type}}) when is_binary(name) do
    with {:ok, {:object, pairs}} <- type(inner_type) do
      type = {:object, replace_pair(pairs, "nullable", true)}
      {:ok, object([{"name", name}, {"required", false}, {"type", type}])}
    end
  end

  defp signature_field({name, field_type}) when is_binary(name) do
    with {:ok, type} <- type(field_type) do
      {:ok, object([{"name", name}, {"required", true}, {"type", type}])}
    end
  end

  defp signature_field(_field), do: {:error, :unsupported_contract}

  defp json_schema(schema) when is_map(schema) do
    case JSONSchema.node_type(schema) do
      {:ok, "object", nullable?} -> json_schema_object(schema, nullable?)
      {:ok, "array", nullable?} -> json_schema_array(schema, nullable?)
      {:ok, json_type, nullable?} -> json_schema_scalar(schema, json_type, nullable?)
      :error -> json_schema_composition(schema)
    end
  end

  defp json_schema(_schema), do: {:error, :unsupported_contract}

  defp json_schema_object(schema, nullable?) do
    properties = Map.get(schema, "properties", %{})
    required = MapSet.new(Map.get(schema, "required", []))

    with {:ok, fields} <-
           properties
           |> Enum.sort_by(&elem(&1, 0))
           |> map_types(fn {name, child} ->
             with {:ok, child_type} <- json_schema(child) do
               {:ok,
                object([
                  {"name", name},
                  {"required", MapSet.member?(required, name)},
                  {"type", child_type}
                ])}
             end
           end),
         {:ok, property_names} <- optional_property_names(schema) do
      {:ok,
       constrained_node(
         schema,
         [
           {"kind", "object"},
           {"nullable", nullable?},
           {"closed", Map.get(schema, "additionalProperties", false) == false},
           {"fields", fields}
         ] ++
           if(is_nil(property_names), do: [], else: [{"property_names", property_names}])
       )}
    end
  end

  defp json_schema_composition(%{"oneOf" => branches}) when is_list(branches),
    do: {:error, :unsupported_contract}

  defp json_schema_composition(_schema), do: {:error, :unsupported_contract}

  defp json_schema_array(schema, nullable?) do
    with {:ok, items} <- optional_items(schema) do
      {:ok,
       constrained_node(
         schema,
         [{"kind", "array"}, {"nullable", nullable?}, {"items", items}]
       )}
    end
  end

  defp json_schema_scalar(schema, json_type, nullable?)
       when json_type in ["null", "boolean", "number", "integer", "string"] do
    kind = if json_type == "null", do: "nil", else: json_type
    {:ok, constrained_node(schema, [{"kind", kind}, {"nullable", nullable?}])}
  end

  defp json_schema_scalar(_schema, _json_type, _nullable?),
    do: {:error, :unsupported_contract}

  defp json_schema_union(%{"oneOf" => branches} = schema, discriminator)
       when is_list(branches) and is_binary(discriminator) do
    with {:ok, variants} <- map_types(branches, &union_variant(&1, discriminator)) do
      {:ok,
       constrained_node(
         schema,
         [
           {"kind", "tagged_union"},
           {"nullable", false},
           {"variants", Enum.sort_by(variants, &union_sort_key/1)}
         ]
       )}
    end
  end

  defp optional_json_schema(nil), do: {:ok, nil}
  defp optional_json_schema(schema), do: json_schema(schema)

  defp optional_items(schema) do
    case Map.fetch(schema, "items") do
      {:ok, items} -> json_schema(items)
      :error -> type(:any)
    end
  end

  defp optional_property_names(schema) do
    case Map.fetch(schema, "propertyNames") do
      {:ok, property_names} -> json_schema(property_names)
      :error -> {:ok, nil}
    end
  end

  defp union_variant(schema, discriminator_name) do
    with {:ok, projection} <- json_schema(schema),
         {:object, pairs} <- projection,
         {:ok, discriminator} <- discriminator_literal(schema, discriminator_name) do
      {:ok, object([{"discriminator", discriminator}, {"type", {:object, pairs}}])}
    else
      _invalid -> {:error, :unsupported_contract}
    end
  end

  defp discriminator_literal(%{"properties" => properties}, name) when is_map(properties) do
    case get_in(properties, [name, "const"]) do
      literal when is_binary(literal) ->
        {:ok, object([{"name", name}, {"literal", literal}])}

      _invalid ->
        {:error, :unsupported_contract}
    end
  end

  defp discriminator_literal(_schema, _name), do: {:error, :unsupported_contract}

  defp union_sort_key({:object, pairs}) do
    {"discriminator", {:object, discriminator}} = List.keyfind(pairs, "discriminator", 0)
    {"literal", literal} = List.keyfind(discriminator, "literal", 0)
    enum_sort_key(literal)
  end

  defp constrained_node(schema, base_pairs) do
    kind = base_pairs |> Map.new() |> Map.fetch!("kind")

    pairs =
      base_pairs ++
        optional_pair(schema, "title", "title") ++
        optional_pair(schema, "description", "description") ++
        enum_pair(schema) ++
        present_pair(schema, "const", "const") ++
        applicable_constraint_pairs(schema, kind)

    object(pairs)
  end

  defp applicable_constraint_pairs(schema, kind) when kind in ["integer", "number"] do
    optional_pair(schema, "minimum", "minimum") ++
      optional_pair(schema, "maximum", "maximum")
  end

  defp applicable_constraint_pairs(schema, "string") do
    optional_pair(schema, "minLength", "min_length") ++
      optional_pair(schema, "maxLength", "max_length") ++
      optional_pair(schema, "format", "format")
  end

  defp applicable_constraint_pairs(schema, "array") do
    optional_pair(schema, "minItems", "min_items") ++
      optional_pair(schema, "maxItems", "max_items")
  end

  defp applicable_constraint_pairs(schema, "object") do
    optional_pair(schema, "maxProperties", "max_properties")
  end

  defp applicable_constraint_pairs(_schema, _kind), do: []

  defp optional_pair(schema, source, target) do
    case Map.get(schema, source) do
      nil -> []
      value -> [{target, value}]
    end
  end

  defp present_pair(schema, source, target) do
    case Map.fetch(schema, source) do
      {:ok, value} -> [{target, value}]
      :error -> []
    end
  end

  defp enum_pair(schema) do
    case Map.get(schema, "enum") do
      values when is_list(values) -> [{"enum", Enum.sort_by(values, &enum_sort_key/1)}]
      _missing -> []
    end
  end

  defp enum_sort_key(value) do
    {:ok, encoded} = DeterministicJSON.encode(value)
    encoded
  end

  defp scalar(kind), do: {:ok, object([{"kind", kind}, {"nullable", false}])}

  defp object_type(closed, fields) do
    {:ok,
     object([
       {"kind", "object"},
       {"nullable", false},
       {"closed", closed},
       {"fields", fields}
     ])}
  end

  defp map_types(values, mapper) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  defp allocate_placeholder(field, state) when is_binary(field) do
    if identifier_placeholder?(field), do: {field, state}, else: allocate_generated(state)
  end

  defp allocate_placeholder(_field, state), do: allocate_generated(state)

  defp allocate_generated({reserved, index}) do
    candidate = "value#{index}"

    if MapSet.member?(reserved, candidate) do
      allocate_generated({reserved, index + 1})
    else
      {candidate, {MapSet.put(reserved, candidate), index + 1}}
    end
  end

  defp identifier_placeholder?(field) when is_binary(field),
    do: Regex.match?(@identifier, field) and field not in @literal_symbols

  defp identifier_placeholder?(_field), do: false

  defp inline_json(value) do
    value
    |> Jason.encode!()
    |> String.replace("\u2028", "\\u2028")
    |> String.replace("\u2029", "\\u2029")
  end

  defp replace_pair(pairs, key, value) do
    Enum.map(pairs, fn
      {^key, _old} -> {key, value}
      pair -> pair
    end)
  end

  defp object(pairs), do: {:object, pairs}

  defp encoded_projection(projection) do
    with {:ok, json} <- DeterministicJSON.encode(projection),
         {:ok, value} <- Jason.decode(json),
         do: TypedCanonicalJSON.encode(value)
  end
end
