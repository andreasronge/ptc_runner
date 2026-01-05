defmodule PtcRunner.SubAgent.Prompt.DataInventory do
  @moduledoc """
  Data inventory section generation for SubAgent prompts.

  Generates the Data Inventory section that shows available context variables
  with their inferred types and sample values. Handles nested maps, lists,
  and firewalled fields (prefixed with `_`).
  """

  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.SubAgent.Signature.Renderer

  @doc """
  Generate the data inventory section from context.

  Shows available context variables with their inferred types and sample values.
  Handles nested maps, lists, and firewalled fields (prefixed with `_`).
  When field descriptions are provided (from upstream agent chaining), they are
  rendered as Clojure-style comments below each field.

  ## Parameters

  - `context` - Context map
  - `context_signature` - Optional parsed signature for type information
  - `field_descriptions` - Optional map of field name atoms to description strings

  ## Returns

  A string containing the data inventory section in markdown format.

  ## Examples

      iex> context = %{user_id: 123, name: "Alice"}
      iex> inventory = PtcRunner.SubAgent.Prompt.DataInventory.generate(context, nil)
      iex> inventory =~ "ctx/user_id"
      true
      iex> inventory =~ "ctx/name"
      true

  """
  @spec generate(map(), Signature.signature() | nil, map() | nil) :: String.t()
  def generate(context, context_signature \\ nil, field_descriptions \\ nil)

  def generate(context, _context_signature, _field_descriptions)
      when map_size(context) == 0 do
    """
    # Data Inventory

    No data available in context.
    """
  end

  def generate(context, context_signature, field_descriptions) do
    # Get parameter types from signature if available
    param_types =
      case context_signature do
        {:signature, params, _return_type} ->
          Map.new(params)

        _ ->
          %{}
      end

    rows =
      context
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join("\n", fn {key, value} ->
        key_str = to_string(key)
        type_str = format_type(key_str, value, param_types)
        is_firewalled = String.starts_with?(key_str, "_")
        sample = if is_firewalled, do: "[Hidden]", else: format_sample(value)
        firewalled_note = if is_firewalled, do: " [Firewalled]", else: ""
        # Add field description if available
        desc = get_field_description(key, field_descriptions)
        desc_note = if desc, do: " — #{desc}", else: ""

        "| `ctx/#{key_str}` | `#{type_str}` | #{sample}#{firewalled_note}#{desc_note} |"
      end)

    header = """
    # Data Inventory

    Available in `ctx/`:

    | Key | Type | Sample |
    |-----|------|--------|
    """

    note =
      if Enum.any?(context, fn {k, _v} -> String.starts_with?(to_string(k), "_") end) do
        "\n\nNote: Firewalled fields (prefixed with `_`) are available in your program but hidden from conversation history."
      else
        ""
      end

    header <> rows <> note
  end

  @doc false
  @spec get_field_description(atom() | String.t(), map() | nil) :: String.t() | nil
  def get_field_description(_key, nil), do: nil

  def get_field_description(key, descriptions) when is_map(descriptions) do
    # Try atom key first, then string key
    key_atom = if is_atom(key), do: key, else: String.to_existing_atom(to_string(key))
    key_str = to_string(key)

    Map.get(descriptions, key_atom) || Map.get(descriptions, key_str)
  rescue
    ArgumentError -> Map.get(descriptions, to_string(key))
  end

  # ============================================================
  # Private Helpers - Type Formatting
  # ============================================================

  defp format_type(key_str, value, param_types) do
    # Try to get type from signature first
    case Map.get(param_types, key_str) do
      nil ->
        # Infer type from value
        infer_type(value)
        |> Renderer.render_type()

      type ->
        Renderer.render_type(type)
    end
  end

  # Infer type from runtime value
  defp infer_type(value) when is_binary(value), do: :string
  defp infer_type(value) when is_integer(value), do: :int
  defp infer_type(value) when is_float(value), do: :float
  defp infer_type(value) when is_boolean(value), do: :bool
  defp infer_type(value) when is_atom(value), do: :keyword

  defp infer_type(value) when is_list(value) do
    case value do
      [] -> {:list, :any}
      [first | _] -> {:list, infer_type(first)}
    end
  end

  defp infer_type(value) when is_map(value) do
    if map_size(value) == 0 do
      :map
    else
      # Infer map fields
      fields =
        value
        |> Enum.take(5)
        |> Enum.map(fn {k, v} -> {to_string(k), infer_type(v)} end)

      {:map, fields}
    end
  end

  defp infer_type(_value), do: :any

  # ============================================================
  # Private Helpers - Sample Formatting
  # ============================================================

  defp format_sample(value) when is_binary(value) do
    if String.length(value) > 50 do
      "\"#{String.slice(value, 0, 47)}...\""
    else
      inspect(value)
    end
  end

  defp format_sample(value) when is_list(value) do
    cond do
      value == [] ->
        "[]"

      length(value) <= 3 ->
        inspect(value)

      true ->
        sample = Enum.take(value, 3)
        inspect(sample) <> " (#{length(value)} items)"
    end
  end

  defp format_sample(value) when is_map(value) do
    if map_size(value) == 0 do
      "{}"
    else
      # Show first few keys
      keys =
        value
        |> Map.keys()
        |> Enum.take(3)
        |> Enum.map_join(", ", &to_string/1)

      if map_size(value) > 3 do
        "{#{keys}, ...}"
      else
        "{#{keys}}"
      end
    end
  end

  defp format_sample(value), do: inspect(value)
end
