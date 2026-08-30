defmodule PtcRunner.Kernel.ValueContract do
  @moduledoc """
  Compiled manifest-local contract for application input and `Result.value`.

  Ordinary contracts use the same bounded object profile as Kernel capability
  schemas. Application contracts additionally permit one root-only tagged
  union: two to sixteen closed object branches in `oneOf`, all sharing exactly
  one required string discriminator whose `const` value is distinct in every
  branch.

  The shared bounded schema profile additionally recognizes only the asserted
  `sha256` string format. References, regexes, arbitrary formats, nested
  composition, union types, and arbitrary `oneOf` remain unsupported. The
  normalized contract is limited to 64 KiB and compiled once with JSV.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.JSONSchema.SHA256Format
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.TypedCanonicalJSON
  alias PtcRunner.Kernel.ValueContractClassification

  @dialects [
    "https://json-schema.org/draft/2020-12/schema",
    "http://json-schema.org/draft-07/schema#"
  ]
  @root_keys ~w($schema title description oneOf)
  @max_branches 16
  @max_contract_bytes 65_536
  @max_discriminator_bytes 128
  @max_violations 8
  @max_diagnostic_names 32
  @max_diagnostic_name_bytes 4_096

  @enforce_keys [:schema, :validator, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type t :: %__MODULE__{
          schema: map(),
          validator: JSV.Root.t(),
          attestation: binary()
        }

  @type rejection :: JSONSchema.rejection()

  @spec compile(map()) :: {:ok, t()} | {:error, {:invalid_value_contract, rejection()}}
  def compile(schema) when is_map(schema) and not is_struct(schema) do
    case Map.has_key?(schema, "oneOf") do
      true -> compile_tagged_union(schema)
      false -> compile_object(schema)
    end
  rescue
    _exception -> invalid(:unsupported_schema, [])
  end

  def compile(_schema), do: invalid(:not_a_schema_object, [])

  @doc """
  Returns the rules a tagged-union rejection can carry beyond the object profile.
  """
  @spec union_rules() :: [atom()]
  def union_rules do
    [
      :union_branch_count,
      :union_branch_not_closed_object,
      :union_discriminator_missing
    ]
  end

  defp invalid(rule, segments),
    do: {:error, {:invalid_value_contract, %{rule: rule, segments: segments}}}

  @spec sealed?(term()) :: boolean()
  @doc "Checks that a contract is the unchanged result of bounded compilation."
  def sealed?(%__MODULE__{attestation: attestation} = contract) do
    Enum.sort(Map.keys(contract)) == @field_keys and
      Attestation.valid?(__MODULE__, payload(contract), attestation)
  end

  def sealed?(_contract), do: false

  @spec valid?(t(), term()) :: boolean()
  def valid?(%__MODULE__{validator: validator} = contract, value) do
    sealed?(contract) and JSONValue.value?(value) and JSONSchema.valid?(validator, value)
  end

  def valid?(_contract, _value), do: false

  @spec behavior_hash(t()) :: binary()
  @doc """
  Returns the stable behavior identity of the compiled contract.

  `$schema`, `default`, and vendor annotations are removed by compilation.
  This projection additionally removes `title` and `description` only while
  traversing accepted schema positions; property names with those spellings
  remain literal application keys.
  """
  def behavior_hash(%__MODULE__{schema: schema} = contract) do
    if not sealed?(contract), do: raise(ArgumentError, "invalid value contract")

    projection = behavior_schema(schema)
    {:ok, encoded} = TypedCanonicalJSON.encode(projection)
    TypedCanonicalJSON.sha256(<<"ptc.contract-behavior.v1", 0>>, encoded)
  end

  @doc false
  @spec json_value(term()) :: {:ok, term()} | {:error, :duplicate_key | :invalid_json}
  def json_value(value) do
    with {:ok, encoded} <- DeterministicJSON.encode(value),
         {:ok, decoded} <- Jason.decode(encoded) do
      {:ok, decoded}
    else
      {:error, :duplicate_key} = error -> error
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  @spec classify(t(), term()) :: map()
  @doc """
  Explains a contract rejection without disclosing the rejected value.

  Every reported name comes from the compiled schema rather than from the
  value: the discriminator's name, the branch whose `const` the value carries,
  and bounded, sorted allowed and missing key lists at retained object paths.
  The only facts derived from the value itself are its JSON kind, required-key
  absence, and per-object counts of keys the schema does not declare — types,
  booleans, and numbers, never caller-authored content.

  A rejected result is deliberately withheld from the public error, so without
  this an operator cannot tell a missing key from a wrong shape without
  re-running under private inspection.

  `violations` locates faults, it does not enumerate them: when several array
  elements fail the same way, the reported set may name fewer of them than
  actually failed. It is a diagnosis, not a validation report. At most eight
  violations are retained. One violation at each retained object path carries
  applicable local facts. Closed paths add `allowed_keys` and any undeclared
  count; actual objects add any missing required keys. Open paths never label
  valid extension keys undeclared. Schema-name lists keep at most 32 names and
  4,096 encoded bytes; truncated lists carry their total count and an explicit
  truncation flag.
  """
  def classify(%__MODULE__{} = contract, value) do
    if not sealed?(contract), do: raise(ArgumentError, "invalid value contract")

    {classification, _evidence} = classify_with_evidence(contract, value)
    classification
  rescue
    _exception -> %{value_kind: :unknown}
  end

  def classify(_contract, _value), do: %{value_kind: :unknown}

  @doc false
  @spec model_feedback(t(), term()) :: map()
  def model_feedback(%__MODULE__{} = contract, value) do
    contract
    |> classify(value)
    |> Map.take([:value_kind, :json_value, :discriminator, :violations])
    |> Map.update(:violations, [], fn violations ->
      Enum.map(violations, &model_feedback_violation/1)
    end)
  end

  def model_feedback(_contract, _value), do: %{value_kind: :unknown, violations: []}

  @spec classify_with_evidence(t(), term()) ::
          {map(), ValueContractClassification.t() | nil}
  @doc false
  def classify_with_evidence(
        %__MODULE__{schema: schema, validator: validator} = contract,
        value
      ) do
    if not sealed?(contract), do: raise(ArgumentError, "invalid value contract")

    shape =
      case Map.fetch(schema, "oneOf") do
        {:ok, branches} -> classify_union(branches, value)
        :error -> %{}
      end

    branch_index = Map.get(shape, :branch_index)
    path_schema = selected_path_schema(schema, branch_index)

    classification =
      shape
      |> Map.delete(:branch_index)
      |> Map.put(:value_kind, value_kind(value))
      # A value can fail before any schema keyword runs: `valid?/2` also requires
      # a JSON-like value, and a PTC-Lisp map with keyword keys is not one. That
      # rejection produces no violations at all, so without this flag the
      # commonest authoring mistake reports as an empty explanation.
      |> Map.put(:json_value, JSONValue.value?(value))
      |> Map.put(
        :violations,
        validator
        |> violations(value, schema, branch_index)
        |> enrich_violations(path_schema, value)
      )

    {classification, classification_evidence(contract, branch_index)}
  rescue
    _exception -> {%{value_kind: :unknown}, nil}
  end

  def classify_with_evidence(_contract, _value), do: {%{value_kind: :unknown}, nil}

  @spec describe(t()) :: binary()
  @doc """
  Renders the contract's shape as compact text for a model-facing prompt.

  A task prompt that paraphrases its own result schema drifts from it, and the
  drift only surfaces as a rejected result after a live run has been paid for.
  Generating the shape from the compiled contract keeps the schema the single
  authority and turns drift into a test failure instead.

  Types only — no descriptions, no prose, no guidance about when each branch
  applies. That judgement belongs to the task, which the schema cannot express.
  """
  def describe(%__MODULE__{schema: schema} = contract) do
    if not sealed?(contract), do: raise(ArgumentError, "invalid value contract")

    case Map.fetch(schema, "oneOf") do
      {:ok, branches} -> Enum.map_join(branches, "\n", &describe_object/1)
      :error -> describe_object(schema)
    end
  end

  defp describe_object(schema) do
    required = Map.get(schema, "required", [])

    fields =
      schema
      |> Map.get("properties", %{})
      |> Enum.sort_by(fn {name, _} -> {name not in required, name} end)
      |> Enum.map_join(", ", fn {name, node} ->
        optional = if name in required, do: "", else: "?"
        ~s("#{name}"#{optional} #{describe_type(node)})
      end)

    "{" <> fields <> "}"
  end

  defp describe_type(%{"const" => value}), do: inspect(value)

  defp describe_type(%{"type" => "array"} = node),
    do: "[" <> describe_type(Map.get(node, "items", %{})) <> "]"

  defp describe_type(%{"type" => "object"} = node), do: describe_object(node)
  defp describe_type(%{"type" => type}) when is_binary(type), do: type
  defp describe_type(_node), do: "any"

  # The validator reports which schema keyword failed and where, but its error
  # struct also carries the offending data. Only the structural path and the
  # keyword travel out. No validator detail is emitted, so a new keyword cannot
  # start disclosing values by default.
  defp violations(validator, value, schema, branch_index) do
    case JSV.validate(value, validator, cast: false) do
      {:ok, _validated} ->
        []

      {:error, error} ->
        error
        |> JSV.normalize_error()
        |> Map.get(:details, [])
        |> Enum.flat_map(&unit_violations(&1, schema, branch_index))
        |> Enum.uniq_by(&{&1.segments, &1.kind})
        |> Enum.take(@max_violations)
    end
  rescue
    _exception -> []
  end

  # `normalize_error/1` is JSV's supported projection: nested units carrying an
  # `instanceLocation` pointer and the keywords that failed there. Walking the
  # validator's internal error structs instead lost every violation as soon as
  # more than one array element failed, because applicator keywords nest their
  # causes differently at depth.
  defp unit_violations(unit, schema, branch_index) do
    segments = unit |> Map.get(:instanceLocation, "#") |> pointer_segments(schema)

    unit
    |> Map.get(:errors, [])
    |> Enum.flat_map(fn error ->
      details = error |> Map.get(:details, []) |> List.wrap()

      cond do
        Map.get(error, :kind) == :oneOf and details != [] ->
          details
          |> selected_branches(schema, branch_index)
          |> Enum.flat_map(fn {detail, branch_schema} ->
            unit_violations(detail, branch_schema, nil)
          end)

        details != [] ->
          Enum.flat_map(details, &unit_violations(&1, schema, branch_index))

        true ->
          leaf_violation(segments, Map.get(error, :kind))
      end
    end)
  end

  # JSV flattens nested branch errors and sorts them by instance location, so
  # neither the detail count nor its position corresponds to the `oneOf`
  # alternatives. The evaluation/schema pointer is the stable branch identity.
  # Every detail from the discriminator-selected branch remains relevant; the
  # other alternatives are rejected by their own `const` and must stay private.
  defp selected_branches(details, %{"oneOf" => branches} = schema, branch_index) do
    Enum.flat_map(details, fn detail ->
      case detail_branch_index(detail) do
        {:ok, index} when is_nil(branch_index) or index == branch_index ->
          case Enum.at(branches, index) do
            nil -> []
            branch_schema -> [{detail, branch_schema}]
          end

        {:ok, _other_index} ->
          []

        :error when is_nil(branch_index) ->
          [{detail, schema}]

        :error ->
          []
      end
    end)
  end

  defp selected_branches(details, schema, _branch_index),
    do: Enum.map(details, &{&1, schema})

  defp detail_branch_index(detail) do
    pointer = Map.get(detail, :evaluationPath) || Map.get(detail, :schemaLocation)

    case pointer do
      "#/oneOf/" <> rest ->
        rest
        |> String.split("/", parts: 2)
        |> hd()
        |> nonnegative_index()

      _other ->
        :error
    end
  end

  defp leaf_violation(_segments, nil), do: []

  defp leaf_violation(_segments, kind)
       when kind in [:properties, :items, :oneOf, :allOf, :anyOf],
       do: []

  defp leaf_violation(nil, _kind), do: []
  defp leaf_violation(segments, kind), do: [%{segments: segments, kind: kind}]

  # JSV exposes RFC 6901 instance pointers. Decode the pointer, then authorize
  # each segment against the exact schema node at that location. A property
  # declared elsewhere in the contract is not authority for this path.
  defp pointer_segments("#", _schema), do: []

  defp pointer_segments("#/" <> rest, schema) do
    rest
    |> String.split("/")
    |> Enum.map(&decode_pointer_segment/1)
    |> walk_schema_path(schema, [])
  end

  defp pointer_segments(_other, _schema), do: nil

  defp walk_schema_path([], _schema, retained), do: Enum.reverse(retained)

  defp walk_schema_path([segment | rest], %{"type" => "object"} = schema, retained) do
    properties = Map.get(schema, "properties", %{})

    case Map.fetch(properties, segment) do
      {:ok, child} ->
        walk_schema_path(rest, child, [{:property, segment} | retained])

      :error ->
        Enum.reverse(retained)
    end
  end

  defp walk_schema_path([segment | rest], %{"type" => "array", "items" => child}, retained) do
    case nonnegative_index(segment) do
      {:ok, index} -> walk_schema_path(rest, child, [{:index, index} | retained])
      :error -> Enum.reverse(retained)
    end
  end

  defp walk_schema_path(_segments, _schema, retained), do: Enum.reverse(retained)

  defp decode_pointer_segment(segment),
    do: segment |> String.replace("~1", "/") |> String.replace("~0", "~")

  defp nonnegative_index(segment) do
    case Integer.parse(segment) do
      {index, ""} when index >= 0 ->
        if Integer.to_string(index) == segment, do: {:ok, index}, else: :error

      _invalid ->
        :error
    end
  end

  # Object guidance is attached to the existing schema-authorized violation
  # path so input classifications keep using the same attested CommandPath
  # channel. JSV can emit several keywords for one object; enrich only the first
  # retained record at each path so long schema names are not repeated.
  defp enrich_violations(violations, schema, value) when is_map(schema) do
    {enriched, _seen} =
      Enum.map_reduce(violations, MapSet.new(), fn violation, seen ->
        segments = Map.get(violation, :segments)

        if not is_list(segments) or MapSet.member?(seen, segments) do
          {violation, seen}
        else
          case schema_value_at_path(schema, value, segments) do
            {:ok, %{"type" => "object"} = object_schema, object_value} ->
              {
                violation
                |> put_declared_expected(object_schema)
                |> object_diagnostic(object_schema, object_value),
                MapSet.put(seen, segments)
              }

            {:ok, node, _node_value} ->
              {put_declared_expected(violation, node), MapSet.put(seen, segments)}

            :error ->
              {violation, seen}
          end
        end
      end)

    enriched
  end

  defp enrich_violations(violations, _schema, _value), do: violations

  defp put_declared_expected(%{kind: kind} = violation, schema) do
    case JSONSchema.declared_expected(kind, schema) do
      {:ok, expected} -> Map.put(violation, :expected, expected)
      :omit -> violation
    end
  end

  defp put_declared_expected(violation, _schema), do: violation

  defp model_feedback_violation(violation) when is_map(violation) do
    Map.take(violation, [
      :kind,
      :segments,
      :expected,
      :allowed_keys,
      :allowed_key_count,
      :allowed_keys_truncated,
      :missing_required,
      :missing_required_count,
      :missing_required_truncated,
      :undeclared_key_count
    ])
  end

  defp model_feedback_violation(_violation), do: %{}

  defp schema_value_at_path(schema, value, []), do: {:ok, schema, value}

  defp schema_value_at_path(
         %{"type" => "object", "properties" => properties},
         value,
         [{:property, name} | rest]
       )
       when is_map(properties) and is_map(value) and not is_struct(value) do
    with {:ok, child_schema} <- Map.fetch(properties, name),
         {:ok, child_value} <- Map.fetch(value, name) do
      schema_value_at_path(child_schema, child_value, rest)
    end
  end

  defp schema_value_at_path(
         %{"type" => "array", "items" => items},
         value,
         [{:index, index} | rest]
       )
       when is_list(value) and is_integer(index) and index >= 0 do
    case Enum.fetch(value, index) do
      {:ok, child_value} -> schema_value_at_path(items, child_value, rest)
      :error -> :error
    end
  end

  defp schema_value_at_path(_schema, _value, _segments), do: :error

  defp object_diagnostic(violation, schema, value) do
    violation
    |> put_missing_required(schema, value)
    |> put_closed_object_diagnostic(schema, value)
  end

  defp put_missing_required(violation, schema, value)
       when is_map(value) and not is_struct(value) do
    missing_required =
      schema
      |> Map.get("required", [])
      |> Enum.reject(&Map.has_key?(value, &1))
      |> Enum.sort()

    maybe_put_missing_required(violation, missing_required)
  end

  defp put_missing_required(violation, _schema, _value), do: violation

  defp put_closed_object_diagnostic(violation, %{"additionalProperties" => false} = schema, value) do
    allowed_keys = schema |> Map.get("properties", %{}) |> Map.keys() |> Enum.sort()

    violation
    |> put_name_diagnostic(
      :allowed_keys,
      :allowed_key_count,
      :allowed_keys_truncated,
      allowed_keys
    )
    |> put_undeclared_key_count(value, MapSet.new(allowed_keys))
  end

  defp put_closed_object_diagnostic(violation, _schema, _value), do: violation

  defp put_undeclared_key_count(violation, value, allowed)
       when is_map(value) and not is_struct(value) do
    undeclared_key_count =
      Enum.count(value, fn {name, _child} -> not MapSet.member?(allowed, name) end)

    maybe_put_undeclared_key_count(violation, undeclared_key_count)
  end

  defp put_undeclared_key_count(violation, _value, _allowed), do: violation

  defp maybe_put_missing_required(violation, []), do: violation

  defp maybe_put_missing_required(violation, missing_required) do
    put_name_diagnostic(
      violation,
      :missing_required,
      :missing_required_count,
      :missing_required_truncated,
      missing_required
    )
  end

  defp maybe_put_undeclared_key_count(violation, 0), do: violation

  defp maybe_put_undeclared_key_count(violation, count),
    do: Map.put(violation, :undeclared_key_count, count)

  defp put_name_diagnostic(violation, list_key, count_key, truncated_key, names) do
    {retained, encoded_bytes} =
      Enum.reduce_while(names, {[], 2}, fn name, {retained, bytes} ->
        separator_bytes = if retained == [], do: 0, else: 1

        case DeterministicJSON.encode(name) do
          {:ok, encoded} ->
            next_bytes = bytes + separator_bytes + byte_size(encoded)

            if length(retained) < @max_diagnostic_names and
                 next_bytes <= @max_diagnostic_name_bytes do
              {:cont, {[name | retained], next_bytes}}
            else
              {:halt, {retained, bytes}}
            end

          {:error, _reason} ->
            {:halt, {retained, bytes}}
        end
      end)

    retained = Enum.reverse(retained)
    violation = Map.put(violation, list_key, retained)

    if length(retained) == length(names) and encoded_bytes <= @max_diagnostic_name_bytes do
      violation
    else
      violation
      |> Map.put(count_key, length(names))
      |> Map.put(truncated_key, true)
    end
  end

  defp classify_union(branches, value) do
    with {:ok, name} <- shared_discriminator(branches),
         true <- is_map(value),
         {:ok, tag} when is_binary(tag) <- Map.fetch(value, name),
         index when is_integer(index) <-
           Enum.find_index(branches, &(get_in(&1, ["properties", name, "const"]) == tag)) do
      %{discriminator: name, matched_branch: tag, branch_index: index}
    else
      _other ->
        %{
          discriminator: discriminator_name(branches),
          matched_branch: nil,
          expected_branches: Enum.map(branches, &branch_tag(&1, discriminator_name(branches)))
        }
    end
  end

  defp discriminator_name(branches) do
    case shared_discriminator(branches) do
      {:ok, name} -> name
      _other -> nil
    end
  end

  @doc false
  @spec prompt_discriminator(t()) :: {:ok, binary()} | :error
  def prompt_discriminator(%__MODULE__{schema: %{"oneOf" => branches}} = contract) do
    if sealed?(contract), do: shared_discriminator(branches), else: :error
  end

  def prompt_discriminator(_contract), do: :error

  defp branch_tag(branch, nil), do: get_in(branch, ["properties"]) && nil
  defp branch_tag(branch, name), do: get_in(branch, ["properties", name, "const"])

  defp value_kind(value) when is_binary(value), do: :string
  defp value_kind(value) when is_boolean(value), do: :boolean
  defp value_kind(value) when is_integer(value), do: :integer
  defp value_kind(value) when is_float(value), do: :number
  defp value_kind(value) when is_list(value), do: :array
  defp value_kind(value) when is_map(value) and not is_struct(value), do: :object
  defp value_kind(nil), do: :null
  defp value_kind(_value), do: :unknown

  defp compile_object(schema) do
    case JSONSchema.compile(schema) do
      {:ok, normalized, validator} ->
        {:ok, seal(normalized, validator)}

      {:error, {:invalid_schema, rejection}} ->
        {:error, {:invalid_value_contract, rejection}}
    end
  end

  defp behavior_schema(schema) when is_map(schema) do
    schema
    |> Map.drop(["title", "description"])
    |> maybe_map_schema_children("properties", fn properties ->
      Map.new(properties, fn {name, child} -> {name, behavior_schema(child)} end)
    end)
    |> maybe_map_schema_children("items", &behavior_schema/1)
    |> maybe_map_schema_children("oneOf", &Enum.map(&1, fn branch -> behavior_schema(branch) end))
  end

  defp maybe_map_schema_children(schema, key, mapper) do
    case Map.fetch(schema, key) do
      {:ok, value} -> Map.put(schema, key, mapper.(value))
      :error -> schema
    end
  end

  defp compile_tagged_union(schema) do
    with :ok <- union_root_keys(schema),
         {:ok, root} <- normalize_root(schema),
         {:ok, branches} <- union_branches(root),
         {:ok, normalized_branches} <- compile_branches(branches),
         {:ok, _discriminator} <- union_discriminator(normalized_branches),
         normalized = Map.put(root, "oneOf", normalized_branches),
         {:ok, encoded} <- encode_contract(normalized),
         :ok <- validate_contract_size(encoded),
         {:ok, validator} <- build_union(normalized) do
      {:ok, seal(normalized, validator)}
    end
  end

  defp union_root_keys(schema) do
    if JSONValue.map?(schema) do
      case schema |> Map.keys() |> Enum.reject(&(&1 in @root_keys)) |> Enum.sort() do
        [] -> :ok
        [key | _rest] when is_binary(key) -> invalid(:unsupported_keyword, [{:property, key}])
        _non_binary -> invalid(:unsupported_keyword, [])
      end
    else
      invalid(:not_a_schema_object, [])
    end
  end

  defp union_branches(root) do
    case root["oneOf"] do
      branches when is_list(branches) and length(branches) in 2..@max_branches ->
        {:ok, branches}

      _invalid ->
        invalid(:union_branch_count, [{:property, "oneOf"}])
    end
  end

  defp encode_contract(normalized) do
    case DeterministicJSON.encode(normalized) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> invalid(:unsupported_schema, [])
    end
  end

  defp validate_contract_size(encoded) do
    if byte_size(encoded) <= @max_contract_bytes,
      do: :ok,
      else: invalid(:schema_too_large, [])
  end

  defp build_union(normalized) do
    case JSV.build(normalized, atoms: false, formats: [SHA256Format], warnings: :silent) do
      {:ok, validator} -> {:ok, validator}
      _invalid -> invalid(:unsupported_schema, [])
    end
  end

  defp normalize_root(schema) do
    with :ok <- valid_dialect(Map.get(schema, "$schema")),
         :ok <- optional_text(schema, "title"),
         :ok <- optional_text(schema, "description") do
      {:ok, Map.delete(schema, "$schema")}
    end
  end

  defp valid_dialect(nil), do: :ok
  defp valid_dialect(value) when value in @dialects, do: :ok
  defp valid_dialect(_value), do: invalid(:unsupported_dialect, [{:property, "$schema"}])

  defp optional_text(schema, key) do
    case Map.fetch(schema, key) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        if String.valid?(value), do: :ok, else: invalid(:invalid_keyword_value, key_segments(key))

      {:ok, _value} ->
        invalid(:invalid_keyword_value, key_segments(key))
    end
  end

  # A branch carries its own rejection, relocated under the branch it came
  # from: `/oneOf/1/properties/kind/type` is a location the author can open,
  # while "one of the branches is invalid" is another blind refusal.
  defp compile_branches(branches) do
    branches
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {branch, index}, {:ok, normalized} ->
      case compile_branch(branch, index) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | normalized]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp compile_branch(branch, index) do
    case JSONSchema.compile(branch) do
      {:ok, %{"type" => "object", "additionalProperties" => false} = compiled, _validator} ->
        {:ok, compiled}

      {:ok, _open, _validator} ->
        invalid(
          :union_branch_not_closed_object,
          branch_segments(index) ++ [{:property, "additionalProperties"}]
        )

      {:error, {:invalid_schema, %{rule: rule, segments: segments}}} ->
        invalid(rule, branch_segments(index) ++ segments)
    end
  end

  defp union_discriminator(branches) do
    case shared_discriminator(branches) do
      {:ok, name} -> {:ok, name}
      _invalid -> invalid(:union_discriminator_missing, [{:property, "oneOf"}])
    end
  end

  defp branch_segments(index), do: [{:property, "oneOf"}, {:index, index}]

  defp key_segments(key) when is_binary(key), do: [{:property, key}]

  defp shared_discriminator([first | rest] = branches) do
    candidates =
      first
      |> discriminator_candidates()
      |> Enum.filter(fn name ->
        Enum.all?(rest, &(name in discriminator_candidates(&1)))
      end)

    case candidates do
      [name] ->
        values = Enum.map(branches, &get_in(&1, ["properties", name, "const"]))

        if distinct_discriminator_values?(values), do: {:ok, name}, else: :error

      _none_or_ambiguous ->
        :error
    end
  end

  defp discriminator_candidates(branch) do
    properties = Map.get(branch, "properties", %{})

    branch
    |> Map.get("required", [])
    |> Enum.filter(fn name ->
      case Map.get(properties, name) do
        %{"type" => "string", "const" => value}
        when is_binary(value) and byte_size(value) in 1..@max_discriminator_bytes ->
          String.valid?(value)

        _other ->
          false
      end
    end)
  end

  defp distinct_discriminator_values?(values) do
    length(values) == MapSet.size(MapSet.new(values))
  end

  defp seal(schema, validator) do
    contract = %__MODULE__{schema: schema, validator: validator, attestation: <<>>}
    %{contract | attestation: Attestation.attest(__MODULE__, payload(contract))}
  end

  defp classification_evidence(contract, branch_index) do
    path_schema = selected_path_schema(contract.schema, branch_index)

    evidence = %ValueContractClassification{
      behavior_hash: behavior_hash(contract),
      path_schema: path_schema,
      attestation: <<>>
    }

    payload = {evidence.behavior_hash, evidence.path_schema}

    %{
      evidence
      | attestation: Attestation.attest(ValueContractClassification, payload)
    }
  end

  defp selected_path_schema(%{"oneOf" => branches}, branch_index)
       when is_list(branches) and is_integer(branch_index) and branch_index >= 0,
       do: Enum.at(branches, branch_index)

  defp selected_path_schema(%{"oneOf" => [first | _rest] = branches}, nil) do
    with {:ok, name} <- shared_discriminator(branches),
         %{"properties" => properties} <- first,
         {:ok, discriminator_schema} <- Map.fetch(properties, name) do
      %{
        "type" => "object",
        "properties" => %{name => discriminator_schema},
        "required" => [name],
        "additionalProperties" => true
      }
    else
      _invalid -> nil
    end
  end

  defp selected_path_schema(schema, nil) when is_map(schema), do: schema
  defp selected_path_schema(_schema, _branch_index), do: nil

  defp payload(contract), do: {contract.schema, contract.validator}
end
