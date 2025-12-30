defmodule PtcRunner.SubAgent.Signature.Renderer do
  @moduledoc """
  Renders signatures back to string representation.

  Converts internal signature format to human-readable syntax for use in
  prompts and debugging.
  """

  @doc """
  Render a signature to its string representation.

  ## Examples

      iex> sig = {:signature, [{"id", :int}], :string}
      iex> PtcRunner.SubAgent.Signature.Renderer.render(sig)
      "(id :int) -> :string"

      iex> sig = {:signature, [], {:map, [{"count", :int}]}}
      iex> PtcRunner.SubAgent.Signature.Renderer.render(sig)
      "-> {count :int}"
  """
  @spec render({:signature, list(), term()}) :: String.t()
  def render({:signature, params, return_type}) do
    params_str =
      Enum.map_join(params, ", ", fn {name, type} -> "#{name} #{render_type(type)}" end)

    if params == [] do
      "-> #{render_type(return_type)}"
    else
      "(#{params_str}) -> #{render_type(return_type)}"
    end
  end

  # ============================================================
  # Type Rendering
  # ============================================================

  @spec render_type(term()) :: String.t()
  defp render_type(:string), do: ":string"
  defp render_type(:int), do: ":int"
  defp render_type(:float), do: ":float"
  defp render_type(:bool), do: ":bool"
  defp render_type(:keyword), do: ":keyword"
  defp render_type(:any), do: ":any"
  defp render_type(:map), do: ":map"

  defp render_type({:optional, type}) do
    render_type(type) <> "?"
  end

  defp render_type({:list, element_type}) do
    "[" <> render_type(element_type) <> "]"
  end

  defp render_type({:map, fields}) do
    fields_str =
      Enum.map_join(fields, ", ", fn {name, type} -> "#{name} #{render_type(type)}" end)

    "{#{fields_str}}"
  end
end
