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
