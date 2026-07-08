defmodule PtcRunner.SymbolInventory.ReferenceRenderer do
  @moduledoc "Alternate deterministic renderer used to prove renderer swappability."

  alias PtcRunner.SymbolInventory.DefaultRenderer

  @id "reference_v1"

  @spec id() :: String.t()
  def id, do: @id

  @spec render([map()], keyword()) :: {String.t() | nil, map()}
  def render(facts, opts \\ []) do
    {default_text, meta} = DefaultRenderer.render(facts, opts)

    text =
      if is_binary(default_text) do
        String.replace(
          default_text,
          ";; === available symbols ===",
          ";; === symbol reference ==="
        )
      end

    {text, %{meta | "renderer_id" => @id}}
  end
end
