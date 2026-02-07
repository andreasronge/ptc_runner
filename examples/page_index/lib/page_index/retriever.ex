defmodule PageIndex.Retriever do
  @moduledoc """
  Tree-based retrieval using SubAgent with llm_query.

  Two retrieval modes:
  - `retrieve/3` - Agent-based with tool calls to fetch content
  - `retrieve_simple/3` - Score all nodes, fetch top matches
  """

  alias PageIndex.DocumentTools
  alias PtcRunner.SubAgent

  @doc """
  Retrieves relevant content using an agent that can fetch sections.

  The agent sees a list of all sections with summaries and can
  call `get-content` to fetch actual page content.
  """
  def retrieve(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    pdf_path = Keyword.fetch!(opts, :pdf_path)
    max_turns = Keyword.get(opts, :max_turns, 15)

    # Pre-warm the PDF cache before agent execution
    IO.puts("Pre-loading PDF pages...")
    {:ok, _} = PageIndex.get_content(pdf_path, 1, 1)
    IO.puts("PDF cache ready.")

    # Flatten tree to get all nodes with page ranges
    nodes = DocumentTools.flatten_tree(tree)

    # Format sections as a readable list
    sections_text =
      nodes
      |> Enum.map(fn n ->
        summary = String.slice(n.summary || "", 0, 120)
        "• #{n.node_id}: #{n.title} (pages #{n.start_page}-#{n.end_page})\n  #{summary}"
      end)
      |> Enum.join("\n\n")

    get_content = DocumentTools.make_fetch_tool(nodes, pdf_path, chunk_size: 6000)
    grep_content = DocumentTools.make_grep_tool(nodes, pdf_path)

    prompt = """
    Answer the question using the document sections listed below.

    QUESTION: {{query}}

    AVAILABLE SECTIONS:
    #{sections_text}

    INSTRUCTIONS:
    1. Read the summaries and identify 2-4 sections most likely to answer the question
    2. Fetch each relevant section using: (tool/get-content {:node_id "the_node_id"})
    3. Read the fetched content carefully
    3b. PAGINATION: If you are looking for a table or specific data and a fetch result
        shows `truncated: true`, you MUST call get-content again with the same node_id
        and the offset from the hint. Do not guess data from partial tables.
        For large sections, use grep-content first to find where specific data appears,
        then use get-content with the offset.
    4. Synthesize a comprehensive answer using facts from the content
    5. Return your answer with the sources used

    IMPORTANT:
    - Fetch multiple sections if the answer requires information from different parts
    - Use specific numbers and facts from the content
    - Cite which sections your answer came from
    """

    navigator =
      SubAgent.new(
        prompt: prompt,
        signature:
          "(query :string) -> {answer :string, sources [{node_id :string, pages :string}]}",
        tools: %{"get-content" => get_content, "grep-content" => grep_content},
        max_turns: max_turns,
        timeout: 30_000
      )

    SubAgent.run(navigator, llm: llm, context: %{query: query})
  end

  @doc """
  Simple retrieval that scores all nodes and fetches top matches.
  More predictable but makes more LLM calls for scoring.
  """
  def retrieve_simple(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    pdf_path = Keyword.fetch!(opts, :pdf_path)
    top_k = Keyword.get(opts, :top_k, 3)

    nodes = DocumentTools.flatten_tree(tree)

    IO.puts("Scoring #{length(nodes)} nodes...")

    scored_nodes =
      nodes
      |> Task.async_stream(
        fn node ->
          score = score_relevance(node, query, llm)
          IO.puts("  #{node.node_id}: #{score}")
          Map.put(node, :score, score)
        end,
        max_concurrency: 5,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(top_k)

    IO.puts("\nTop #{top_k} relevant sections:")

    for node <- scored_nodes do
      IO.puts("  #{node.node_id} (score: #{node.score}): #{node.title}")
    end

    IO.puts("\nFetching content...")

    contents =
      Enum.map(scored_nodes, fn node ->
        {:ok, content} = PageIndex.get_content(pdf_path, node.start_page, node.end_page)

        %{
          node_id: node.node_id,
          title: node.title,
          pages: "#{node.start_page}-#{node.end_page}",
          content: content
        }
      end)

    IO.puts("Generating answer...")
    generate_answer(query, contents, llm)
  end

  defp score_relevance(node, query, llm) do
    prompt = """
    Rate how relevant this section is to answering the question.

    Question: #{query}

    Section: #{node.title}
    Summary: #{node.summary}

    Return a score from 0.0 (not relevant) to 1.0 (highly relevant).
    """

    case SubAgent.run(prompt, output: :json, signature: "{score :float}", llm: llm) do
      {:ok, step} -> step.return["score"] || 0.0
      {:error, _} -> 0.0
    end
  end

  defp generate_answer(query, contents, llm) do
    context_text =
      contents
      |> Enum.map(fn c ->
        """
        === #{c.title} (pages #{c.pages}) ===
        #{String.slice(c.content, 0, 4000)}
        """
      end)
      |> Enum.join("\n\n")

    prompt = """
    Answer the following question using ONLY the provided context.
    Cite specific facts and numbers from the sources.

    Question: #{query}

    Context:
    #{context_text}
    """

    case SubAgent.run(prompt,
           output: :json,
           signature: "{answer :string, sources [:string]}",
           llm: llm
         ) do
      {:ok, step} -> {:ok, step.return}
      {:error, step} -> {:error, step.fail}
    end
  end
end
