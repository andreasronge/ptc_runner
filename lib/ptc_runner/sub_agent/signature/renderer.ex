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

  @doc """
  Render a type spec to its string representation.

  Converts type tuples and atoms to their PTC-Lisp syntax representation
  (e.g., `:string`, `[int]`, `{key :string}`).

  ## Examples

      iex> PtcRunner.SubAgent.Signature.Renderer.render_type(:string)
      ":string"

      iex> PtcRunner.SubAgent.Signature.Renderer.render_type({:optional, :int})
      ":int?"

      iex> PtcRunner.SubAgent.Signature.Renderer.render_type({:list, :string})
      "[:string]"
  """
  @spec render_type(term()) :: String.t()
  def render_type(:string), do: ":string"
  def render_type(:int), do: ":int"
  def render_type(:float), do: ":float"
  def render_type(:bool), do: ":bool"
  def render_type(:keyword), do: ":keyword"
  def render_type(:any), do: ":any"
  def render_type(:map), do: ":map"

  def render_type({:optional, type}) do
    render_type(type) <> "?"
  end

  def render_type({:list, element_type}) do
    "[" <> render_type(element_type) <> "]"
  end

  def render_type({:map, fields}) do
    fields_str =
      Enum.map_join(fields, ", ", fn {name, type} -> "#{name} #{render_type(type)}" end)

    "{#{fields_str}}"
  end
end
