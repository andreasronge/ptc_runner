defmodule PtcRunner.SubAgent.Prompt.Output do
  @moduledoc """
  Expected output section generation for SubAgent prompts.

  Generates the Expected Output section that shows the required return format
  based on the agent's signature. Also handles field description rendering
  for output fields.
  """

  alias PtcRunner.SubAgent.Prompt.DataInventory
  alias PtcRunner.SubAgent.Signature.Renderer

  @doc """
  Generate the expected output section from signature.

  Shows the required return format based on the agent's signature,
  including field descriptions if available.

  ## Parameters

  - `context_signature` - Parsed signature for return type information
  - `field_descriptions` - Optional map of field name atoms to description strings

  ## Returns

  A string containing the expected output section, or empty string if no signature.

  ## Examples

      iex> sig = {:signature, [{"x", :int}], :int}
      iex> output = PtcRunner.SubAgent.Prompt.Output.generate(sig, nil)
      iex> output =~ "Expected Output"
      true
      iex> output =~ ":int"
      true

  """
  @spec generate(PtcRunner.SubAgent.Signature.signature() | nil, map() | nil) :: String.t()
  def generate(nil, _field_descriptions), do: ""

  def generate({:signature, _params, return_type}, field_descriptions) do
    type_str = Renderer.render_type(return_type)
    example_val = generate_return_example_value(return_type)

    # Add field descriptions for output fields if available
    field_descs = generate_output_field_descriptions(return_type, field_descriptions)

    """
    # Expected Output

    Your final answer must match this format: `#{type_str}`#{field_descs}

    Call `(return #{example_val})` when complete.
    """
  end

  # ============================================================
  # Private Helpers - Field Descriptions
  # ============================================================

  # Generate field descriptions for output fields
  defp generate_output_field_descriptions({:map, fields}, field_descriptions)
       when is_map(field_descriptions) and map_size(field_descriptions) > 0 do
    descs =
      fields
      |> Enum.flat_map(fn {name, _type} ->
        get_field_description_for_list(name, field_descriptions)
      end)

    if descs == [] do
      ""
    else
      "\n\nField descriptions:\n" <> Enum.join(descs, "\n")
    end
  end

  defp generate_output_field_descriptions(_return_type, _field_descriptions), do: ""

  defp get_field_description_for_list(name, field_descriptions) do
    case DataInventory.get_field_description(name, field_descriptions) do
      nil -> []
      desc -> ["  - `#{name}`: #{desc}"]
    end
  end

  # ============================================================
  # Private Helpers - Example Value Generation
  # ============================================================

  defp generate_return_example_value(:int), do: "42"
  defp generate_return_example_value(:float), do: "3.14"
  defp generate_return_example_value(:string), do: "\"result\""
  defp generate_return_example_value(:bool), do: "true"
  defp generate_return_example_value(:keyword), do: ":ok"
  defp generate_return_example_value(:any), do: "nil"
  defp generate_return_example_value(:map), do: "{}"

  defp generate_return_example_value({:optional, type}) do
    generate_return_example_value(type)
  end

  defp generate_return_example_value({:list, _type}) do
    "[]"
  end

  defp generate_return_example_value({:map, fields}) do
    inner =
      Enum.map_join(fields, ", ", fn {name, type} ->
        ":#{name} #{generate_return_example_value(type)}"
      end)

    "{#{inner}}"
  end
end
