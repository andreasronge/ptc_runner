defmodule PtcRunner.Kernel.ValueContract do
  @moduledoc """
  Compiled manifest-local contract for application input and `Result.value`.

  Ordinary contracts use the same bounded object profile as Kernel capability
  schemas. Application contracts additionally permit one root-only tagged
  union: two to sixteen closed object branches in `oneOf`, all sharing exactly
  one required string discriminator whose `const` value is distinct in every
  branch.

  This deliberately does not widen MCP callable schemas. References, regexes,
  nested composition, union types, and arbitrary `oneOf` remain unsupported.
  The normalized contract is limited to 64 KiB and compiled once with JSV.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONSchema
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
    |> Map.put(
      :violations,
      violations(validator, value, Map.get(shape, :branch_index), declared_names(schema))
    )
  rescue
    _exception -> %{value_kind: :unknown}
  end

  def classify(_contract, _value), do: %{value_kind: :unknown}

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

      {:error, %JSV.ValidationError{errors: errors}} ->
        errors
        |> Enum.flat_map(&flatten_error(&1, branch_index))
        |> Enum.map(&violation(&1, declared))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(&{&1.path, &1.kind})
        |> Enum.take(@max_violations)
    end
  rescue
    _exception -> []
  end

  # A tagged union reports one `:oneOf` failure whose `invalidated` branches
  # carry the errors that matter, each as an indexed validation context. Every
  # branch the discriminator did not select also fails — on its own `const`, and
  # on required keys it was never given — so reporting all of them would bury
  # the branch the caller actually meant. With a matched branch, report only its
  # context; with none, the value fits nowhere and every branch is relevant.
  defp flatten_error(%JSV.Validator.Error{kind: :oneOf, args: args}, branch_index) do
    args
    |> Keyword.get(:invalidated, [])
    |> Enum.filter(fn
      {index, _context} -> is_nil(branch_index) or index == branch_index
      _other -> true
    end)
    |> Enum.flat_map(fn
      {_index, context} -> branch_errors(context, branch_index)
      context when is_map(context) -> branch_errors(context, branch_index)
      _other -> []
    end)
  end

  defp flatten_error(%JSV.Validator.Error{} = error, _branch_index), do: [error]
  defp flatten_error(_other, _branch_index), do: []

  defp branch_errors(context, branch_index),
    do: context |> Map.get(:errors, []) |> Enum.flat_map(&flatten_error(&1, branch_index))

  defp violation(%JSV.Validator.Error{kind: :required, data_path: path, args: args}, declared),
    do: %{
      path: violation_path(path, declared),
      kind: :required,
      detail: Keyword.get(args, :required, [])
    }

  defp violation(%JSV.Validator.Error{kind: kind, data_path: path}, declared)
       when kind not in [:properties, :items, :oneOf],
       do: %{path: violation_path(path, declared), kind: kind}

  defp violation(_error, _declared), do: nil

  # `data_path` arrives innermost-first with integers for array indices. A
  # violation under `additionalProperties` is located *at the undeclared key*,
  # so the path can carry a model-authored name — the one kind of content this
  # whole function exists to keep out of a public error. Rather than special-
  # casing that keyword, every string segment is checked against the names the
  # contract declares, and anything else is replaced.
  defp violation_path([], _declared), do: "(root)"

  defp violation_path(path, declared) do
    path
    |> Enum.reverse()
    |> Enum.map_join(fn
      index when is_integer(index) -> "[#{index}]"
      key when is_binary(key) -> "." <> declared_name(key, declared)
      _other -> ".(undeclared)"
    end)
    |> String.trim_leading(".")
  end

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
           JSV.build(normalized, atoms: false, formats: false, warnings: :silent) do
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
