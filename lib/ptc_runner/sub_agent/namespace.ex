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
  - `field_descriptions` - Map of field names to description strings (for data/)
  - `context_signature` - Parsed signature for type information (for data/)
  - `memory` - Map of LLM definitions (for user/ namespace)
  - `has_println` - Boolean, controls sample display in user/ namespace

  Always includes the tools section (showing available tools or "No tools available").

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.render(%{})
      ";; No tools available"

      iex> tool = %PtcRunner.Tool{name: "search", signature: "(query :string) -> :string"}
      iex> PtcRunner.SubAgent.Namespace.render(%{tools: %{"search" => tool}})
      ";; === tools ===\\ntool/search(query string) -> string\\n;; Example: (tool/search {:query ...})"

      iex> PtcRunner.SubAgent.Namespace.render(%{data: %{count: 42}})
      ";; No tools available\\n\\n;; === data/ ===\\ndata/count                    ; integer, sample: 42"

      iex> PtcRunner.SubAgent.Namespace.render(%{memory: %{total: 100}, has_println: false})
      ";; No tools available\\n\\n;; === user/ (your prelude) ===\\ntotal                         ; = integer, sample: 100"
  """
  @spec render(map()) :: String.t()
  def render(config) do
    sample_opts = [
      sample_limit: config[:sample_limit] || 3,
      sample_printable_limit: config[:sample_printable_limit] || 80
    ]

    data_opts =
      [
        field_descriptions: config[:field_descriptions],
        context_signature: config[:context_signature]
      ] ++ sample_opts

    user_opts = [has_println: config[:has_println] || false] ++ sample_opts

    [
      Tool.render(config[:tools] || %{}),
      Data.render(config[:data] || %{}, data_opts),
      User.render(config[:memory] || %{}, user_opts)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      sections -> Enum.join(sections, "\n\n")
    end
  end
end
