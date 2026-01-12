defmodule PtcRunner.SubAgent.Namespace do
  @moduledoc """
  Renders namespaces for the USER message (REPL with Prelude model).

  Coordinates rendering of:
  - tool/ : Available tools (from agent config, stable)
  - data/ : Input data (from agent config, stable)
  - user/ : LLM definitions (prelude, grows each turn)
  """

  alias PtcRunner.SubAgent.Namespace.{Data, Tool, User}

  @doc """
  Render all namespaces as a single string.

  ## Config keys
  - `tools` - Map of tool name to tool struct (for tool/ namespace)
  - `data` - Map of input data (for data/ namespace)
  - `memory` - Map of LLM definitions (for user/ namespace)
  - `has_println` - Boolean, controls sample display in user/ namespace

  Returns `nil` if all sections are empty.

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.render(%{})
      nil

      iex> tool = %PtcRunner.Tool{name: "search", signature: "(query :string) -> :string"}
      iex> PtcRunner.SubAgent.Namespace.render(%{tools: %{"search" => tool}})
      ";; === tools ===\\ntool/search(query) -> string"

      iex> PtcRunner.SubAgent.Namespace.render(%{data: %{count: 42}})
      ";; === data/ ===\\ndata/count                    ; integer, sample: 42"

      iex> PtcRunner.SubAgent.Namespace.render(%{memory: %{total: 100}, has_println: false})
      ";; === user/ (your prelude) ===\\ntotal                         ; = integer, sample: 100"
  """
  @spec render(map()) :: String.t() | nil
  def render(config) do
    [
      Tool.render(config[:tools] || %{}),
      Data.render(config[:data] || %{}),
      User.render(config[:memory] || %{}, config[:has_println] || false)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      sections -> Enum.join(sections, "\n\n")
    end
  end
end
