defmodule PtcRunner.SubAgent.Namespace.Data do
  @moduledoc "Renders the data/ namespace section."

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.Namespace.TypeVocabulary
  alias PtcRunner.SubAgent.Signature.Renderer

  @name_width 30

  @doc """
  Render data/ namespace section for USER message.

  Returns `nil` for empty data maps, otherwise a formatted string with header
  and entries showing type label and truncated sample.

  ## Options

  - `:field_descriptions` - Map of field names to description strings
  - `:context_signature` - Parsed signature for type information
  - `:sample_limit` - Max items to show in collections (default: 3)
  - `:sample_printable_limit` - Max chars for strings (default: 80)

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.Data.render(%{})
      nil

      iex> PtcRunner.SubAgent.Namespace.Data.render(%{count: 42})
      ";; === data/ ===\\ndata/count                    ; integer, sample: 42"

      iex> PtcRunner.SubAgent.Namespace.Data.render(%{_token: "secret"})
      ";; === data/ ===\\ndata/_token                   ; string, [Hidden] [Firewalled]"

      iex> PtcRunner.SubAgent.Namespace.Data.render(%{x: 5}, field_descriptions: %{x: "Input value"})
      ";; === data/ ===\\ndata/x                        ; integer, sample: 5 -- Input value"
  """
  @spec render(map(), keyword()) :: String.t() | nil
  def render(data, opts \\ [])

  def render(data, _opts) when map_size(data) == 0, do: nil

  def render(data, opts) do
    field_descriptions = Keyword.get(opts, :field_descriptions, %{}) || %{}
    context_signature = Keyword.get(opts, :context_signature)

    # Extract param types from signature if available
    param_types = extract_param_types(context_signature)

    lines =
      data
      |> Enum.sort_by(fn {name, _} -> to_string(name) end)
      |> Enum.map(fn {name, value} ->
        format_entry(name, value, param_types, field_descriptions, opts)
      end)

    [";; === data/ ===" | lines] |> Enum.join("\n")
  end

  defp extract_param_types({:signature, params, _return_type}) do
    params
    |> Enum.map(fn {name, type} -> {to_string(name), type} end)
    |> Map.new()
  end

  defp extract_param_types(_), do: %{}

  defp format_entry(name, value, param_types, field_descriptions, opts) do
    name_str = to_string(name)
    is_firewalled = String.starts_with?(name_str, "_")

    # Get type - prefer signature type, fall back to runtime inference
    type_label = get_type_label(name_str, value, param_types)

    # Build the line parts
    padded_name = String.pad_trailing("data/#{name_str}", @name_width)

    sample_part =
      if is_firewalled do
        "[Hidden] [Firewalled]"
      else
        "sample: #{format_sample(value, opts)}"
      end

    desc_part =
      case get_field_description(name, field_descriptions) do
        nil -> ""
        desc -> " -- #{desc}"
      end

    "#{padded_name}; #{type_label}, #{sample_part}#{desc_part}"
  end

  defp get_type_label(name_str, value, param_types) do
    case Map.get(param_types, name_str) do
      nil ->
        # Use runtime type inference
        TypeVocabulary.type_of(value)

      type ->
        # Use signature type, render without colons
        Renderer.render_type(type) |> String.replace(":", "")
    end
  end

  defp get_field_description(_key, nil), do: nil
  defp get_field_description(_key, descriptions) when map_size(descriptions) == 0, do: nil

  defp get_field_description(key, descriptions) do
    key_atom = if is_atom(key), do: key, else: String.to_existing_atom(to_string(key))
    key_str = to_string(key)

    Map.get(descriptions, key_atom) || Map.get(descriptions, key_str)
  rescue
    ArgumentError -> Map.get(descriptions, to_string(key))
  end

  defp format_sample(value, opts) do
    limit = Keyword.get(opts, :sample_limit, 3)
    printable_limit = Keyword.get(opts, :sample_printable_limit, 80)
    {str, _truncated} = Format.to_clojure(value, limit: limit, printable_limit: printable_limit)
    str
  end
end
