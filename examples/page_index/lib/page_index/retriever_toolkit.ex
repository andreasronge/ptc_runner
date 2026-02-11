defmodule PageIndex.RetrieverToolkit do
  @moduledoc """
  Shared helpers for document retrieval strategies.

  Provides common utilities used by PlanRetriever: tree flattening,
  smart fetch with fuzzy matching, section formatting, and result extraction.
  """

  alias PtcRunner.SubAgent

  @doc """
  Flatten a hierarchical tree into a list of leaf node maps.

  Returns nodes with `:node_id`, `:title`, `:summary`, `:start_page`, `:end_page`.
  Only includes nodes that have a `start_page` (i.e., actual content sections).
  """
  def flatten_tree(tree, acc \\ []) do
    children = Map.get(tree, :children, [])

    node = %{
      node_id: tree.node_id,
      title: tree.title,
      summary: tree.summary,
      start_page: Map.get(tree, :start_page),
      end_page: Map.get(tree, :end_page)
    }

    acc = if node.start_page, do: [node | acc], else: acc

    Enum.reduce(children, acc, fn child, acc ->
      flatten_tree(child, acc)
    end)
  end

  @doc """
  Build a smart fetch tool function with fuzzy matching and pagination.

  Returns a function suitable for use as a PTC tool. The function:
  - Tries exact match on `node_id` first
  - Falls back to fuzzy matching by word overlap
  - Returns 5000-char chunks with pagination hints
  - Suggests similar sections on miss
  """
  def make_smart_fetch_tool(nodes, pdf_path) do
    fn args ->
      query = args["node_id"] || args[:node_id] || ""
      offset = args["offset"] || args[:offset] || 0

      offset =
        if is_binary(offset),
          do: offset |> String.replace(",", "") |> String.to_integer(),
          else: offset

      # First try exact match
      node = Enum.find(nodes, fn n -> n.node_id == query end)

      # If no exact match, try fuzzy matching on title and node_id
      node = node || find_best_match(nodes, query)

      if node do
        case PageIndex.get_content(pdf_path, node.start_page, node.end_page) do
          {:ok, full_content} ->
            total_chars = String.length(full_content)
            sliced = String.slice(full_content, offset, 5000)
            returned_chars = String.length(sliced)
            end_offset = offset + returned_chars
            truncated = end_offset < total_chars

            result = %{
              "node_id" => node.node_id,
              "title" => node.title,
              "pages" => "#{node.start_page}-#{node.end_page}",
              "content" => sliced,
              "total_chars" => total_chars,
              "offset" => offset,
              "truncated" => truncated
            }

            if truncated do
              Map.put(
                result,
                "hint",
                "Content truncated. Use fetch_section with offset: #{end_offset} to get more."
              )
            else
              result
            end

          {:error, reason} ->
            %{"error" => inspect(reason)}
        end
      else
        suggestions = suggest_sections(nodes, query)
        %{"error" => "No match for '#{query}'. Try: #{suggestions}"}
      end
    end
  end

  @doc "Find the best fuzzy match for a query among nodes by word overlap."
  def find_best_match(nodes, query) do
    query_lower = String.downcase(query)
    query_words = String.split(query_lower, ~r/[\s_]+/)

    nodes
    |> Enum.map(fn node ->
      title_lower = String.downcase(node.title)
      id_lower = String.downcase(node.node_id)

      score =
        Enum.count(query_words, fn word ->
          String.contains?(title_lower, word) or String.contains?(id_lower, word)
        end)

      {node, score}
    end)
    |> Enum.filter(fn {_, score} -> score > 0 end)
    |> Enum.sort_by(fn {_, score} -> -score end)
    |> List.first()
    |> case do
      {node, _score} -> node
      nil -> nil
    end
  end

  @doc "Suggest similar section IDs based on partial query match."
  def suggest_sections(nodes, query) do
    query_lower = String.downcase(query)

    nodes
    |> Enum.filter(fn n ->
      String.contains?(String.downcase(n.title), query_lower) or
        String.contains?(String.downcase(n.node_id), query_lower)
    end)
    |> Enum.take(3)
    |> Enum.map(& &1.node_id)
    |> Enum.join(", ")
    |> case do
      "" -> nodes |> Enum.take(5) |> Enum.map(& &1.node_id) |> Enum.join(", ")
      suggestions -> suggestions
    end
  end

  @doc "Format nodes as summary lines for planner/LLM consumption."
  def format_sections(nodes) do
    nodes
    |> Enum.map(fn n ->
      summary = String.slice(n.summary || "", 0, 80)
      "#{n.node_id}: #{n.title} (p.#{n.start_page}-#{n.end_page}) - #{summary}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Build a search SubAgentTool that wraps the extraction agent.

  The returned tool accepts a single `query` parameter and spawns a multi-turn
  child agent that navigates the section catalog, fetches content, and returns
  structured findings.

  ## Options

  - `:llm` - Optional LLM override for the search agent (inherits from parent by default)
  """
  def make_search_tool(nodes, pdf_path, opts \\ []) do
    sections_summary = format_sections(nodes)
    fetch_tool = make_smart_fetch_tool(nodes, pdf_path)

    agent =
      SubAgent.new(
        prompt: """
        Extract structured data from a document to answer a query.

        QUERY: {{query}}

        AVAILABLE SECTIONS:
        #{sections_summary}

        INSTRUCTIONS:
        1. Identify 1-2 sections most likely to contain the data from the list above
        2. Fetch and grep to find the specific data point:
           (def section (tool/fetch_section {:node_id "section_id"}))
           (tool/grep-n {:pattern "keyword" :text (:content section)})
        3. If truncated, paginate: (tool/fetch_section {:node_id "id" :offset N})
        4. Before returning, verify you have found a concrete value that answers the query.
           If your search result is empty or ambiguous, try a different section or search pattern.
        5. Structure each finding as:
           {label value unit page section context}
           Use raw numeric values (34500 not "34,500"). Note scale from table headers.
        6. If no relevant data found after checking 2-3 sections, use (fail "reason")
        """,
        signature:
          "(query :string) -> {findings [{label :string, value :any, unit :string, page :any, section :string, context :string}], sections_searched [:string]}",
        tools: %{
          "fetch_section" =>
            {fetch_tool,
             signature:
               "(node_id :string, offset :int) -> {node_id :string, title :string, pages :string, content :string, total_chars :int, offset :int, truncated :bool, hint :string}",
             description:
               "Fetch content from a document section by ID. Use offset for pagination when truncated is true."}
        },
        builtin_tools: [:grep],
        max_turns: 6,
        timeout: 60_000,
        description:
          "Search the document for specific data. Returns structured findings with values, units, page numbers, and source sections."
      )

    SubAgent.as_tool(agent, opts)
  end

  @doc "Extract the final answer from plan execution results."
  def find_synthesis_result(results) do
    # Primary: use the designated target task ID from the prompt constraints
    # Fallback: pick the result that is NOT a raw fetch (no "content"+"node_id" keys)
    # Last resort: return something rather than nil
    Map.get(results, "final_answer") ||
      Enum.find_value(results, fn {_task_id, r} ->
        if is_map(r) and not (Map.has_key?(r, "content") and Map.has_key?(r, "node_id")) do
          r
        end
      end) ||
      results |> Enum.sort_by(fn {id, _} -> id end) |> List.last() |> elem(1)
  end

  @doc "Extract source references from search tool findings in plan results."
  def extract_search_sources(results) do
    results
    |> Enum.flat_map(fn {_task_id, result} ->
      case result do
        %{"findings" => findings} when is_list(findings) ->
          Enum.map(findings, fn f ->
            %{section: f["section"], page: f["page"]}
          end)

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end
end
