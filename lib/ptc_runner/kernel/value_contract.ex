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

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.JSONSchema.SHA256Format
  alias PtcRunner.Kernel.JSONValue

  @dialects [
    "https://json-schema.org/draft/2020-12/schema",
    "http://json-schema.org/draft-07/schema#"
  ]
  @root_keys ~w($schema title description oneOf)
  @max_branches 16
  @max_contract_bytes 65_536
  @max_discriminator_bytes 128
  @max_violations 8

  @enforce_keys [:schema, :validator]
  defstruct [:schema, :validator]

  @type t :: %__MODULE__{schema: map(), validator: JSV.Root.t()}

  @spec compile(map()) :: {:ok, t()} | {:error, :invalid_value_contract}
  def compile(schema) when is_map(schema) and not is_struct(schema) do
    case Map.has_key?(schema, "oneOf") do
      true -> compile_tagged_union(schema)
      false -> compile_object(schema)
    end
  rescue
    _exception -> {:error, :invalid_value_contract}
  end

  def compile(_schema), do: {:error, :invalid_value_contract}

  @spec valid?(t(), term()) :: boolean()
  def valid?(%__MODULE__{validator: validator}, value) do
    JSONValue.value?(value) and JSONSchema.valid?(validator, value)
  end

  def valid?(_contract, _value), do: false

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
  and the schema-declared required keys that branch did not find. The only
  facts derived from the value itself are its JSON kind and the count of keys
  the branch does not declare — a type name and a number, never content.

  A rejected result is deliberately withheld from the public error, so without
  this an operator cannot tell a missing key from a wrong shape without
  re-running under private inspection.

  `violations` locates faults, it does not enumerate them: when several array
  elements fail the same way, the reported set may name fewer of them than
  actually failed. It is a diagnosis, not a validation report.
  """
  def classify(%__MODULE__{schema: schema, validator: validator}, value) do
    shape =
      case Map.fetch(schema, "oneOf") do
        {:ok, branches} -> classify_union(branches, value)
        :error -> classify_object(schema, value)
      end

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
      violations(validator, value, Map.get(shape, :branch_index), declared_names(schema))
    )
  rescue
    _exception -> %{value_kind: :unknown}
  end

  def classify(_contract, _value), do: %{value_kind: :unknown}

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
  def describe(%__MODULE__{schema: schema}) do
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
  # keyword travel out; `detail` is emitted for `:required` alone, whose
  # argument is a list of schema-declared key names. Every other keyword
  # reports its name and location and nothing more, so a new keyword cannot
  # start disclosing values by default.
  defp violations(validator, value, branch_index, declared) do
    case JSV.validate(value, validator, cast: false) do
      {:ok, _validated} ->
        []

      {:error, error} ->
        error
        |> JSV.normalize_error()
        |> Map.get(:details, [])
        |> Enum.flat_map(&unit_violations(&1, branch_index, declared))
        |> Enum.uniq_by(&{&1.path, &1.kind})
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
  defp unit_violations(unit, branch_index, declared) do
    path = unit |> Map.get(:instanceLocation, "#") |> pointer_path(declared)

    unit
    |> Map.get(:errors, [])
    |> Enum.flat_map(fn error ->
      details = error |> Map.get(:details, []) |> List.wrap()

      cond do
        Map.get(error, :kind) == :oneOf and details != [] ->
          details
          |> selected_branches(branch_index)
          |> Enum.flat_map(&unit_violations(&1, branch_index, declared))

        details != [] ->
          Enum.flat_map(details, &unit_violations(&1, branch_index, declared))

        true ->
          leaf_violation(path, Map.get(error, :kind))
      end
    end)
  end

  # `oneOf` alternatives arrive in schema order, so the branch the
  # discriminator selected is the one at its index. Every other alternative is
  # rejected by its own `const` and then reports each key it was never given;
  # reporting those buried the one fault the caller could act on. With no
  # branch selected the value fits nowhere, and all alternatives are relevant.
  defp selected_branches(details, nil), do: details

  defp selected_branches(details, branch_index) do
    case Enum.at(details, branch_index) do
      nil -> details
      branch -> [branch]
    end
  end

  defp leaf_violation(_path, nil), do: []

  defp leaf_violation(_path, kind) when kind in [:properties, :items, :oneOf, :allOf, :anyOf],
    do: []

  defp leaf_violation(path, kind), do: [%{path: path, kind: kind}]

  # `#/evidence/0/snapshot_hash` becomes `evidence[0].snapshot_hash`. A segment
  # naming an undeclared key is caller-authored content, so it is replaced.
  defp pointer_path("#", _declared), do: "(root)"

  defp pointer_path("#/" <> rest, declared) do
    rest
    |> String.split("/")
    |> Enum.map_join(fn segment ->
      case Integer.parse(segment) do
        {index, ""} -> "[#{index}]"
        _other -> "." <> declared_name(segment, declared)
      end
    end)
    |> String.trim_leading(".")
  end

  defp pointer_path(_other, _declared), do: "(root)"

  defp declared_name(key, declared) do
    if MapSet.member?(declared, key), do: key, else: "(undeclared)"
  end

  # Every property name the contract mentions, at any depth. Bounded by the
  # 64 KiB normalized contract, so this stays small.
  defp declared_names(schema) when is_map(schema) do
    own =
      schema
      |> Map.get("properties", %{})
      |> Map.keys()
      |> MapSet.new()

    schema
    |> Map.drop(["properties"])
    |> Map.values()
    |> Enum.concat(Map.values(Map.get(schema, "properties", %{})))
    |> Enum.reduce(own, fn value, acc -> MapSet.union(acc, declared_names(value)) end)
  end

  defp declared_names(values) when is_list(values),
    do:
      Enum.reduce(values, MapSet.new(), fn value, acc ->
        MapSet.union(acc, declared_names(value))
      end)

  defp declared_names(_other), do: MapSet.new()

  defp classify_union(branches, value) do
    with {:ok, name} <- shared_discriminator(branches),
         true <- is_map(value),
         {:ok, tag} when is_binary(tag) <- Map.fetch(value, name),
         index when is_integer(index) <-
           Enum.find_index(branches, &(get_in(&1, ["properties", name, "const"]) == tag)) do
      Map.merge(
        %{discriminator: name, matched_branch: tag, branch_index: index},
        classify_object(Enum.at(branches, index), value)
      )
    else
      _other ->
        %{
          discriminator: discriminator_name(branches),
          matched_branch: nil,
          expected_branches: Enum.map(branches, &branch_tag(&1, discriminator_name(branches)))
        }
    end
  end

  defp classify_object(schema, value) when is_map(value) do
    required = Map.get(schema, "required", [])
    declared = schema |> Map.get("properties", %{}) |> Map.keys() |> MapSet.new()

    %{
      missing_required: Enum.reject(required, &Map.has_key?(value, &1)),
      undeclared_key_count: Enum.count(Map.keys(value), &(not MapSet.member?(declared, &1)))
    }
  end

  defp classify_object(schema, _value),
    do: %{missing_required: Map.get(schema, "required", []), undeclared_key_count: 0}

  defp discriminator_name(branches) do
    case shared_discriminator(branches) do
      {:ok, name} -> name
      _other -> nil
    end
  end

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
        {:ok, %__MODULE__{schema: normalized, validator: validator}}

      {:error, :invalid_schema} ->
        {:error, :invalid_value_contract}
    end
  end

  defp compile_tagged_union(schema) do
    with true <- JSONValue.map?(schema),
         true <- Map.keys(schema) -- @root_keys == [],
         {:ok, root} <- normalize_root(schema),
         branches when is_list(branches) <- root["oneOf"],
         true <- length(branches) in 2..@max_branches,
         {:ok, normalized_branches} <- compile_branches(branches),
         {:ok, _discriminator} <- shared_discriminator(normalized_branches),
         normalized = Map.put(root, "oneOf", normalized_branches),
         {:ok, encoded} <- DeterministicJSON.encode(normalized),
         true <- byte_size(encoded) <= @max_contract_bytes,
         {:ok, validator} <-
           JSV.build(normalized,
             atoms: false,
             formats: [SHA256Format],
             warnings: :silent
           ) do
      {:ok, %__MODULE__{schema: normalized, validator: validator}}
    else
      _reason -> {:error, :invalid_value_contract}
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
  defp valid_dialect(_value), do: {:error, :invalid_value_contract}

  defp optional_text(schema, key) do
    case Map.fetch(schema, key) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        if String.valid?(value), do: :ok, else: {:error, :invalid_value_contract}

      {:ok, _value} ->
        {:error, :invalid_value_contract}
    end
  end

  defp compile_branches(branches) do
    Enum.reduce_while(branches, {:ok, []}, fn branch, {:ok, normalized} ->
      case JSONSchema.compile(branch) do
        {:ok, %{"type" => "object", "additionalProperties" => false} = compiled, _validator} ->
          {:cont, {:ok, [compiled | normalized]}}

        _invalid ->
          {:halt, {:error, :invalid_value_contract}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

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

        if distinct_discriminator_values?(values),
          do: {:ok, name},
          else: {:error, :invalid_value_contract}

      _none_or_ambiguous ->
        {:error, :invalid_value_contract}
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
end
