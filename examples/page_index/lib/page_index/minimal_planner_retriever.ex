defmodule PageIndex.MinimalPlannerRetriever do
  @moduledoc """
  Constraint-free MetaPlanner retrieval that relies on a high-level search SubAgentTool.

  Unlike `PlannerRetriever`, this module does NOT prescribe agent names, prompts,
  topology, or domain-specific examples. Instead, it provides:
  - A `search` SubAgentTool that wraps the extraction agent (navigates sections, fetches,
    paginates, greps, and returns structured findings)
  - A single constraint: the final synthesis task must have id "final_answer"

  The MetaPlanner autonomously decides how many agents to create, what to name them,
  what prompts to give them, and how to decompose the question. Plan agents call `search`
  with a specific data need; the search agent handles document navigation internally.
  """

  alias PageIndex.RetrieverToolkit
  alias PtcRunner.PlanExecutor

  @doc """
  Retrieves an answer using MetaPlanner with minimal constraints.

  ## Options

  - `:llm` - Required. LLM callback (used for the meta planner)
  - `:search_llm` - Optional. Separate LLM for the search SubAgent (defaults to `:llm`)
  - `:pdf_path` - Required. Path to the PDF file
  - `:max_replans` - Max replan attempts (default: 2)
  - `:quality_gate` - Enable pre-flight data sufficiency check (default: false)
  - `:quality_gate_llm` - Optional separate LLM for quality gate
  - `:on_event` - Optional event callback
  """
  def retrieve(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    search_llm = Keyword.get(opts, :search_llm)
    pdf_path = Keyword.fetch!(opts, :pdf_path)
    max_replans = Keyword.get(opts, :max_replans, 2)
    on_event = Keyword.get(opts, :on_event)
    quality_gate = Keyword.get(opts, :quality_gate, false)
    quality_gate_llm = Keyword.get(opts, :quality_gate_llm)

    # Pre-warm the PDF cache
    IO.puts("Pre-loading PDF pages...")
    {:ok, _} = PageIndex.get_content(pdf_path, 1, 1)
    IO.puts("PDF cache ready.")

    nodes = RetrieverToolkit.flatten_tree(tree)
    doc_title = tree.title || "Document"

    mission = """
    Answer this question about "#{doc_title}":

    QUESTION: #{query}

    Use the search tool to find relevant data from the document.
    """

    constraints = """
    The final synthesis task MUST have the id "final_answer".
    """

    available_tools = %{
      "search" => """
      Search the document for specific data. Returns structured findings.
      Signature: (query :string) -> {findings [{label :string, value :any, unit :string, page :any, section :string, context :string}], sections_searched [:string]}

      Call with a specific data need, e.g.: (tool/search {:query "total revenue for 2022"})
      Use multiple search calls for different data points rather than one broad query.
      """
    }

    search_tool_opts = if search_llm, do: [llm: search_llm], else: []

    base_tools = %{
      "search" => RetrieverToolkit.make_search_tool(nodes, pdf_path, search_tool_opts)
    }

    executor_opts =
      [
        llm: llm,
        available_tools: available_tools,
        base_tools: base_tools,
        max_total_replans: max_replans,
        max_turns: 20,
        timeout: 60_000,
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
        final_result = RetrieverToolkit.find_synthesis_result(results)

        {:ok,
         %{
           answer:
             final_result["answer"] || final_result["assessment"] || final_result["analysis"] ||
               final_result,
           sources: RetrieverToolkit.extract_search_sources(results),
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
end
