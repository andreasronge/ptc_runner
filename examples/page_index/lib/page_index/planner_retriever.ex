defmodule PageIndex.PlannerRetriever do
  @moduledoc """
  MetaPlanner-based retrieval for complex multi-hop questions.

  Uses PlanExecutor to:
  1. Decompose question into subtasks (fetch specific data points)
  2. Verify each fetch returned valid data
  3. Replan if verification fails
  4. Synthesize final answer from collected data
  """

  alias PageIndex.DocumentTools
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
    strategy = Keyword.get(opts, :strategy)

    # Pre-warm the PDF cache before starting planner execution
    # This avoids timeout issues when the sandbox tries to extract pages
    IO.puts("Pre-loading PDF pages...")
    {:ok, _} = PageIndex.get_content(pdf_path, 1, 1)
    IO.puts("PDF cache ready.")

    nodes = DocumentTools.flatten_tree(tree)
    sections_summary = DocumentTools.format_sections(nodes)
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

    computational_instructions =
      if strategy == :computational do
        """

        PCE (Plan-Code-Execute) MODE:
        For all computation, comparison, or data transformation tasks:
        - Use `agent: "direct"`
        - Write valid PTC-Lisp code directly in the `input` field.
        - Upstream results are available via `data/results` in the Lisp environment
          (e.g., `(get data/results "task_id")` to get a task's output map).
        - Use standard Lisp functions: `+`, `-`, `*`, `/`, `get`, `map`, `filter`, `reduce`.
        - Do not guess; perform calculations on the exact numbers extracted by upstream tasks.
        """
      else
        ""
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
       computation task between the fetches and the final synthesis.
    4. Create a synthesis_gate task that produces the final answer from upstream results
    #{computational_instructions}
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
            {"id": "fetch_data", "agent": "document_analyst", "input": "Fetch section 'section_id' and extract: metric names and values", "signature": "{metrics [{name :string, value :float}]}", "on_failure": "replan"},
            {"id": "final_answer", "agent": "synthesizer", "input": "Answer the question using the extracted data", "depends_on": ["fetch_data"], "type": "synthesis_gate"}
          ]
        }
        """
      else
        ""
      end

    pce_example =
      if strategy == :computational do
        """
        Example of a computational task using agent: "direct":
        {
          "id": "calc_change",
          "agent": "direct",
          "input": "(let [d (get data/results \\"fetch_data\\") val_current (get d \\"value_current\\") val_previous (get d \\"value_previous\\")] (* (/ (- val_current val_previous) val_previous) 100))",
          "depends_on": ["fetch_data"],
          "signature": "{change_pct :float}"
        }
        """
      else
        ""
      end

    constraints = """
    CRITICAL: You MUST generate a plan with BOTH "agents" AND "tasks" keys.

    CRITICAL: The final synthesis task MUST have the id "final_answer".
    #{pce_example}

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
          "prompt": "You are a data extraction agent. Focus on the section specified in your task input. For large sections, use grep_section first to locate keywords, then fetch_section at the returned offset. If your first grep pattern returns no matches, try a broader keyword (e.g., if a specific term fails, try a shorter keyword). When a fetch result has truncated: true, call fetch_section again with the offset from the hint. Do not guess data from partial tables — paginate until you find what you need. If the specified section does not contain the requested data after thorough search, call (fail) with details rather than searching other sections — the planner will redirect you. Return a consolidated set of findings with page numbers for provenance.",
          "tools": ["fetch_section", "grep_section"]
        },
        "synthesizer": {
          "prompt": "You produce clear answers from structured data provided by upstream tasks."
        }
      },
      "tasks": [
        {"id": "fetch_data", "agent": "document_analyst", "input": "Fetch section 'target_section_id' and extract: metric names, current and prior period values, and growth rates. Include page numbers.", "signature": "{items [{name :string, value_current :float, value_previous :float, growth_pct :float, page :int}]}"},
        {"id": "final_answer", "agent": "synthesizer", "input": "Answer the question using the extracted data", "depends_on": ["fetch_data"], "type": "synthesis_gate"}
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
      "fetch_section" => DocumentTools.make_fetch_tool(nodes, pdf_path),
      "grep_section" => DocumentTools.make_grep_tool(nodes, pdf_path)
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

  defp find_synthesis_result(results) do
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
end
