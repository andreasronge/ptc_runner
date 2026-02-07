defmodule PageIndex.HybridRetriever do
  @moduledoc """
  Routes queries to the most efficient retrieval strategy.

  Strategies:
  1. **simple** - Direct SubAgent call for basic lookups.
  2. **computational** - Planned tasks using inline PTC-Lisp.
  3. **exploratory** - Iterative retrieval for fuzzy search.
  4. **complex** - Full MetaPlanner decomposition.
  """

  alias PageIndex.{Retriever, PlannerRetriever, IterativeRetriever, DocumentTools}
  alias PtcRunner.SubAgent

  @doc """
  Main entry point for hybrid retrieval.
  """
  def retrieve(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)

    nodes = DocumentTools.flatten_tree(tree)
    sections_summary = DocumentTools.format_sections(nodes)

    strategy = classify_query(query, sections_summary, llm)
    IO.puts("Hybrid strategy selected: #{strategy}")

    route(strategy, tree, query, opts)
  end

  defp route("simple", tree, query, opts) do
    case Retriever.retrieve(tree, query, opts) do
      {:ok, step} ->
        {:ok,
         %{
           answer: step.return["answer"],
           sources: step.return["sources"],
           strategy: "simple",
           replans: 0,
           tasks_executed: 1
         }}

      {:error, step} ->
        {:error, step.fail}
    end
  end

  defp route("computational", tree, query, opts) do
    case PlannerRetriever.retrieve(tree, query, Keyword.put(opts, :strategy, :computational)) do
      {:ok, result} -> {:ok, Map.put(result, :strategy, "computational")}
      err -> err
    end
  end

  defp route("exploratory", tree, query, opts) do
    case IterativeRetriever.retrieve(tree, query, opts) do
      {:ok, result} ->
        {:ok,
         %{
           answer: result.answer,
           sources: result.sources,
           strategy: "exploratory",
           replans: result.iterations,
           tasks_executed: result.findings_count
         }}

      err ->
        err
    end
  end

  defp route(_strategy, tree, query, opts) do
    case PlannerRetriever.retrieve(tree, query, opts) do
      {:ok, result} -> {:ok, Map.put(result, :strategy, "complex")}
      err -> err
    end
  end

  defp classify_query(query, sections_summary, llm) do
    prompt = """
    Analyze the following user query and document structure to determine the most \
    efficient retrieval strategy.

    QUERY: #{query}

    DOCUMENT STRUCTURE:
    #{sections_summary}

    STRATEGIES:
    - "simple": A straightforward lookup for a single fact or data point that is \
    likely contained in one specific section. (e.g., "What is the primary address?", "Who is the CEO?")
    - "computational": Requires extracting specific numeric values and performing \
    arithmetic, comparisons, or aggregations. (e.g., "What was the percentage change between 2022 and 2021?", \
    "Compare the values in Section A vs Section B")
    - "exploratory": Requires searching for unstructured information that might be \
    scattered or fuzzy, needing a loop to find then refine. (e.g., "What are the key risk factors mentioned?", \
    "Summarize all references to a specific topic")
    - "complex": Requires a multi-step plan involving multiple distinct data points \
    from different parts of the document to be combined. (e.g., "Analyze the relationship between two metrics across sections")

    INSTRUCTIONS:
    - Respond with ONLY a JSON object containing the "strategy" key.
    - Be biased towards "simple" if it seems possible to answer in one go.
    - Be biased towards "computational" if numbers are involved.
    """

    case SubAgent.run(prompt, output: :json, signature: "{strategy :string}", llm: llm) do
      {:ok, step} ->
        (step.return["strategy"] || "complex") |> String.downcase()

      {:error, _} ->
        "complex"
    end
  end
end
