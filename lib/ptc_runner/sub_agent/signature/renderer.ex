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
  # Key Conversion
  # ============================================================

  @doc """
  Convert a snake_case field name to kebab-case for LLM-facing prompts.

  Strips leading `_`, replaces remaining `_` with `-`, prepends `_` back.

  ## Examples

      iex> PtcRunner.SubAgent.Signature.Renderer.to_lisp_key("q1_total")
      "q1-total"

      iex> PtcRunner.SubAgent.Signature.Renderer.to_lisp_key("_email_ids")
      "_email-ids"

      iex> PtcRunner.SubAgent.Signature.Renderer.to_lisp_key("name")
      "name"
  """
  @spec to_lisp_key(String.t()) :: String.t()
  def to_lisp_key(name) do
    case name do
      "_" <> rest -> "_" <> String.replace(rest, "_", "-")
      _ -> String.replace(name, "_", "-")
    end
  end

  # ============================================================
  # Type Rendering
  # ============================================================

  @doc """
  Render a type spec to its string representation.

  Converts type tuples and atoms to their PTC-Lisp syntax representation
  (e.g., `:string`, `[int]`, `{key :string}`).

  Accepts an optional `key_style` option:
  - `:lisp_prompt` — converts map field names to kebab-case for LLM-facing prompts

  ## Examples

      iex> PtcRunner.SubAgent.Signature.Renderer.render_type(:string)
      ":string"

      iex> PtcRunner.SubAgent.Signature.Renderer.render_type({:optional, :int})
      ":int?"

      iex> PtcRunner.SubAgent.Signature.Renderer.render_type({:list, :string})
      "[:string]"
  """
  @spec render_type(term(), keyword()) :: String.t()
  def render_type(type, opts \\ [])
  def render_type(:string, _opts), do: ":string"
  def render_type(:int, _opts), do: ":int"
  def render_type(:float, _opts), do: ":float"
  def render_type(:bool, _opts), do: ":bool"
  def render_type(:keyword, _opts), do: ":keyword"
  def render_type(:any, _opts), do: ":any"
  def render_type(:map, _opts), do: ":map"

  def render_type({:optional, type}, opts) do
    render_type(type, opts) <> "?"
  end

  def render_type({:list, element_type}, opts) do
    "[" <> render_type(element_type, opts) <> "]"
  end

  def render_type({:map, fields}, opts) do
    key_fn =
      if Keyword.get(opts, :key_style) == :lisp_prompt do
        &to_lisp_key/1
      else
        & &1
      end

    fields_str =
      Enum.map_join(fields, ", ", fn {name, type} ->
        "#{key_fn.(name)} #{render_type(type, opts)}"
      end)

    "{#{fields_str}}"
  end
end
