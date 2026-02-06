defmodule PageIndex.PlannerRetriever do
  @moduledoc """
  MetaPlanner-based retrieval for complex multi-hop questions.

  Uses PlanExecutor to:
  1. Decompose question into subtasks (fetch specific data points)
  2. Verify each fetch returned valid data
  3. Replan if verification fails
  4. Synthesize final answer from collected data
  """

  alias PtcRunner.PlanExecutor

  @doc """
  Retrieves using MetaPlanner for complex questions requiring multi-hop reasoning.

  The planner will:
  - Identify what data points are needed
  - Create tasks to fetch each from the document
  - Verify results contain the expected information
  - Run quality gate before synthesis to check data sufficiency (if enabled)
  - Synthesize the final answer

  ## Options

  - `:llm` - Required. LLM callback
  - `:pdf_path` - Required. Path to the PDF file
  - `:max_replans` - Max replan attempts (default: 2)
  - `:quality_gate` - Enable pre-flight data sufficiency check (default: false)
  - `:quality_gate_llm` - Optional separate LLM for quality gate
  - `:on_event` - Optional event callback
  """
  def retrieve(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    pdf_path = Keyword.fetch!(opts, :pdf_path)
    max_replans = Keyword.get(opts, :max_replans, 2)
    on_event = Keyword.get(opts, :on_event)
    quality_gate = Keyword.get(opts, :quality_gate, false)
    quality_gate_llm = Keyword.get(opts, :quality_gate_llm)

    # Pre-warm the PDF cache before starting planner execution
    # This avoids timeout issues when the sandbox tries to extract pages
    IO.puts("Pre-loading PDF pages...")
    {:ok, _} = PageIndex.get_content(pdf_path, 1, 1)
    IO.puts("PDF cache ready.")

    nodes = flatten_tree(tree)
    sections_summary = format_sections_for_planner(nodes)
    doc_title = tree.title || "Document"

    mission = """
    Answer this question about "#{doc_title}":

    QUESTION: #{query}

    DOCUMENT SECTIONS (use fetch_section tool to get content):
    #{sections_summary}

    INSTRUCTIONS:
    1. First, work backwards from the question: what specific data, computations, or comparisons
       are needed to produce a well-supported answer?
    2. Create "fetcher" tasks to retrieve only the sections that contain required data points
    3. If the answer requires computation (ratios, comparisons, derived values), create a dedicated
       computation task (agent with no tools) between the fetches and the final synthesis.
       Give it a precise signature with the computed values.
    4. Create a synthesis_gate task that produces the final answer from upstream results
    5. Include verification predicates to ensure data was found
    """

    constraints = """
    CRITICAL: You MUST generate a plan with BOTH "agents" AND "tasks" keys.

    CRITICAL: The final synthesis task MUST have the id "final_answer".

    For fetching document sections, use `agent: "direct"` with PTC-Lisp tool calls.
    You know the exact section IDs from the document sections list above, so there is
    no need for an LLM agent to figure them out. Example:
    {"id": "fetch_balance_sheet", "agent": "direct", "input": "(tool/fetch_section {:node_id \"financial_state_consolidated_balance_sheet_at_\"})"}

    You may define additional agents with no tools for computation, analysis, or synthesis.
    Give each agent a clear prompt describing its role.

    You MUST generate at least one task in the "tasks" array. Example structure:
    {
      "agents": {"analyzer": {...}},
      "tasks": [
        {"id": "fetch_data", "agent": "direct", "input": "(tool/fetch_section {:node_id \"section_id\"})"},
        {"id": "final_answer", "agent": "analyzer", "input": "...", "depends_on": ["fetch_data"], "type": "synthesis_gate"}
      ]
    }

    DO NOT return a plan with an empty tasks array or missing tasks key.
    """

    # Tool description lists all available section IDs for the planner
    all_section_ids =
      nodes
      |> Enum.map(& &1.node_id)
      |> Enum.join(", ")

    available_tools = %{
      "fetch_section" => """
      Fetch content from a document section by ID or search term.
      Input: {node_id: string} - The section ID or search term
      Output: {node_id: string, title: string, pages: string, content: string}

      Available sections: #{all_section_ids}

      Use the section summaries in the mission to choose which section(s) to fetch.
      The tool also supports fuzzy matching on titles if an exact ID isn't known.
      """
    }

    # Actual tool implementation with fuzzy matching
    base_tools = %{
      "fetch_section" => make_smart_fetch_tool(nodes, pdf_path)
    }

    executor_opts =
      [
        llm: llm,
        available_tools: available_tools,
        base_tools: base_tools,
        max_total_replans: max_replans,
        max_turns: 10,
        constraints: constraints,
        quality_gate: quality_gate
      ]
      |> then(fn opts ->
        if on_event, do: Keyword.put(opts, :on_event, on_event), else: opts
      end)
      |> then(fn opts ->
        if quality_gate_llm,
          do: Keyword.put(opts, :quality_gate_llm, quality_gate_llm),
          else: opts
      end)

    case PlanExecutor.run(mission, executor_opts) do
      {:ok, results, metadata} ->
        # Extract final answer from synthesis task
        final_result = find_synthesis_result(results)

        {:ok,
         %{
           answer:
             final_result["answer"] || final_result["assessment"] || final_result["analysis"] ||
               final_result,
           sources: extract_sources(results),
           replans: metadata.replan_count,
           tasks_executed: map_size(results)
         }}

      {:error, reason, metadata} ->
        {:error,
         %{
           reason: reason,
           replans: metadata.replan_count,
           partial_results: metadata
         }}
    end
  end

  defp make_smart_fetch_tool(nodes, pdf_path) do
    fn args ->
      query = args["node_id"] || args[:node_id] || ""

      # First try exact match
      node = Enum.find(nodes, fn n -> n.node_id == query end)

      # If no exact match, try fuzzy matching on title and node_id
      node = node || find_best_match(nodes, query)

      if node do
        case PageIndex.get_content(pdf_path, node.start_page, node.end_page) do
          {:ok, content} ->
            content =
              if String.length(content) > 5000 do
                String.slice(content, 0, 5000) <> "\n[truncated]"
              else
                content
              end

            %{
              "node_id" => node.node_id,
              "title" => node.title,
              "pages" => "#{node.start_page}-#{node.end_page}",
              "content" => content
            }

          {:error, reason} ->
            %{"error" => inspect(reason)}
        end
      else
        # Return suggestions
        suggestions = suggest_sections(nodes, query)
        %{"error" => "No match for '#{query}'. Try: #{suggestions}"}
      end
    end
  end

  defp find_best_match(nodes, query) do
    query_lower = String.downcase(query)
    query_words = String.split(query_lower, ~r/[\s_]+/)

    # Score each node based on word matches in title and node_id
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

  defp suggest_sections(nodes, query) do
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

  defp find_synthesis_result(results) do
    # Primary: use the designated target task ID from the prompt constraints
    # Fallback: pick the result that is NOT a raw fetch (no "content"+"node_id" keys),
    # since fetch results always have that shape and synthesis results don't.
    # Last resort: return something rather than nil
    Map.get(results, "final_answer") ||
      Enum.find_value(results, fn {_task_id, r} ->
        if is_map(r) and not (Map.has_key?(r, "content") and Map.has_key?(r, "node_id")) do
          r
        end
      end) ||
      results |> Enum.sort_by(fn {id, _} -> id end) |> List.last() |> elem(1)
  end

  defp extract_sources(results) do
    results
    |> Enum.flat_map(fn {_task_id, result} ->
      case result do
        %{"node_id" => id, "pages" => pages} -> [%{node_id: id, pages: pages}]
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1.node_id)
  end

  defp flatten_tree(tree, acc \\ []) do
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

  defp format_sections_for_planner(nodes) do
    nodes
    |> Enum.map(fn n ->
      summary = String.slice(n.summary || "", 0, 80)
      "#{n.node_id}: #{n.title} (p.#{n.start_page}-#{n.end_page}) - #{summary}"
    end)
    |> Enum.join("\n")
  end
end
