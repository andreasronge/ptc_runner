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
  - `:self_failure` - Enable rich self-failure via `(fail)` + `on_failure: "replan"` (default: false)
  - `:on_event` - Optional event callback
  """
  def retrieve(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    pdf_path = Keyword.fetch!(opts, :pdf_path)
    max_replans = Keyword.get(opts, :max_replans, 2)
    on_event = Keyword.get(opts, :on_event)
    quality_gate = Keyword.get(opts, :quality_gate, false)
    quality_gate_llm = Keyword.get(opts, :quality_gate_llm)
    self_failure = Keyword.get(opts, :self_failure, false)

    # Pre-warm the PDF cache before starting planner execution
    # This avoids timeout issues when the sandbox tries to extract pages
    IO.puts("Pre-loading PDF pages...")
    {:ok, _} = PageIndex.get_content(pdf_path, 1, 1)
    IO.puts("PDF cache ready.")

    nodes = flatten_tree(tree)
    sections_summary = format_sections_for_planner(nodes)
    doc_title = tree.title || "Document"

    self_failure_instruction =
      if self_failure do
        """
        5. For agents that analyze or compute from fetched data, include this instruction in the
           agent prompt: "If the fetched sections do not contain the specific data you need,
           call (fail \\"reason\\") with a detailed explanation — describe what you found, what is
           missing, and if you noticed a reference to where the data might actually be (e.g.
           'See Note 12'), include that as a hint."
           Set "on_failure": "replan" on these tasks so the planner can try a different approach.
        """
      else
        "5. Include verification predicates to ensure data was found\n"
      end

    mission = """
    Answer this question about "#{doc_title}":

    QUESTION: #{query}

    DOCUMENT SECTIONS (use fetch_section tool to get content):
    #{sections_summary}

    INSTRUCTIONS:
    1. First, work backwards from the question: what specific data, computations, or comparisons
       are needed to produce a well-supported answer?
    2. Create document_analyst tasks to retrieve AND EXTRACT structured data from sections.
       Each task specifies what data to extract and a signature for its output.
    3. If the answer requires computation (ratios, comparisons, derived values), create a dedicated
       computation task (agent with no tools) between the fetches and the final synthesis.
       Give it a precise signature with the computed values.
    4. Create a synthesis_gate task that produces the final answer from upstream results
    #{self_failure_instruction}\
    """

    self_failure_constraints =
      if self_failure do
        """

        For document_analyst tasks that extract data, set "on_failure": "replan" so the planner
        can try a different section or approach if the data is not found. Example:

        {
          "agents": {
            "document_analyst": {
              "prompt": "You are a data extraction agent. For large sections, use grep_section first to locate keywords, then fetch_section at the returned offset. If your first grep pattern returns no matches, try a broader keyword. When a fetch result has truncated: true, call fetch_section again with the offset from the hint. If the fetched sections do not contain the specific data you need, call (fail \\"reason\\") with a detailed explanation — describe what you found, what is missing, and any hints about where to find it.",
              "tools": ["fetch_section", "grep_section"]
            },
            "synthesizer": {"prompt": "You produce clear answers from structured data provided by upstream tasks."}
          },
          "tasks": [
            {"id": "fetch_segment_data", "agent": "document_analyst", "input": "Fetch section 'section_id' and extract: metric names and values", "signature": "{metrics [{name :string, value :float}]}", "on_failure": "replan"},
            {"id": "final_answer", "agent": "synthesizer", "input": "Answer the question using the extracted data", "depends_on": ["fetch_segment_data"], "type": "synthesis_gate"}
          ]
        }
        """
      else
        ""
      end

    constraints = """
    CRITICAL: You MUST generate a plan with BOTH "agents" AND "tasks" keys.

    CRITICAL: The final synthesis task MUST have the id "final_answer".

    For fetching and extracting data from document sections, define a single "document_analyst"
    agent with tools: ["fetch_section", "grep_section"]. Reuse this agent for all data-gathering tasks.

    Each fetch task must:
    - Specify WHAT DATA to extract in its input (not just which section to fetch)
    - Include a signature describing the structured output

    The document_analyst will fetch the section, paginate if content is truncated, and return
    only the extracted structured data. Downstream tasks receive clean findings, not raw text.

    DO NOT use agent: "direct" for section fetches.
    Multiple tasks can use the same document_analyst agent — it is invoked fresh for each task
    with that specific task's input. Do not create separate analyst_1, analyst_2, etc.

    You may define additional agents with no tools for computation, analysis, or synthesis.
    Give each agent a clear prompt describing its role.

    You MUST generate at least one task in the "tasks" array. Example structure:
    {
      "agents": {
        "document_analyst": {
          "prompt": "You are a data extraction agent. Focus on the section specified in your task input. For large sections, use grep_section first to locate keywords, then fetch_section at the returned offset. If your first grep pattern returns no matches, try a broader keyword (e.g., if 'Organic Growth %' fails, try 'Organic'). When a fetch result has truncated: true, call fetch_section again with the offset from the hint. Do not guess data from partial tables — paginate until you find what you need. If the specified section does not contain the requested data after thorough search, call (fail) with details rather than searching other sections — the planner will redirect you. Return a consolidated set of findings with page numbers for provenance.",
          "tools": ["fetch_section", "grep_section"]
        },
        "synthesizer": {
          "prompt": "You produce clear answers from structured data provided by upstream tasks."
        }
      },
      "tasks": [
        {"id": "fetch_segment_data", "agent": "document_analyst", "input": "Fetch section 'management_s_di_performance_by_business_segmen' and extract: segment names, 2022 and 2021 revenue, organic growth rates excluding M&A, and FX impact for each segment. Include page numbers.", "signature": "{segments [{name :string, revenue_2022 :float, revenue_2021 :float, organic_growth_pct :float, fx_impact_pct :float, page :int}]}"},
        {"id": "final_answer", "agent": "synthesizer", "input": "Answer the question using the extracted data", "depends_on": ["fetch_segment_data"], "type": "synthesis_gate"}
      ]
    }

    DO NOT return a plan with an empty tasks array or missing tasks key.
    #{self_failure_constraints}\
    """

    # Tool description lists all available section IDs for the planner
    all_section_ids =
      nodes
      |> Enum.map(& &1.node_id)
      |> Enum.join(", ")

    available_tools = %{
      "fetch_section" => """
      Fetch content from a document section by ID or search term.
      Input: {node_id: string, offset: int (optional, default 0)}
      Output: {node_id, title, pages, content, total_chars, offset, truncated, hint?}

      Content is returned in 5000-char chunks. When truncated is true, the hint field
      contains the exact call with offset to get the next chunk.

      Available sections: #{all_section_ids}
      """,
      "grep_section" => """
      Search a section's full content for a keyword or phrase. Returns up to 5 matches
      with offsets and surrounding context. Use BEFORE fetch_section on large sections
      to jump to the right location.
      Input: {node_id: string, pattern: string}
      Output: {node_id, total_chars, pattern, matches: [{offset, context, hint}]}

      Available sections: #{all_section_ids}
      """
    }

    # Actual tool implementation with fuzzy matching
    base_tools = %{
      "fetch_section" => make_smart_fetch_tool(nodes, pdf_path),
      "grep_section" => make_grep_tool(nodes, pdf_path)
    }

    executor_opts =
      [
        llm: llm,
        available_tools: available_tools,
        base_tools: base_tools,
        max_total_replans: max_replans,
        max_turns: 20,
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
        # Return suggestions
        suggestions = suggest_sections(nodes, query)
        %{"error" => "No match for '#{query}'. Try: #{suggestions}"}
      end
    end
  end

  defp make_grep_tool(nodes, pdf_path) do
    fn args ->
      query = args["node_id"] || args[:node_id] || ""
      pattern = args["pattern"] || args[:pattern] || ""

      node = Enum.find(nodes, fn n -> n.node_id == query end)
      node = node || find_best_match(nodes, query)

      if node do
        case PageIndex.get_content(pdf_path, node.start_page, node.end_page) do
          {:ok, content} ->
            matches = find_pattern_matches(content, pattern)

            %{
              "node_id" => node.node_id,
              "total_chars" => String.length(content),
              "pattern" => pattern,
              "matches" => Enum.take(matches, 5)
            }

          {:error, reason} ->
            %{"error" => inspect(reason)}
        end
      else
        suggestions = suggest_sections(nodes, query)
        %{"error" => "No match for '#{query}'. Try: #{suggestions}"}
      end
    end
  end

  defp find_pattern_matches(content, pattern) do
    content_lower = String.downcase(content)

    # Support pipe-delimited OR patterns (e.g., "Revenue|Sales")
    # and regex patterns (containing .* or other regex metacharacters)
    if String.contains?(pattern, "|") or String.contains?(pattern, ".*") do
      find_regex_matches(content, content_lower, pattern)
    else
      pattern_lower = String.downcase(pattern)
      find_all_positions(content, content_lower, pattern_lower, 0, [])
    end
  end

  defp find_regex_matches(content, content_lower, pattern) do
    case Regex.compile(String.downcase(pattern), "i") do
      {:ok, regex} ->
        Regex.scan(regex, content_lower, return: :index)
        |> Enum.map(fn [{pos, _len} | _] ->
          ctx_start = max(0, pos - 40)
          ctx = String.slice(content, ctx_start, 120)

          %{
            "offset" => pos,
            "context" => ctx,
            "hint" =>
              "Use fetch_section with offset: #{max(0, pos - 200)} to read around this match."
          }
        end)

      {:error, _} ->
        # Fall back to literal match if regex is invalid
        find_all_positions(content, content_lower, String.downcase(pattern), 0, [])
    end
  end

  defp find_all_positions(_content, content_lower, _pattern, start, acc)
       when start >= byte_size(content_lower) do
    Enum.reverse(acc)
  end

  defp find_all_positions(content, content_lower, pattern, start, acc) do
    case :binary.match(content_lower, pattern, scope: {start, byte_size(content_lower) - start}) do
      {pos, _len} ->
        ctx_start = max(0, pos - 40)
        ctx = String.slice(content, ctx_start, 120)

        match = %{
          "offset" => pos,
          "context" => ctx,
          "hint" =>
            "Use fetch_section with offset: #{max(0, pos - 200)} to read around this match."
        }

        find_all_positions(content, content_lower, pattern, pos + 1, [match | acc])

      :nomatch ->
        Enum.reverse(acc)
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
