defmodule PtcRunnerMcp.PromptRegistry do
  @moduledoc false

  alias PtcRunner.PtcToolProtocol

  @common_card %{
    audience: :mcp_tool_description,
    budget_profile: :compact,
    surface: :mcp_direct_ptc_lisp_execute
  }

  @authoring_card_path Path.expand(
                         Path.join([__DIR__, "..", "..", "priv", "mcp_authoring_card.md"])
                       )
  @external_resource @authoring_card_path
  @authoring_card File.read!(@authoring_card_path)

  @aggregator_authoring_card_path Path.expand(
                                    Path.join([
                                      __DIR__,
                                      "..",
                                      "..",
                                      "priv",
                                      "mcp_aggregator_authoring_card.md"
                                    ])
                                  )
  @external_resource @aggregator_authoring_card_path
  @aggregator_authoring_card File.read!(@aggregator_authoring_card_path)

  @cards %{
    mcp_no_tools_capability:
      Map.merge(@common_card, %{
        id: :mcp_no_tools_capability,
        dimensions: [:execution_surface, :completion_contract],
        dynamic_boundary: :static_card,
        placement: :quick_contract,
        profile: :mcp_no_tools,
        prompt_fun: :mcp_no_tools_capability,
        trust: :authoritative
      }),
    mcp_no_tools_authoring_card:
      Map.merge(@common_card, %{
        id: :mcp_no_tools_authoring_card,
        dimensions: [:dialect, :completion_contract, :trust_boundary],
        dynamic_boundary: :static_card,
        placement: :after_quick_contract,
        profile: :mcp_no_tools,
        prompt_fun: :mcp_no_tools_authoring_card,
        trust: :authoritative
      }),
    mcp_aggregator_quick_contract:
      Map.merge(@common_card, %{
        id: :mcp_aggregator_quick_contract,
        dimensions: [:execution_surface, :completion_contract, :catalog_discovery],
        dynamic_boundary: :before_dynamic_catalog,
        placement: :quick_contract,
        profile: :mcp_aggregator,
        prompt_fun: :mcp_aggregator_quick_contract,
        trust: :authoritative
      }),
    mcp_aggregator_authoring_card:
      Map.merge(@common_card, %{
        id: :mcp_aggregator_authoring_card,
        dimensions: [:dialect, :execution_surface, :completion_contract, :trust_boundary],
        dynamic_boundary: :before_dynamic_catalog,
        placement: :after_quick_contract,
        profile: :mcp_aggregator,
        prompt_fun: :mcp_aggregator_authoring_card,
        trust: :authoritative
      }),
    mcp_dynamic_catalog:
      Map.merge(@common_card, %{
        audience: :mcp_tool_description,
        budget_profile: :compact,
        id: :mcp_dynamic_catalog,
        dimensions: [:catalog_discovery],
        dynamic_boundary: :dynamic_catalog,
        placement: :after_authoritative_cards,
        profile: :mcp_aggregator,
        trust: :untrusted_data
      })
  }

  @profiles %{
    mcp_no_tools_description: [
      :mcp_no_tools_capability,
      :mcp_no_tools_authoring_card
    ],
    mcp_aggregator_description: [
      :mcp_aggregator_quick_contract,
      :mcp_aggregator_authoring_card,
      :mcp_dynamic_catalog
    ]
  }

  @doc false
  @spec render(atom(), keyword()) :: String.t() | nil
  def render(:mcp_no_tools_description, _opts) do
    render_parts(profile_parts!(:mcp_no_tools_description))
  end

  def render(:mcp_aggregator_description, opts) do
    catalog = Keyword.get(opts, :catalog)

    :mcp_aggregator_description
    |> profile_parts!()
    |> Enum.flat_map(fn
      :mcp_dynamic_catalog -> dynamic_catalog_part(catalog)
      card -> [render_card(card)]
    end)
    |> Enum.join("\n\n")
  end

  def render(key, _opts) when is_atom(key), do: render_card_or_nil(key)

  @doc false
  @spec card_text(atom()) :: String.t() | nil
  def card_text(key) when is_atom(key), do: render_card_or_nil(key)

  @doc false
  @spec card_metadata(atom()) :: map() | nil
  def card_metadata(key) when is_atom(key) do
    case Map.get(@cards, key) do
      nil -> nil
      card -> Map.delete(card, :prompt_fun)
    end
  end

  @doc false
  @spec profile_metadata(atom()) :: [map()] | nil
  def profile_metadata(key) when is_atom(key) do
    case Map.get(@profiles, key) do
      nil -> nil
      parts -> Enum.map(parts, &card_metadata/1)
    end
  end

  @doc false
  @spec profile_parts!(atom()) :: [atom()]
  def profile_parts!(key) when is_atom(key), do: Map.fetch!(@profiles, key)

  defp render_parts(parts), do: Enum.map_join(parts, "\n\n", &render_card/1)

  defp render_card_or_nil(key) do
    if Map.has_key?(@cards, key), do: render_card(key)
  end

  defp render_card(:mcp_no_tools_capability), do: PtcToolProtocol.tool_description(:mcp_no_tools)
  defp render_card(:mcp_no_tools_authoring_card), do: @authoring_card
  defp render_card(:mcp_aggregator_quick_contract), do: mcp_aggregator_quick_contract()
  defp render_card(:mcp_aggregator_authoring_card), do: @aggregator_authoring_card

  defp render_card(key) do
    raise ArgumentError, "unknown MCP prompt card: #{inspect(key)}"
  end

  defp dynamic_catalog_part(nil), do: []
  defp dynamic_catalog_part(""), do: []
  defp dynamic_catalog_part(catalog) when is_binary(catalog), do: [catalog]

  defp mcp_aggregator_quick_contract do
    """
    Execute a PTC-Lisp program in PtcRunner's sandbox for deterministic computation, filtering, aggregation, and orchestration over configured upstream MCP servers.

    Quick aggregator contract:
    - Call upstream tools inside the program as `(tool/mcp-call {:server "<name>" :tool "<tool>" :args {...}})`.
    - World-fault failures such as timeout, oversize, upstream error, cap exhaustion, or unavailable upstream return `nil` and are recorded in `upstream_calls`.
    - A successful top-level JSON `null` returns `:json-null`, not `nil`.
    - Unwrap upstream MCP envelopes with `(mcp/text r)` for text and `(mcp/json r)` for structured JSON.
    - Use `catalog/search-tools`, `catalog/list-tools`, or `catalog/describe-tool` when catalog details are not inline or a schema is unfamiliar.
    - Return compact maps, vectors, or strings; do not return full upstream envelopes unless the caller asked for them.

    Each invocation of `ptc_lisp_execute` is independent; there is no memory of prior calls.
    """
    |> String.trim()
  end
end
