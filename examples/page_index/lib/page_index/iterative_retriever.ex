defmodule PageIndex.IterativeRetriever do
  @moduledoc """
  Iterative retrieval inspired by PageIndex's approach.

  Uses a loop with sufficiency checking:
  1. Select relevant sections from index
  2. Fetch content
  3. Check if sufficient to answer
  4. If not, identify what's missing and fetch more
  5. Generate answer when sufficient
  """

  alias PtcRunner.SubAgent

  @doc """
  Retrieves using iterative refinement with sufficiency checking.
  """
  def retrieve(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    pdf_path = Keyword.fetch!(opts, :pdf_path)
    max_iterations = Keyword.get(opts, :max_iterations, 3)

    nodes = flatten_tree(tree)
    sections_text = format_sections(nodes)

    # Tools for the agent
    tools = %{
      "fetch-section" => make_fetch_tool(nodes, pdf_path),
      "check-sufficiency" => make_sufficiency_tool(llm),
      "identify-missing" => make_missing_tool(llm)
    }

    prompt = """
    Answer the question by iteratively gathering information from document sections.

    QUESTION: {{query}}

    AVAILABLE SECTIONS:
    #{sections_text}

    PROCESS:
    1. Identify 2-3 sections likely to contain relevant information
    2. Fetch each section: (tool/fetch-section {:node_id "id"})
    3. Check if you have sufficient info: (tool/check-sufficiency {:question data/query :collected "summary of what you found"})
    4. If insufficient, identify what's missing: (tool/identify-missing {:question data/query :collected "what you have" :gap "what's missing"})
    5. Fetch additional sections based on the gap
    6. Repeat until sufficient, then return answer

    IMPORTANT:
    - For ratio/calculation questions, you need BOTH numerator and denominator
    - For comparison questions, fetch data for ALL items being compared
    - For trend questions, fetch multiple time periods
    - Always verify you have the specific numbers needed before answering
    """

    navigator = SubAgent.new(
      prompt: prompt,
      signature: "(query :string) -> {answer :string, sources [{node_id :string, pages :string}], iterations :int}",
      tools: tools,
      max_turns: max_iterations * 5
    )

    SubAgent.run(navigator, llm: llm, context: %{query: query})
  end

  defp make_fetch_tool(nodes, pdf_path) do
    fn args ->
      node_id = args["node_id"] || args[:node_id]
      node = Enum.find(nodes, fn n -> n.node_id == node_id end)

      if node do
        case PageIndex.get_content(pdf_path, node.start_page, node.end_page) do
          {:ok, content} ->
            content = if String.length(content) > 5000 do
              String.slice(content, 0, 5000) <> "\n[truncated]"
            else
              content
            end

            %{
              node_id: node_id,
              title: node.title,
              pages: "#{node.start_page}-#{node.end_page}",
              content: content
            }

          {:error, reason} ->
            %{error: inspect(reason)}
        end
      else
        %{error: "Node not found: #{node_id}"}
      end
    end
  end

  defp make_sufficiency_tool(llm) do
    fn args ->
      question = args["question"] || args[:question]
      collected = args["collected"] || args[:collected]

      prompt = """
      Determine if the collected information is SUFFICIENT to answer the question.

      Question: #{question}

      Collected Information:
      #{collected}

      Consider:
      - For calculations: Do we have ALL numbers needed?
      - For comparisons: Do we have data for ALL items?
      - For trends: Do we have multiple time periods?
      - For causes: Do we have specific factors, not just outcomes?

      Be STRICT - if any key information is missing, mark as insufficient.
      """

      case SubAgent.run(prompt,
             output: :json,
             signature: "{sufficient :bool, reason :string, missing :string}",
             llm: llm
           ) do
        {:ok, step} -> step.return
        {:error, _} -> %{"sufficient" => false, "reason" => "Error checking", "missing" => "unknown"}
      end
    end
  end

  defp make_missing_tool(llm) do
    fn args ->
      question = args["question"] || args[:question]
      collected = args["collected"] || args[:collected]
      gap = args["gap"] || args[:gap]

      prompt = """
      Given what's missing, suggest which document sections to fetch next.

      Question: #{question}
      What we have: #{collected}
      What's missing: #{gap}

      Return the types of sections that would likely contain the missing information.
      Be specific about what financial data is needed.
      """

      case SubAgent.run(prompt,
             output: :json,
             signature: "{suggested_sections [:string], rationale :string}",
             llm: llm
           ) do
        {:ok, step} -> step.return
        {:error, _} -> %{"suggested_sections" => [], "rationale" => "Error identifying"}
      end
    end
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

  defp format_sections(nodes) do
    nodes
    |> Enum.map(fn n ->
      summary = String.slice(n.summary || "", 0, 100)
      "• #{n.node_id}: #{n.title} (p.#{n.start_page}-#{n.end_page}) - #{summary}"
    end)
    |> Enum.join("\n")
  end
end
