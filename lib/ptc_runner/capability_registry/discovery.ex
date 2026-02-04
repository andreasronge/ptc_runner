defmodule PtcRunner.CapabilityRegistry.Discovery do
  @moduledoc """
  Multi-strategy search for tools and skills.

  Provides graceful degradation across three search strategies:

  1. **Exact tag matching** - Fast, precise, may miss synonyms
  2. **Fuzzy text matching** - Uses Jaro distance on name + description
  3. **Semantic search** - Embedding similarity (when available)

  ## Context-Aware Resolution

  When multiple implementations exist for a capability, resolution considers:

  - **Base success rate** - Overall historical performance
  - **Context affinity** - Success rate for tags matching the mission
  - **Failure penalties** - Known failure patterns in similar contexts

  """

  alias PtcRunner.CapabilityRegistry.{Registry, Skill}

  @type search_result :: %{
          id: String.t(),
          score: float(),
          match_type: :tag | :fuzzy | :semantic
        }

  @type search_opts :: [
          min_score: float(),
          limit: pos_integer(),
          context_tags: [String.t()],
          model_id: String.t()
        ]

  @doc """
  Searches for tools matching a query.

  Uses multi-strategy search: tags → fuzzy → semantic.

  ## Options

  - `:min_score` - Minimum match score (default: 0.3)
  - `:limit` - Maximum results (default: 10)
  - `:context_tags` - Context tags for affinity scoring

  ## Examples

      results = Discovery.search(registry, "parse csv", context_tags: ["european"])

  """
  @spec search(Registry.t(), String.t(), search_opts()) :: [search_result()]
  def search(registry, query, opts \\ []) do
    min_score = Keyword.get(opts, :min_score, 0.3)
    limit = Keyword.get(opts, :limit, 10)
    context_tags = Keyword.get(opts, :context_tags, [])

    query_tags = extract_tags(query)

    registry
    |> Registry.list_tools()
    |> Enum.map(fn tool ->
      {match_type, score} = calculate_tool_score(tool, query, query_tags)

      # Apply context affinity boost
      affinity = context_affinity(tool.context_success, context_tags)

      %{
        id: tool.id,
        score: score + affinity * 0.2,
        match_type: match_type,
        tool: tool
      }
    end)
    |> Enum.filter(&(&1.score >= min_score))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
    |> Enum.map(&Map.delete(&1, :tool))
  end

  @doc """
  Searches for skills matching context tags and/or tool associations.

  ## Options

  - `:tool_ids` - Find skills that apply to these tools
  - `:model_id` - Filter by model effectiveness
  - `:min_score` - Minimum effectiveness threshold (default: 0.5)

  """
  @spec search_skills(Registry.t(), [String.t()], search_opts()) :: [Skill.t()]
  def search_skills(registry, context_tags, opts \\ []) do
    tool_ids = Keyword.get(opts, :tool_ids, [])
    model_id = Keyword.get(opts, :model_id)
    min_score = Keyword.get(opts, :min_score, 0.5)

    registry
    |> Registry.list_skills()
    |> Enum.filter(fn skill ->
      # Include if matches any tool or any context tag
      matches_tools = tool_ids != [] and Skill.applies_to_any?(skill, tool_ids)
      matches_context = context_tags != [] and matches_any_tag?(skill.tags, context_tags)

      matches_tools or matches_context
    end)
    |> Enum.map(fn skill ->
      effectiveness = Skill.effectiveness_for_model(skill, model_id)
      {skill, effectiveness}
    end)
    |> Enum.filter(fn {_, effectiveness} -> effectiveness >= min_score end)
    |> Enum.sort_by(fn {_, effectiveness} -> effectiveness end, :desc)
    |> Enum.map(fn {skill, _} -> skill end)
  end

  @doc """
  Resolves the best implementation for a capability.

  Uses context-aware scoring to select the best tool from available
  implementations.

  ## Scoring Formula

      score = base_success_rate + context_affinity - failure_penalty

  """
  @spec resolve(Registry.t(), String.t(), [String.t()]) :: {:ok, String.t()} | :error
  def resolve(registry, capability_id, context_tags) do
    case Registry.get_capability(registry, capability_id) do
      nil ->
        :error

      capability when capability.implementations == [] ->
        :error

      capability ->
        best =
          capability.implementations
          |> Enum.map(fn impl_id ->
            case Registry.get_tool(registry, impl_id) do
              nil -> nil
              tool -> {impl_id, score_tool(registry, tool, context_tags)}
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.max_by(fn {_, score} -> score end, fn -> nil end)

        case best do
          nil -> :error
          {impl_id, _score} -> {:ok, impl_id}
        end
    end
  end

  @doc """
  Gets context-specific warnings for a set of tags.

  Returns warnings for tools that have low success rates in similar contexts.
  """
  @spec get_context_warnings(Registry.t(), [String.t()]) :: [
          %{tool_id: String.t(), warning: String.t()}
        ]
  def get_context_warnings(registry, context_tags) do
    registry
    |> Registry.list_tools()
    |> Enum.flat_map(fn tool ->
      context_tags
      |> Enum.filter(fn tag ->
        rate = Map.get(tool.context_success, tag, 1.0)
        rate < 0.3
      end)
      |> Enum.map(fn tag ->
        rate = Map.get(tool.context_success, tag, 1.0)

        %{
          tool_id: tool.id,
          warning: "Tool '#{tool.id}' has #{round(rate * 100)}% success rate for context '#{tag}'"
        }
      end)
    end)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Extract searchable tags from a query string
  defp extract_tags(query) do
    query
    |> String.downcase()
    |> String.split(~r/[\s,_-]+/)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.uniq()
  end

  # Calculate tool score using multi-strategy matching
  defp calculate_tool_score(tool, query, query_tags) do
    # Strategy 1: Tag matching
    tag_score = tag_overlap_score(tool.tags, query_tags)

    if tag_score > 0.5 do
      {:tag, tag_score}
    else
      # Strategy 2: Fuzzy matching on name + description
      fuzzy_score = fuzzy_match_score(tool, query)

      if fuzzy_score > tag_score do
        {:fuzzy, fuzzy_score}
      else
        {:tag, tag_score}
      end
    end
  end

  # Score based on tag overlap
  defp tag_overlap_score(tool_tags, query_tags) when tool_tags == [] or query_tags == [] do
    0.0
  end

  defp tag_overlap_score(tool_tags, query_tags) do
    tool_tags_lower = Enum.map(tool_tags, &String.downcase/1)

    matches = Enum.count(query_tags, &(&1 in tool_tags_lower))
    matches / max(length(query_tags), 1)
  end

  # Fuzzy match using Jaro distance
  defp fuzzy_match_score(tool, query) do
    query_lower = String.downcase(query)

    name_score = String.jaro_distance(String.downcase(tool.name || ""), query_lower)

    desc_score =
      case tool.description do
        nil ->
          0.0

        desc ->
          # Match against first 100 chars of description
          desc_start = desc |> String.slice(0, 100) |> String.downcase()
          String.jaro_distance(desc_start, query_lower)
      end

    max(name_score, desc_score * 0.8)
  end

  # Calculate context affinity score
  defp context_affinity(_context_success, []), do: 0.0

  defp context_affinity(context_success, context_tags) do
    scores =
      context_tags
      |> Enum.map(&Map.get(context_success, &1, 0.5))

    Enum.sum(scores) / length(context_tags)
  end

  # Score a tool for resolution
  defp score_tool(registry, tool, context_tags) do
    # Check health - unhealthy tools get heavy penalty
    health_penalty =
      case Registry.get_health(registry, tool.id) do
        :green -> 0.0
        :pending -> 0.1
        :flaky -> 0.3
        :red -> 0.8
        nil -> 0.0
      end

    # Base score from success rate
    base = tool.success_rate

    # Context affinity boost
    affinity = context_affinity(tool.context_success, context_tags)

    # Failure penalty for low context success
    failure_penalty =
      context_tags
      |> Enum.count(fn tag ->
        Map.get(tool.context_success, tag, 1.0) < 0.3
      end)
      |> Kernel.*(0.2)

    base + affinity - failure_penalty - health_penalty
  end

  defp matches_any_tag?(skill_tags, context_tags) do
    skill_tags_lower = Enum.map(skill_tags, &String.downcase/1)
    context_lower = Enum.map(context_tags, &String.downcase/1)
    Enum.any?(context_lower, &(&1 in skill_tags_lower))
  end
end
